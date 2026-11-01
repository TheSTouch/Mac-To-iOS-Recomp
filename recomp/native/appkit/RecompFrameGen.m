// Frame generation (iOS 26): MetalFX's frame interpolator makes a frame between each
// two the game renders, from the depth and motion vectors the game already hands
// MetalFX's temporal upscaler. The game renders fewer frames (less GPU work, less
// heat) and the screen shows twice as many; each rendered frame looks the same.
//
// Tried on Stray on an iPhone 17: the GPU went from 87% to 69% busy for the same 30
// frames/s shown, but from 15 frames/s rendered the controls felt half a second late.
// An iPhone app's screen runs at 60 Hz (120 needs CADisableMinimumFrameDurationOnPhone,
// and a warm phone drops back to 60), so 20 rendered -> 40 shown does not fit; 30 -> 60
// is smoother but not cooler.
//
// A game's profile can turn it on for iPhones ("frame_generation" in its "iphone" block,
// RecompFrameGenPhone in the Info.plist) and for iPads (its "ipad" block, RecompFrameGenPad).
// Stray's does on both: 20 -> 40 on an iPhone, 30 -> 60 on an iPad, where the screen runs
// at 120 Hz (an M1 iPad Pro renders the game at about 41 frames/s uncapped, CPU-bound, and
// shows them unevenly). RECOMP_IDIOM=phone or pad picks a set on a Mac. A file named
// recomp-framegen in Documents overrides that while the game runs: empty or "off": off;
// "default": the profile's setting; otherwise on, with optional key=value words:
//   fps=20     frames the game renders each second (the screen shows twice as many)
//   fov=50     the camera's vertical field of view, in degrees
//   near=10    near plane in game units (Unreal: centimetres)
//   far=1e6    far plane (Unreal's is infinite)
//   mv=1       factor on the motion vector scale the game gives the upscaler
//   jitter=0   pass the upscaler's jitter (the color given here is already upscaled)
//   lock=1     hold the game's frames and both shown frames to the screen's refreshes
//              (lock=0: the game on a clock of its own, each frame shown as soon as it
//              is ready). Unlocked, the two drift apart over minutes, and at some
//              offsets the drawables are late: on an M1 iPad Pro at 2x output, for
//              minutes at a time, every other frame stayed 1.5 refreshes and the next
//              2.5, and the picture seemed to jump between two images.
//   bench=1    no frame generation: the game renders as fast as it can (fps=0 for no
//              cap) into stand-ins it never waits for, and a thread of its own shows
//              the newest finished frame at each refresh, dropping the rest. The GPU stays fully busy at its full clock, so the frames
//              rendered each second measure what settings cost; otherwise iOS lowers
//              the GPU clock to the load and the time per frame hides any saving.
//   pace=40    no frame generation: the screen is asked for 120 Hz and each frame the
//              game presents stays on it at least 1/40 s, so a game held to 40 frames/s
//              (its own frame rate limit) shows each one for exactly 3 refreshes. On an
//              M1 iPad Pro, Stray uncapped runs 40-50 frames/s, which land on the
//              refreshes unevenly.
//
// How: while on, the game draws into stand-in drawables whose textures are this
// file's (a ring of kRing), so it never waits for the screen's three drawables, and
// its requests are held to `fps`. After the upscaler's encode, the game's command
// buffer copies its depth and motion textures (it reuses them the next frame); the
// next stand-in the game takes is the frame they belong to. When the game presents
// a stand-in, a frame between it and the previous one is made straight into a real
// drawable and presented, then the frame itself is copied into another and
// presented half a frame later. Locked (the default), the game's frames start a whole
// number of refreshes apart and both are presented at refresh times: the frame between
// two refreshes after the last shown frame, or the first refresh it can be ready for.
//
// Whatever the switch, the upscaler's inputs are logged once (formats, sizes, motion
// vector scale, jitter), and the order of upscaler encodes, drawables and presents
// over the first frames.
#import "RecompAppKit.h"
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>

id<MTLCommandQueue> RecompGameQueue(void); // RecompMetal.m

typedef struct { double fps, fov, nearZ, farZ, mv, pace; BOOL jitter, bench, lock; } Settings;
static const Settings kDefaults = {20, 50, 10, 1e6, 1, 0, NO, NO, YES};

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static Settings gSet;                  // under gLock
static atomic_bool gOn;
static dispatch_queue_t gGen;          // generation and the switch's polling
static __thread BOOL tOurs;            // a real drawable taken by this file

static void Swap(Class c, SEL sel, IMP imp, IMP *orig) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) { RLOG(@"framegen: %s has no %s", class_getName(c), sel_getName(sel)); return; }
    *orig = method_setImplementation(m, imp);
}

static Settings CurrentSettings(void) {
    os_unfair_lock_lock(&gLock);
    Settings s = gSet;
    os_unfair_lock_unlock(&gLock);
    return s;
}

// --- order of events over the first frames --------------------------------------------

static char gOrder[64];
static atomic_int gOrderLen;
static void Trace(char c) {
    int i = atomic_fetch_add(&gOrderLen, 1);
    if (i < (int)sizeof gOrder - 1) gOrder[i] = c;
    if (i == (int)sizeof gOrder - 2)
        RLOG(@"framegen: order of upscaler encodes (E), drawables (D), presents (P), command-buffer presents (C): %s", gOrder);
}

// --- the upscaler's inputs, copied --------------------------------------------------------

@interface RFGInputs : NSObject {
@public
    int slot;
    float mvx, mvy, jx, jy;
    BOOL reversed, reset;
}
@end
@implementation RFGInputs
@end

enum { kSlots = 3 };
static id<MTLTexture> gDepth[kSlots], gMotion[kSlots]; // the render thread's
static int gNextSlot;
static RFGInputs *gPending;            // under gLock: the last encode's, not yet given a drawable

static id<MTLTexture> Match(id<MTLTexture> have, id<MTLDevice> dev, MTLPixelFormat format, NSUInteger w, NSUInteger h,
                            MTLTextureUsage usage) {
    if (have && have.width == w && have.height == h && have.pixelFormat == format) return have;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
    d.usage = usage;
    d.storageMode = MTLStorageModePrivate;
    return [dev newTextureWithDescriptor:d];
}
static id<MTLTexture> MatchTexture(id<MTLTexture> have, id<MTLTexture> like, MTLTextureUsage usage) {
    return Match(have, like.device, like.pixelFormat, like.width, like.height, usage);
}

static NSString *Describe(id<MTLTexture> t) {
    if (!t) return @"none";
    return [NSString stringWithFormat:@"%lux%lu format %lu usage %lu type %lu samples %lu", (unsigned long)t.width,
            (unsigned long)t.height, (unsigned long)t.pixelFormat, (unsigned long)t.usage, (unsigned long)t.textureType,
            (unsigned long)t.sampleCount];
}

static void LogScalerOnce(id<MTLFXTemporalScaler> s) {
    static atomic_bool done;
    if (atomic_exchange(&done, true)) return;
    RLOG(@"framegen: upscaler %s: color %@; depth %@; motion %@; output %@; content %lux%lu; motion vector scale %.3f, %.3f; "
         @"jitter %.3f, %.3f; depth reversed %d; pre-exposure %.3f; exposure texture %@",
         class_getName(object_getClass(s)), Describe(s.colorTexture), Describe(s.depthTexture), Describe(s.motionTexture),
         Describe(s.outputTexture), (unsigned long)s.inputContentWidth, (unsigned long)s.inputContentHeight,
         s.motionVectorScaleX, s.motionVectorScaleY, s.jitterOffsetX, s.jitterOffsetY, [s isDepthReversed], s.preExposure,
         Describe(s.exposureTexture));
}

static IMP oEncode;
static void FixEncode(id<MTLFXTemporalScaler> self, SEL s, id<MTLCommandBuffer> cb) {
    ((void (*)(id, SEL, id))oEncode)(self, s, cb);
    Trace('E');
    LogScalerOnce(self);
    if (!atomic_load(&gOn)) return;
    id<MTLTexture> depth = self.depthTexture, motion = self.motionTexture;
    if (!depth || !motion || depth.textureType != MTLTextureType2D || depth.sampleCount > 1 || motion.sampleCount > 1) return;
    int k = gNextSlot;
    gNextSlot = (k + 1) % kSlots;
    gDepth[k] = MatchTexture(gDepth[k], depth, MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget);
    gMotion[k] = MatchTexture(gMotion[k], motion, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:depth toTexture:gDepth[k]];
    [b copyFromTexture:motion toTexture:gMotion[k]];
    [b endEncoding];
    RFGInputs *in = [RFGInputs new];
    in->slot = k;
    in->mvx = self.motionVectorScaleX;
    in->mvy = self.motionVectorScaleY;
    in->jx = self.jitterOffsetX;
    in->jy = self.jitterOffsetY;
    in->reversed = [self isDepthReversed];
    in->reset = self.reset;
    os_unfair_lock_lock(&gLock);
    gPending = in;
    os_unfair_lock_unlock(&gLock);
}

// Called by RecompMetal.m for each temporal scaler the game makes.
void RecompFrameGenScaler(id scaler) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    if (!scaler) return;
    os_unfair_lock_lock(&lock);
    if (!oEncode) Swap(object_getClass(scaler), @selector(encodeToCommandBuffer:), (IMP)FixEncode, &oEncode);
    os_unfair_lock_unlock(&lock);
}

// --- stand-in drawables ------------------------------------------------------------------------

// The game draws into a ring of kRing textures. A frame's texture is read by its own
// generation and, as the previous frame, by the next one; it goes back to the ring
// once both are committed (the game's later work on the same queue comes after them).
// Two keep the game from drawing ahead of the screen: it draws the next frame only once
// the previous one is handed to the screen, while that one stays as the previous frame
// for the next generation. Four let it run three frames ahead (200 ms of input delay at
// 15 frames/s); three, one frame (50 ms at 20 frames/s, felt on the camera).
enum { kRing = 2 };
static id<MTLTexture> gRing[kRing];    // the render thread's
static int gRingNext;
static dispatch_semaphore_t gRingFree;

@class RFGDrawable;
static void Generate(RFGDrawable *d);
static void BenchPresent(RFGDrawable *d);

@interface RFGDrawable : NSObject <CAMetalDrawable> {
@public
    int slot;
    BOOL bench;                        // one of the bench ring's
    RFGInputs *inputs;
    NSMutableArray *handlers;
    CFTimeInterval presented;
}
@property (nonatomic, strong) id<MTLTexture> texture;
@property (nonatomic, strong) CAMetalLayer *layer;
@property (nonatomic) NSUInteger drawableID;
@end

@implementation RFGDrawable
- (void)present {
    Trace('P');
    if (bench) BenchPresent(self);
    else dispatch_async(gGen, ^{ Generate(self); });
}
- (void)presentAtTime:(CFTimeInterval)t { [self present]; }
- (void)presentAfterMinimumDuration:(CFTimeInterval)t { [self present]; }
- (void)addPresentedHandler:(MTLDrawablePresentedHandler)block {
    @synchronized (self) {
        if (!handlers) handlers = [NSMutableArray array];
        [handlers addObject:block];
    }
}
- (CFTimeInterval)presentedTime { return presented; }
@end

// The screen's refreshes, from the display link (RFGTick).
static os_unfair_lock gGridLock = OS_UNFAIR_LOCK_INIT;
static double gVsync, gPeriod;         // under gGridLock
static double Period(void) {
    os_unfair_lock_lock(&gGridLock);
    double v = gVsync, p = gPeriod;
    os_unfair_lock_unlock(&gGridLock);
    return p > 0 && CACurrentMediaTime() - v < 1 ? p : 0;
}
// The refresh nearest t, or the first at or after it; t itself without a display link.
static double Refresh(double t, BOOL nearest) {
    os_unfair_lock_lock(&gGridLock);
    double v = gVsync, p = gPeriod;
    os_unfair_lock_unlock(&gGridLock);
    if (p <= 0 || CACurrentMediaTime() - v > 1) return t;
    double n = (t - v) / p;
    return v + (nearest ? round(n) : ceil(n - 1e-3)) * p;
}

static double gNextAcquire;            // the render thread's

// Holds the game to `fps`; locked, its frames start a whole number of refreshes apart.
static void Pace(void) {
    Settings set = CurrentSettings();
    if (set.fps <= 0) return;
    double interval = 1 / set.fps, now = CACurrentMediaTime();
    if (gNextAcquire > now && gNextAcquire - now < 1) usleep((useconds_t)((gNextAcquire - now) * 1e6));
    now = CACurrentMediaTime();
    gNextAcquire = (gNextAcquire > now - interval ? gNextAcquire : now) + interval;
    if (set.lock && !set.bench) gNextAcquire = Refresh(gNextAcquire, YES);
}

static IMP oNextDrawable;
static id RealDrawable(CAMetalLayer *layer) {
    tOurs = YES;
    id d = ((id (*)(id, SEL))oNextDrawable)(layer, @selector(nextDrawable));
    tOurs = NO;
    return d;
}

// --- bench mode ------------------------------------------------------------------------------
// The game never waits for the screen: it draws into one of kBench textures, a finished
// frame replaces a finished one not yet shown (that one is dropped), and a thread of its
// own puts the newest on the screen, waiting for the screen's drawables itself. Five
// cover the worst case: two being drawn, one finished, one being copied, one free.
enum { kBench = 5, kFree = 0, kDrawing, kReady, kCopying };
static id<MTLTexture> gBenchTex[kBench];
static int gBenchState[kBench];            // under gLock
static int gBenchReady = -1;               // under gLock: the newest finished frame
static CAMetalLayer *gBenchLayer;          // under gLock
static dispatch_semaphore_t gBenchSignal;
static atomic_uint gBenchRendered, gBenchShown;

static id BenchAcquire(CAMetalLayer *layer) {
    int k = -1;
    os_unfair_lock_lock(&gLock);
    for (int i = 0; i < kBench && k < 0; i++)
        if (gBenchState[i] == kFree) k = i;
    if (k >= 0) gBenchState[k] = kDrawing;
    os_unfair_lock_unlock(&gLock);
    if (k < 0) return nil;
    // A drawing slot is the game's alone, so its texture can change here.
    CGSize size = layer.drawableSize;
    gBenchTex[k] = Match(gBenchTex[k], layer.device, layer.pixelFormat, (NSUInteger)size.width, (NSUInteger)size.height,
                         MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
    RFGDrawable *d = [RFGDrawable new];
    d->slot = k;
    d->bench = YES;
    d.texture = gBenchTex[k];
    d.layer = layer;
    return d;
}

static void BenchPresent(RFGDrawable *d) {
    atomic_fetch_add(&gBenchRendered, 1);
    os_unfair_lock_lock(&gLock);
    if (gBenchReady >= 0) gBenchState[gBenchReady] = kFree;
    gBenchState[d->slot] = kReady;
    gBenchReady = d->slot;
    gBenchLayer = d.layer;
    os_unfair_lock_unlock(&gLock);
    dispatch_semaphore_signal(gBenchSignal);
}

static void BenchPresenter(void) {
    for (;;) {
        dispatch_semaphore_wait(gBenchSignal, DISPATCH_TIME_FOREVER);
        os_unfair_lock_lock(&gLock);
        int k = gBenchReady;
        if (k >= 0) {
            gBenchReady = -1;
            gBenchState[k] = kCopying;
        }
        CAMetalLayer *layer = gBenchLayer;
        os_unfair_lock_unlock(&gLock);
        if (k < 0) continue;
        id<MTLTexture> tex = gBenchTex[k];
        id<CAMetalDrawable> out = RealDrawable(layer);
        id<MTLCommandQueue> q = RecompGameQueue();
        if (!out || !q || out.texture.width != tex.width || out.texture.height != tex.height) {
            os_unfair_lock_lock(&gLock);
            gBenchState[k] = kFree;
            os_unfair_lock_unlock(&gLock);
            continue;
        }
        id<MTLCommandBuffer> cb = [q commandBuffer];
        cb.label = @"recomp bench: copy";
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b copyFromTexture:tex toTexture:out.texture];
        [b endEncoding];
        [cb addScheduledHandler:^(id<MTLCommandBuffer> c) { [out present]; }];
        [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
            os_unfair_lock_lock(&gLock);
            gBenchState[k] = kFree;
            os_unfair_lock_unlock(&gLock);
        }];
        [cb commit];
        atomic_fetch_add(&gBenchShown, 1);
    }
}

static id FixNextDrawable(CAMetalLayer *self, SEL s) {
    if (tOurs || !atomic_load(&gOn)) return ((id (*)(id, SEL))oNextDrawable)(self, s);
    if (self.framebufferOnly) {
        // Frames are copied into the real drawables, which a framebuffer-only one refuses.
        dispatch_async(dispatch_get_main_queue(), ^{ self.framebufferOnly = NO; });
        return ((id (*)(id, SEL))oNextDrawable)(self, s);
    }
    Pace();
    if (CurrentSettings().bench) {
        id d = BenchAcquire(self);
        return d ?: ((id (*)(id, SEL))oNextDrawable)(self, s);
    }
    if (dispatch_semaphore_wait(gRingFree, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC))) {
        RLOG(@"framegen: no stand-in free after 1 s, the game gets a real drawable");
        return ((id (*)(id, SEL))oNextDrawable)(self, s);
    }
    Trace('D');
    static NSUInteger ids;
    int k = gRingNext;
    gRingNext = (k + 1) % kRing;
    CGSize size = self.drawableSize;
    gRing[k] = Match(gRing[k], self.device, self.pixelFormat, (NSUInteger)size.width, (NSUInteger)size.height,
                     MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
    RFGDrawable *d = [RFGDrawable new];
    d->slot = k;
    d.texture = gRing[k];
    d.layer = self;
    d.drawableID = ++ids;
    os_unfair_lock_lock(&gLock);
    d->inputs = gPending;
    gPending = nil;
    os_unfair_lock_unlock(&gLock);
    return d;
}

// The game's real drawables, presented the usual way, are traced too; with pace=N
// (frame generation off) each stays on screen at least 1/N s.
static IMP oPresent;
static void FixPresent(id self, SEL s) {
    Trace('P');
    double pace = atomic_load(&gOn) || tOurs ? 0 : CurrentSettings().pace;
    if (pace > 0) [self presentAfterMinimumDuration:1 / pace];
    else ((void (*)(id, SEL))oPresent)(self, s);
}

// Metal cannot present a stand-in through a command buffer: it becomes a present
// from the command buffer's scheduled handler.
static IMP oCBPresent, oCBPresentAt, oCBPresentAfter;
static atomic_uint gLateInputs;
static BOOL StandIn(id<MTLCommandBuffer> cb, id d) {
    Trace('C');
    if (![d isKindOfClass:[RFGDrawable class]]) return NO;
    os_unfair_lock_lock(&gLock);
    if (gPending) atomic_fetch_add(&gLateInputs, 1);
    os_unfair_lock_unlock(&gLock);
    [cb addScheduledHandler:^(id<MTLCommandBuffer> b) { [d present]; }];
    return YES;
}
static void FixCBPresent(id self, SEL s, id d) {
    if (!StandIn(self, d)) ((void (*)(id, SEL, id))oCBPresent)(self, s, d);
}
static void FixCBPresentAt(id self, SEL s, id d, CFTimeInterval t) {
    if (!StandIn(self, d)) ((void (*)(id, SEL, id, CFTimeInterval))oCBPresentAt)(self, s, d, t);
}
static void FixCBPresentAfter(id self, SEL s, id d, CFTimeInterval t) {
    if (!StandIn(self, d)) ((void (*)(id, SEL, id, CFTimeInterval))oCBPresentAfter)(self, s, d, t);
}

// --- generation (on gGen) --------------------------------------------------------------------

static int gPrevSlot = -1;
static id<MTLTexture> gPrevTexture;
static id gInterpolator;
static BOOL gInterpolatorFailed;
static struct { unsigned real, made, noInputs, reset, noPrev, noDrawable, failed, corrected; double wait, maxWait; } gStats;

// How long each shown frame stayed on the screen, in refreshes at 120 Hz: with frame
// generation each should stay 2 (60 shown). [0] dropped, [1] 1, [2] 2, [3] 3, [4] 4 or more.
static os_unfair_lock gShownLock = OS_UNFAIR_LOCK_INIT;
static unsigned gShown[5];
static CFTimeInterval gLastShown;
// Locked: a shown frame that went on the screen later than asked (only those asked after
// the last correction count) moves the next ones a refresh later.
static atomic_bool gLate;
static _Atomic double gCorrected;
static char gTimes[400];               // under gShownLock: the last shown frames, 'm'/'o' interval ms (+ late vs asked)
static void Shown(id<MTLDrawable> d, double asked, char kind) {
    CFTimeInterval t = d.presentedTime;
    if (asked > 0 && t > asked + 0.001 && asked > atomic_load(&gCorrected)) atomic_store(&gLate, true);
    os_unfair_lock_lock(&gShownLock);
    size_t n = strlen(gTimes);
    if (t > 0 && gLastShown > 0 && n < sizeof gTimes - 24)
        snprintf(gTimes + n, sizeof gTimes - n, " %c%.1f%+.1f", kind, (t - gLastShown) * 1000, asked > 0 ? (t - asked) * 1000 : 0);
    if (t <= 0) gShown[0]++;
    else {
        if (gLastShown > 0 && t > gLastShown) gShown[MIN(4, MAX(1, (int)lround((t - gLastShown) * 120)))]++;
        gLastShown = t;
    }
    os_unfair_lock_unlock(&gShownLock);
}

API_AVAILABLE(ios(26.0))
static id<MTLFXFrameInterpolator> Interpolator(id<MTLTexture> color, id<MTLTexture> depth, id<MTLTexture> motion) {
    id<MTLFXFrameInterpolator> fi = gInterpolator;
    if (fi && fi.colorTextureFormat == color.pixelFormat && fi.outputWidth == color.width && fi.outputHeight == color.height
        && fi.depthTextureFormat == depth.pixelFormat && fi.motionTextureFormat == motion.pixelFormat
        && fi.inputWidth == motion.width && fi.inputHeight == motion.height)
        return fi;
    if (fi) gInterpolatorFailed = NO;
    gInterpolator = nil;
    if (gInterpolatorFailed) return nil;
    Class c = NSClassFromString(@"MTLFXFrameInterpolatorDescriptor");
    if (!c || ![c supportsDevice:color.device]) {
        RLOG(@"framegen: this device has no MetalFX frame interpolator");
        gInterpolatorFailed = YES;
        return nil;
    }
    MTLFXFrameInterpolatorDescriptor *d = [c new];
    d.colorTextureFormat = d.outputTextureFormat = color.pixelFormat;
    d.depthTextureFormat = depth.pixelFormat;
    d.motionTextureFormat = motion.pixelFormat;
    d.inputWidth = motion.width;
    d.inputHeight = motion.height;
    d.outputWidth = color.width;
    d.outputHeight = color.height;
    fi = [d newFrameInterpolatorWithDevice:color.device];
    if (!fi) {
        RLOG(@"framegen: the frame interpolator refused color %@, depth %@, motion %@", Describe(color), Describe(depth), Describe(motion));
        gInterpolatorFailed = YES;
        return nil;
    }
    RLOG(@"framegen: frame interpolator %lux%lu -> %lux%lu; usage wanted: color %lu, depth %lu, motion %lu, output %lu",
         (unsigned long)fi.inputWidth, (unsigned long)fi.inputHeight, (unsigned long)fi.outputWidth, (unsigned long)fi.outputHeight,
         (unsigned long)fi.colorTextureUsage, (unsigned long)fi.depthTextureUsage, (unsigned long)fi.motionTextureUsage,
         (unsigned long)fi.outputTextureUsage);
    gInterpolator = fi;
    return fi;
}

static void LogErrors(id<MTLCommandBuffer> cb) {
    [cb addCompletedHandler:^(id<MTLCommandBuffer> b) {
        if (b.error) RLOG(@"framegen: command buffer failed: %@", b.error);
    }];
}

// How long each shown frame stays at least: half a rendered frame, less 3 ms. Exactly
// half (25 ms at 20 frames/s, 3 refreshes at 120 Hz) rounded up to the next refresh
// whenever a present came a little late, so every frame stayed 4 refreshes and the
// game rendered 15 frames/s instead of 20.
static double Half(Settings set) { return 0.5 / set.fps - 0.003; }

// Makes the frame between the previous one and `cur` straight into a real drawable and
// presents it; NO when it cannot be made.
// Locked: when the last shown frame goes on the screen, and how long it takes from a
// frame's present to the frame between being ready, the wait for its drawable included
// (rises at once, falls slowly). Without the wait, the frame between was often not
// ready in time: for minutes, every other frame stayed 1.5 refreshes and the next 2.5.
static double gLastOut;                // on gGen
static _Atomic double gLatency = 0.02;

static BOOL Between(RFGDrawable *cur, id<MTLCommandQueue> q, Settings set, double at, double start) {
    RFGInputs *in = cur->inputs;
    id<MTLTexture> tex = cur.texture, prev = gPrevTexture;
    if (!atomic_load(&gOn)) return NO;
    if (!in) { gStats.noInputs++; return NO; }
    if (in->reset) { gStats.reset++; return NO; }
    if (!prev || prev.width != tex.width || prev.height != tex.height || prev.pixelFormat != tex.pixelFormat) {
        gStats.noPrev++;
        return NO;
    }
    if (@available(iOS 26.0, *)) {
        id<MTLTexture> depth = gDepth[in->slot], motion = gMotion[in->slot];
        id<MTLFXFrameInterpolator> fi = Interpolator(tex, depth, motion);
        if (!fi) { gStats.failed++; return NO; }
        double t0 = CACurrentMediaTime();
        id<CAMetalDrawable> mid = RealDrawable(cur.layer);
        double waited = CACurrentMediaTime() - t0;
        gStats.wait += waited;
        gStats.maxWait = MAX(gStats.maxWait, waited);
        if (!mid || mid.texture.width != tex.width || mid.texture.height != tex.height) { gStats.noDrawable++; return NO; }
        id<MTLCommandBuffer> cb = [q commandBuffer];
        cb.label = @"recomp frame generation";
        fi.colorTexture = tex;
        fi.prevColorTexture = prev;
        fi.depthTexture = depth;
        fi.motionTexture = motion;
        fi.outputTexture = mid.texture;
        fi.motionVectorScaleX = in->mvx * set.mv;
        fi.motionVectorScaleY = in->mvy * set.mv;
        fi.jitterOffsetX = set.jitter ? in->jx : 0;
        fi.jitterOffsetY = set.jitter ? in->jy : 0;
        fi.depthReversed = in->reversed;
        fi.deltaTime = 1 / set.fps;
        fi.nearPlane = set.nearZ;
        fi.farPlane = set.farZ;
        fi.fieldOfView = set.fov;
        fi.aspectRatio = (float)tex.width / tex.height;
        fi.shouldResetHistory = NO;
        [fi encodeToCommandBuffer:cb];
        double half = Half(set);
        [mid addPresentedHandler:^(id<MTLDrawable> d) { Shown(d, at, 'm'); }];
        if (at > 0) {
            [cb addScheduledHandler:^(id<MTLCommandBuffer> b) { [mid presentAtTime:at]; }];
            [cb addCompletedHandler:^(id<MTLCommandBuffer> b) {
                double took = CACurrentMediaTime() - start, l = atomic_load(&gLatency);
                atomic_store(&gLatency, MIN(0.1, took > l ? took : l * 0.98 + took * 0.02));
            }];
        } else [cb addScheduledHandler:^(id<MTLCommandBuffer> b) { [mid presentAfterMinimumDuration:half]; }];
        LogErrors(cb);
        [cb commit];
        gStats.made++;
        return YES;
    }
    return NO;
}

static void Generate(RFGDrawable *cur) {
    id<MTLCommandQueue> q = RecompGameQueue();
    Settings set = CurrentSettings();
    gStats.real++;
    // Locked, the frame between goes on the screen at a refresh: two after the last shown
    // frame, or the first the GPU can make, and the frame itself two refreshes later.
    double start = CACurrentMediaTime(), period = set.lock ? Period() : 0, at = 0, at2 = 0;
    if (period > 0) {
        double each = MAX(1, lround(0.5 / set.fps / period)) * period;
        double soonest = Refresh(start + atomic_load(&gLatency) + 0.002, NO);
        at = gLastOut + each >= soonest && gLastOut + each < start + 0.2 ? gLastOut + each : soonest;
        if (atomic_exchange(&gLate, false)) {
            at += period;
            atomic_store(&gCorrected, at);
            gStats.corrected++;
        }
        at2 = at + each;
    }
    BOOL made = q && Between(cur, q, set, at, start);
    if (period > 0) gLastOut = made ? at2 : at;
    // The previous frame's texture is read only by the frame between, committed above:
    // back to the ring, so the game does not wait while this thread waits for a drawable.
    if (gPrevSlot >= 0) dispatch_semaphore_signal(gRingFree);
    id<CAMetalDrawable> out = RealDrawable(cur.layer);
    if (q && out && out.texture.width == cur.texture.width && out.texture.height == cur.texture.height) {
        id<MTLCommandBuffer> cb = [q commandBuffer];
        cb.label = @"recomp frame generation: copy";
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b copyFromTexture:cur.texture toTexture:out.texture];
        [b endEncoding];
        double after = made ? Half(set) : 0, when = made ? at2 : at;
        [out addPresentedHandler:^(id<MTLDrawable> d) {
            Shown(d, when, 'o');
            NSArray *handlers;
            @synchronized (cur) {
                cur->presented = d.presentedTime;
                handlers = [cur->handlers copy];
            }
            for (MTLDrawablePresentedHandler h in handlers) h(cur);
        }];
        if (when > 0) [cb addScheduledHandler:^(id<MTLCommandBuffer> c) { [out presentAtTime:when]; }];
        else [cb addScheduledHandler:^(id<MTLCommandBuffer> c) { [out presentAfterMinimumDuration:after]; }];
        LogErrors(cb);
        [cb commit];
    } else {
        gStats.noDrawable++;
    }
    gPrevSlot = cur->slot;
    gPrevTexture = cur.texture;
}

// --- the screen's refresh rate ------------------------------------------------------------------
// ProMotion sets the refresh rate from what the app seems to need: Stray presents at 30
// and the screen stayed at 30 Hz, so each shown frame waited 33 ms for a drawable and
// 20 rendered became 15. A display link asking for 120 Hz says otherwise.
@interface RFGTick : NSObject
@end
@implementation RFGTick {
    double start;
    unsigned ticks;
}
// Logs the refresh rate the screen really runs at, every 10 s.
- (void)tick:(CADisplayLink *)link {
    os_unfair_lock_lock(&gGridLock);
    gVsync = link.timestamp;
    gPeriod = link.targetTimestamp - link.timestamp;
    os_unfair_lock_unlock(&gGridLock);
    if (!start) start = link.timestamp;
    ticks++;
    if (link.timestamp - start >= 10) {
        RLOG(@"framegen: screen refreshing at %.0f Hz (asked %.0f-%.0f, prefers %.0f; max %ld)", ticks / (link.timestamp - start),
             link.preferredFrameRateRange.minimum, link.preferredFrameRateRange.maximum, link.preferredFrameRateRange.preferred,
             (long)UIScreen.mainScreen.maximumFramesPerSecond);
        start = link.timestamp;
        ticks = 0;
    }
}
@end

static CADisplayLink *gLink;           // main thread

static void WantRate(double shown) {
    if (shown <= 0) {
        [gLink invalidate];
        gLink = nil;
        return;
    }
    if (!gLink) {
        gLink = [CADisplayLink displayLinkWithTarget:[RFGTick new] selector:@selector(tick:)];
        [gLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    // Asked for 40-120 preferring 40, iOS ran the screen at 60 Hz, where 40 frames/s does
    // not fit; at 120 each shown frame lasts 3 refreshes.
    gLink.preferredFrameRateRange = CAFrameRateRangeMake(120, 120, 120);
    RLOG(@"framegen: screen asked for 120 Hz, %.0f frames/s shown", shown);
}

// --- the switch -------------------------------------------------------------------------------

static void Poll(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *text = [NSString stringWithContentsOfFile:[docs stringByAppendingPathComponent:@"recomp-framegen"]
                                               encoding:NSUTF8StringEncoding error:nil];
    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    // Without the file (or with "default"), the profile's setting for an iPhone or an iPad.
    if (!text || [text isEqualToString:@"default"]) {
        static NSString *profile;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            NSString *idiom = RecompIdiom();
            profile = idiom ? NSBundle.mainBundle.infoDictionary[[@"RecompFrameGen" stringByAppendingString:idiom]] : nil;
            if (!profile) profile = @"";
        });
        text = profile;
    }
    BOOL on = text.length && ![text isEqualToString:@"off"];
    Settings s = kDefaults;
    for (NSString *word in [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        NSArray *kv = [word componentsSeparatedByString:@"="];
        if (kv.count != 2) continue;
        double v = [kv[1] doubleValue];
        if ([kv[0] isEqualToString:@"fps"] && (v >= 5 || v == 0)) s.fps = v;
        else if ([kv[0] isEqualToString:@"bench"]) s.bench = v != 0;
        else if ([kv[0] isEqualToString:@"fov"] && v > 0) s.fov = v;
        else if ([kv[0] isEqualToString:@"near"] && v > 0) s.nearZ = v;
        else if ([kv[0] isEqualToString:@"far"] && v > 0) s.farZ = v;
        else if ([kv[0] isEqualToString:@"mv"]) s.mv = v;
        else if ([kv[0] isEqualToString:@"jitter"]) s.jitter = v != 0;
        else if ([kv[0] isEqualToString:@"lock"]) s.lock = v != 0;
        else if ([kv[0] isEqualToString:@"pace"] && v >= 5) s.pace = v;
    }
    if (s.pace) on = NO;
    Settings old = CurrentSettings();
    BOOL was = atomic_load(&gOn);
    if (on == was && memcmp(&s, &old, sizeof s) == 0) return;
    os_unfair_lock_lock(&gLock);
    gSet = s;
    os_unfair_lock_unlock(&gLock);
    if (on && !was) {
        memset(&gStats, 0, sizeof gStats);
        atomic_store(&gOrderLen, 0);
    }
    atomic_store(&gOn, on);
    double shown = on && !s.bench ? 2 * s.fps : s.pace;
    dispatch_async(dispatch_get_main_queue(), ^{ WantRate(shown); });
    if (on && s.bench) RLOG(@"framegen: bench, newest frame shown at each refresh, cap %.0f frames/s (0: none)", s.fps);
    else if (on) RLOG(@"framegen: on, %.0f frames/s rendered, fov %.0f, near %g, far %g, motion x%g, jitter %d, lock %d",
                      s.fps, s.fov, s.nearZ, s.farZ, s.mv, s.jitter, s.lock);
    else if (s.pace) RLOG(@"framegen: off, each frame shown at least 1/%.0f s", s.pace);
    else RLOG(@"framegen: off");
}

static void Report(void) {
    unsigned rendered = atomic_exchange(&gBenchRendered, 0), shown = atomic_exchange(&gBenchShown, 0);
    if (rendered) RLOG(@"framegen: bench: %.1f frames/s rendered, %.1f shown", rendered / 10.0, shown / 10.0);
    if (!gStats.real) return;
    unsigned stay[5];
    char times[sizeof gTimes];
    os_unfair_lock_lock(&gShownLock);
    memcpy(stay, gShown, sizeof stay);
    memset(gShown, 0, sizeof gShown);
    memcpy(times, gTimes, sizeof times);
    gTimes[0] = 0;
    os_unfair_lock_unlock(&gShownLock);
    if (stay[1] + stay[3] + stay[4])
        RLOG(@"framegen: uneven, the last shown (m between, o rendered; ms since the one before, ms late):%s", times);
    RLOG(@"framegen: %u frames rendered, %u made between (%.1f ms waiting for a drawable each, longest %.0f); not made: %u without "
         @"upscaler inputs, %u history resets, %u without a previous frame, %u without a drawable, %u interpolator failures; "
         @"%u given the frame before's inputs; shown for 1/2/3/4+ refreshes: %u/%u/%u/%u, %u dropped; GPU latency %.0f ms, %u corrections",
         gStats.real, gStats.made, gStats.made ? gStats.wait * 1000 / gStats.made : 0.0, gStats.maxWait * 1000, gStats.noInputs,
         gStats.reset, gStats.noPrev, gStats.noDrawable, gStats.failed, atomic_exchange(&gLateInputs, 0), stay[1], stay[2],
         stay[3], stay[4], stay[0], atomic_load(&gLatency) * 1000, gStats.corrected);
    memset(&gStats, 0, sizeof gStats);
}

__attribute__((constructor)) static void RecompFrameGenInit(void) {
    @autoreleasepool {
        gSet = kDefaults;
        gGen = dispatch_queue_create("recomp.framegen", DISPATCH_QUEUE_SERIAL);
        gRingFree = dispatch_semaphore_create(kRing);
        gBenchSignal = dispatch_semaphore_create(0);
        NSThread *presenter = [[NSThread alloc] initWithBlock:^{ BenchPresenter(); }];
        presenter.name = @"recomp bench presenter";
        presenter.qualityOfService = NSQualityOfServiceUserInteractive;
        [presenter start];
        Swap([CAMetalLayer class], @selector(nextDrawable), (IMP)FixNextDrawable, &oNextDrawable);
        Class dc = NSClassFromString(@"CAMetalDrawable");
        if (dc) Swap(dc, @selector(present), (IMP)FixPresent, &oPresent);
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (dev) {
            Class cc = object_getClass([[dev newCommandQueue] commandBuffer]);
            Swap(cc, @selector(presentDrawable:), (IMP)FixCBPresent, &oCBPresent);
            Swap(cc, @selector(presentDrawable:atTime:), (IMP)FixCBPresentAt, &oCBPresentAt);
            Swap(cc, @selector(presentDrawable:afterMinimumDuration:), (IMP)FixCBPresentAfter, &oCBPresentAfter);
        }
        __block unsigned ticks = 0;
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gGen);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(timer, ^{
            Poll();
            if (++ticks % 5 == 0) Report();
        });
        dispatch_resume(timer);
        static dispatch_source_t keep;
        keep = timer;
    }
}
