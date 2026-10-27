// Metal on iOS versus macOS, for the same Apple GPU:
//  - MTLStorageModeManaged does not exist (creating a managed resource aborts);
//    it becomes Shared, which on unified memory needs no synchronisation, so
//    -didModifyRange: and the blit encoder's -synchronize* calls become no-ops;
//  - Mac GPU families and feature sets are reported as supported, since the
//    game checks for them and an Apple GPU on iOS is of the same families as the Mac's;
//  - Mac-only device and layer properties get the values an Apple Silicon Mac reports;
//  - metallibs from older tools (file format 2.3, e.g. Bink's) are refused while
//    their header says macOS; with that flag cleared the same code loads and runs;
//  - MetalFX needs nothing: the MetalFX scalers the game creates are only logged;
//  - command buffers wait while the app is inactive, since iOS refuses GPU work
//    from the background and the engine would stop with a fatal error;
//  - the GPU time of every command buffer, and the time the game's threads wait
//    for pipeline states and shader libraries, are added up for the heartbeat.
#import "RecompAppKit.h"
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <os/lock.h>

static const NSUInteger kManagedOption = 1 << MTLResourceStorageModeShift;
static const NSUInteger kStorageMask = 0xF << MTLResourceStorageModeShift;

static NSUInteger Unmanage(NSUInteger options) {
    return (options & kStorageMask) == kManagedOption ? options & ~kStorageMask : options;
}

static void Swizzle(Class c, SEL sel, IMP imp, IMP *orig) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) { RLOG(@"metal fix: %s has no %s", class_getName(c), sel_getName(sel)); return; }
    *orig = method_setImplementation(m, imp);
}

static void AddIfMissing(Class c, SEL sel, IMP imp, const char *types) {
    if (!class_respondsToSelector(c, sel)) class_addMethod(c, sel, imp, types);
}

// --- device -------------------------------------------------------------------------

static IMP oBuffer, oBufferBytes, oBufferNoCopy, oTexture, oHeap, oSupportsFamily, oSupportsFeatureSet;

static id FixBuffer(id self, SEL s, NSUInteger len, NSUInteger opts) {
    return ((id (*)(id, SEL, NSUInteger, NSUInteger))oBuffer)(self, s, len, Unmanage(opts));
}
static id FixBufferBytes(id self, SEL s, const void *p, NSUInteger len, NSUInteger opts) {
    return ((id (*)(id, SEL, const void *, NSUInteger, NSUInteger))oBufferBytes)(self, s, p, len, Unmanage(opts));
}
static id FixBufferNoCopy(id self, SEL s, void *p, NSUInteger len, NSUInteger opts, id dealloc) {
    return ((id (*)(id, SEL, void *, NSUInteger, NSUInteger, id))oBufferNoCopy)(self, s, p, len, Unmanage(opts), dealloc);
}
static id FixTexture(id self, SEL s, MTLTextureDescriptor *d) {
    if (d.storageMode == 1) d.storageMode = MTLStorageModeShared;
    return ((id (*)(id, SEL, id))oTexture)(self, s, d);
}
static id FixHeap(id self, SEL s, MTLHeapDescriptor *d) {
    if (d.storageMode == 1) d.storageMode = MTLStorageModeShared;
    return ((id (*)(id, SEL, id))oHeap)(self, s, d);
}
static BOOL FixSupportsFamily(id self, SEL s, NSInteger family) {
    // MTLGPUFamilyMac1/Mac2 (2001/2002), MacCatalyst1/2 (4001/4002)
    if (family == 2001 || family == 2002 || family == 4001 || family == 4002) return YES;
    return ((BOOL (*)(id, SEL, NSInteger))oSupportsFamily)(self, s, family);
}
static BOOL FixSupportsFeatureSet(id self, SEL s, NSUInteger fs) {
    if (fs >= 10000 && fs < 11000) return YES; // MTLFeatureSet_macOS_*
    return ((BOOL (*)(id, SEL, NSUInteger))oSupportsFeatureSet)(self, s, fs);
}
static BOOL ReturnNO(id self, SEL s) { return NO; }
static BOOL ReturnYES(id self, SEL s) { return YES; }
static NSUInteger ReturnZero(id self, SEL s) { return 0; }
static uint32_t ReturnOne32(id self, SEL s) { return 1; }

// --- time spent waiting for Metal -----------------------------------------------------
// Pipeline states made on the caller's thread (the engine's render and RHI threads
// wait for them; the driver compiles each one the first time it is asked for) and
// shader libraries loaded: how many, how long in all, the longest. Calls nested in
// a timed one (a variant calling another, a library retried) count once.

static os_unfair_lock gTimeLock = OS_UNFAIR_LOCK_INIT;
static double gTimes[6]; // pipelines: count, seconds, longest; libraries: the same
static __thread int gTimedDepth;

static double TimedStart(void) { return gTimedDepth++ ? 0 : CACurrentMediaTime(); }
static void TimedEnd(int kind, double start) {
    if (--gTimedDepth) return;
    double t = CACurrentMediaTime() - start, *k = gTimes + kind * 3;
    os_unfair_lock_lock(&gTimeLock);
    k[0]++;
    k[1] += t;
    k[2] = MAX(k[2], t);
    os_unfair_lock_unlock(&gTimeLock);
}

// The totals since the last call.
void RecompMetalTimes(double out[6]) {
    os_unfair_lock_lock(&gTimeLock);
    memcpy(out, gTimes, sizeof gTimes);
    memset(gTimes, 0, sizeof gTimes);
    os_unfair_lock_unlock(&gTimeLock);
}

static IMP oRenderPipe, oRenderPipeRefl, oComputePipe, oComputePipeRefl, oComputePipeDesc;

static id TimeRenderPipe(id self, SEL s, id d, NSError **e) {
    double t = TimedStart();
    id p = ((id (*)(id, SEL, id, NSError **))oRenderPipe)(self, s, d, e);
    TimedEnd(0, t);
    return p;
}
static id TimeRenderPipeRefl(id self, SEL s, id d, NSUInteger o, id *r, NSError **e) {
    double t = TimedStart();
    id p = ((id (*)(id, SEL, id, NSUInteger, id *, NSError **))oRenderPipeRefl)(self, s, d, o, r, e);
    TimedEnd(0, t);
    return p;
}
static id TimeComputePipe(id self, SEL s, id f, NSError **e) {
    double t = TimedStart();
    id p = ((id (*)(id, SEL, id, NSError **))oComputePipe)(self, s, f, e);
    TimedEnd(0, t);
    return p;
}
static id TimeComputePipeRefl(id self, SEL s, id f, NSUInteger o, id *r, NSError **e) {
    double t = TimedStart();
    id p = ((id (*)(id, SEL, id, NSUInteger, id *, NSError **))oComputePipeRefl)(self, s, f, o, r, e);
    TimedEnd(0, t);
    return p;
}
static id TimeComputePipeDesc(id self, SEL s, id d, NSUInteger o, id *r, NSError **e) {
    double t = TimedStart();
    id p = ((id (*)(id, SEL, id, NSUInteger, id *, NSError **))oComputePipeDesc)(self, s, d, o, r, e);
    TimedEnd(0, t);
    return p;
}

// --- shader libraries --------------------------------------------------------------

static IMP oLibData, oLibFile, oLibURL;

// A copy of a metallib with the macOS flag (bit 15 of the platform field) cleared,
// or nil when the data is not a macOS metallib.
static dispatch_data_t WithoutMacFlag(dispatch_data_t data) {
    const void *bytes = NULL;
    size_t len = 0;
    dispatch_data_t flat = dispatch_data_create_map(data, &bytes, &len);
    if (len < 8 || memcmp(bytes, "MTLB", 4) || !(((const uint8_t *)bytes)[5] & 0x80)) return nil;
    void *copy = malloc(len);
    memcpy(copy, bytes, len);
    ((uint8_t *)copy)[5] &= 0x7F;
    (void)flat;
    return dispatch_data_create(copy, len, NULL, DISPATCH_DATA_DESTRUCTOR_FREE);
}

static id FixLibData(id self, SEL s, dispatch_data_t data, NSError **err) {
    double t = TimedStart();
    NSError *e = nil;
    id lib = ((id (*)(id, SEL, dispatch_data_t, NSError **))oLibData)(self, s, data, &e);
    if (!lib && [e.domain isEqualToString:MTLLibraryErrorDomain]) {
        dispatch_data_t fixed = WithoutMacFlag(data);
        if (fixed) lib = ((id (*)(id, SEL, dispatch_data_t, NSError **))oLibData)(self, s, fixed, &e);
        static dispatch_once_t once;
        if (lib) dispatch_once(&once, ^{ RLOG(@"metallib from older tools: loaded with the macOS flag cleared (the others are counted in the heartbeat)"); });
    }
    TimedEnd(1, t);
    if (!lib && err) *err = e;
    return lib;
}
static id LibFromPath(id self, NSString *path, NSError **err, id lib, NSError *e) {
    if (!lib && path) {
        NSData *d = [NSData dataWithContentsOfFile:path];
        if (d) {
            dispatch_data_t dd = dispatch_data_create(d.bytes, d.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
            lib = FixLibData(self, @selector(newLibraryWithData:error:), dd, &e);
        }
    }
    if (!lib && err) *err = e;
    return lib;
}
static id FixLibFile(id self, SEL s, NSString *path, NSError **err) {
    double t = TimedStart();
    NSError *e = nil;
    id lib = ((id (*)(id, SEL, NSString *, NSError **))oLibFile)(self, s, path, &e);
    lib = LibFromPath(self, path, err, lib, e);
    TimedEnd(1, t);
    return lib;
}
static id FixLibURL(id self, SEL s, NSURL *url, NSError **err) {
    double t = TimedStart();
    NSError *e = nil;
    id lib = ((id (*)(id, SEL, NSURL *, NSError **))oLibURL)(self, s, url, &e);
    lib = LibFromPath(self, url.path, err, lib, e);
    TimedEnd(1, t);
    return lib;
}

// --- descriptors ---------------------------------------------------------------------

static IMP oTexSetStorage, oTexSetOptions, oHeapSetStorage;
static void FixTexSetStorage(id self, SEL s, NSUInteger mode) {
    ((void (*)(id, SEL, NSUInteger))oTexSetStorage)(self, s, mode == 1 ? MTLStorageModeShared : mode);
}
static void FixTexSetOptions(id self, SEL s, NSUInteger opts) {
    ((void (*)(id, SEL, NSUInteger))oTexSetOptions)(self, s, Unmanage(opts));
}
static void FixHeapSetStorage(id self, SEL s, NSUInteger mode) {
    ((void (*)(id, SEL, NSUInteger))oHeapSetStorage)(self, s, mode == 1 ? MTLStorageModeShared : mode);
}

// --- MetalFX ---------------------------------------------------------------------------
// MetalFX runs on iOS as it does on the Mac; the game builds a scaler whenever its
// render size changes. Logged once per scaler, to show the upscale actually in use.

static IMP oNewTemporalScaler, oNewSpatialScaler;
static void LogScaler(const char *kind, id d, id scaler) {
    RLOG(@"MetalFX: %s scaler %@x%@ -> %@x%@%s", kind, [d valueForKey:@"inputWidth"], [d valueForKey:@"inputHeight"],
         [d valueForKey:@"outputWidth"], [d valueForKey:@"outputHeight"], scaler ? "" : " refused");
}
static id FixNewTemporalScaler(id self, SEL s, id dev) {
    id scaler = ((id (*)(id, SEL, id))oNewTemporalScaler)(self, s, dev);
    LogScaler("temporal", self, scaler);
    return scaler;
}
static id FixNewSpatialScaler(id self, SEL s, id dev) {
    id scaler = ((id (*)(id, SEL, id))oNewSpatialScaler)(self, s, dev);
    LogScaler("spatial", self, scaler);
    return scaler;
}

// --- background ------------------------------------------------------------------------
// iOS refuses GPU work from an app in the background, and the engine treats a refused
// command buffer as a fatal error: a Mac build never pauses its renderer. While the app
// is inactive, commits from the game's threads wait until it is active again (the main
// thread, which the engine never renders on, is not held). The lock also makes the last
// commit before the hold known, so that work can finish while the GPU is still allowed.

static IMP oCommit, oCommitUnretained;
static NSCondition *gGate;
static BOOL gHold;
static id gLastCommit;

// Seconds the GPU spent on the game's work since launch. Command buffers overlap
// on the GPU, so each one adds only the part of its run after the latest end seen.
static os_unfair_lock gGPULock = OS_UNFAIR_LOCK_INIT;
static double gGPUBusy, gGPULastEnd;

double RecompGPUSeconds(void) {
    os_unfair_lock_lock(&gGPULock);
    double busy = gGPUBusy;
    os_unfair_lock_unlock(&gGPULock);
    return busy;
}

static void CountGPUTime(id<MTLCommandBuffer> b) {
    double start = b.GPUStartTime, end = b.GPUEndTime;
    if (end <= start) return;
    os_unfair_lock_lock(&gGPULock);
    if (end > gGPULastEnd) {
        gGPUBusy += end - MAX(start, gGPULastEnd);
        gGPULastEnd = end;
    }
    os_unfair_lock_unlock(&gGPULock);
}

static void Commit(IMP orig, id self, SEL s) {
    [gGate lock];
    while (gHold && !NSThread.isMainThread) [gGate wait];
    gLastCommit = self;
    [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> b) { CountGPUTime(b); }];
    ((void (*)(id, SEL))orig)(self, s);
    [gGate unlock];
}
static void FixCommit(id self, SEL s) { Commit(oCommit, self, s); }
static void FixCommitUnretained(id self, SEL s) { Commit(oCommitUnretained, self, s); }

static void HoldGPUWork(NSNotification *n) {
    [gGate lock];
    gHold = YES;
    id<MTLCommandBuffer> last = gLastCommit;
    gLastCommit = nil;
    [gGate unlock];
    for (int i = 0; i < 100 && last.status < MTLCommandBufferStatusCompleted; i++) usleep(10000);
    RLOG(@"Metal: app inactive, GPU work held");
}
static void ReleaseGPUWork(NSNotification *n) {
    [gGate lock];
    BOOL was = gHold;
    gHold = NO;
    [gGate broadcast];
    [gGate unlock];
    if (was) RLOG(@"Metal: app active, GPU work resumed");
}

static void NoOp1(id self, SEL s, id a) {}
static void NoOpRange(id self, SEL s, NSRange r) {}
static void NoOpSync3(id self, SEL s, id t, NSUInteger slice, NSUInteger level) {}

@implementation CAMetalLayer (RecompMac)
- (BOOL)displaySyncEnabled { return YES; }
- (void)setDisplaySyncEnabled:(BOOL)b {}
@end

__attribute__((constructor)) static void RecompMetalInit(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { RLOG(@"no Metal device"); return; }
        Class dc = object_getClass(dev);
        Swizzle(dc, @selector(newBufferWithLength:options:), (IMP)FixBuffer, &oBuffer);
        Swizzle(dc, @selector(newBufferWithBytes:length:options:), (IMP)FixBufferBytes, &oBufferBytes);
        Swizzle(dc, @selector(newBufferWithBytesNoCopy:length:options:deallocator:), (IMP)FixBufferNoCopy, &oBufferNoCopy);
        Swizzle(dc, @selector(newTextureWithDescriptor:), (IMP)FixTexture, &oTexture);
        Swizzle(dc, @selector(newHeapWithDescriptor:), (IMP)FixHeap, &oHeap);
        Swizzle(dc, @selector(supportsFamily:), (IMP)FixSupportsFamily, &oSupportsFamily);
        Swizzle(dc, @selector(newLibraryWithData:error:), (IMP)FixLibData, &oLibData);
        Swizzle(dc, @selector(newLibraryWithFile:error:), (IMP)FixLibFile, &oLibFile);
        Swizzle(dc, @selector(newLibraryWithURL:error:), (IMP)FixLibURL, &oLibURL);
        Swizzle(dc, @selector(supportsFeatureSet:), (IMP)FixSupportsFeatureSet, &oSupportsFeatureSet);
        Swizzle(dc, @selector(newRenderPipelineStateWithDescriptor:error:), (IMP)TimeRenderPipe, &oRenderPipe);
        Swizzle(dc, @selector(newRenderPipelineStateWithDescriptor:options:reflection:error:), (IMP)TimeRenderPipeRefl, &oRenderPipeRefl);
        Swizzle(dc, @selector(newComputePipelineStateWithFunction:error:), (IMP)TimeComputePipe, &oComputePipe);
        Swizzle(dc, @selector(newComputePipelineStateWithFunction:options:reflection:error:), (IMP)TimeComputePipeRefl, &oComputePipeRefl);
        Swizzle(dc, @selector(newComputePipelineStateWithDescriptor:options:reflection:error:), (IMP)TimeComputePipeDesc, &oComputePipeDesc);
        AddIfMissing(dc, @selector(isLowPower), (IMP)ReturnNO, "B@:");
        AddIfMissing(dc, @selector(isHeadless), (IMP)ReturnNO, "B@:");
        AddIfMissing(dc, @selector(isRemovable), (IMP)ReturnNO, "B@:");
        AddIfMissing(dc, @selector(isDepth24Stencil8PixelFormatSupported), (IMP)ReturnNO, "B@:");
        AddIfMissing(dc, @selector(location), (IMP)ReturnZero, "Q@:");
        AddIfMissing(dc, @selector(locationNumber), (IMP)ReturnZero, "Q@:");
        AddIfMissing(dc, @selector(maxTransferRate), (IMP)ReturnZero, "Q@:");
        AddIfMissing(dc, @selector(peerGroupID), (IMP)ReturnZero, "Q@:");
        AddIfMissing(dc, @selector(peerIndex), (IMP)ReturnZero, "I@:");
        AddIfMissing(dc, @selector(peerCount), (IMP)ReturnOne32, "I@:");
        AddIfMissing(dc, @selector(areBarycentricCoordsSupported), (IMP)ReturnYES, "B@:");

        Class tc = object_getClass([MTLTextureDescriptor new]);
        Swizzle(tc, @selector(setStorageMode:), (IMP)FixTexSetStorage, &oTexSetStorage);
        Swizzle(tc, @selector(setResourceOptions:), (IMP)FixTexSetOptions, &oTexSetOptions);
        Class hc = object_getClass([MTLHeapDescriptor new]);
        Swizzle(hc, @selector(setStorageMode:), (IMP)FixHeapSetStorage, &oHeapSetStorage);
        Class mfxt = NSClassFromString(@"MTLFXTemporalScalerDescriptor"), mfxs = NSClassFromString(@"MTLFXSpatialScalerDescriptor");
        if (mfxt) Swizzle(mfxt, @selector(newTemporalScalerWithDevice:), (IMP)FixNewTemporalScaler, &oNewTemporalScaler);
        if (mfxs) Swizzle(mfxs, @selector(newSpatialScalerWithDevice:), (IMP)FixNewSpatialScaler, &oNewSpatialScaler);

        gGate = [NSCondition new];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        Swizzle(object_getClass([q commandBuffer]), @selector(commit), (IMP)FixCommit, &oCommit);
        Class uc = object_getClass([q commandBufferWithUnretainedReferences]);
        if (class_getMethodImplementation(uc, @selector(commit)) != (IMP)FixCommit)
            Swizzle(uc, @selector(commit), (IMP)FixCommitUnretained, &oCommitUnretained);
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) { HoldGPUWork(n); }];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) { ReleaseGPUWork(n); }];

        // Buffers and blit encoders come in several concrete classes. Where iOS
        // classes define the managed-memory calls, they only assert; replace those,
        // and give every other class no-op versions through NSObject.
        struct { SEL sel; IMP imp; const char *types; } noops[] = {
            {@selector(didModifyRange:), (IMP)NoOpRange, "v@:{_NSRange=QQ}"},
            {@selector(synchronizeResource:), (IMP)NoOp1, "v@:@"},
            {@selector(synchronizeTexture:slice:level:), (IMP)NoOpSync3, "v@:@QQ"},
        };
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        int replaced = 0;
        for (unsigned int i = 0; i < count; i++) {
            const char *name = class_getName(classes[i]);
            if (strncmp(name, "MTL", 3) && strncmp(name, "AGX", 3) && strncmp(name, "IOGPU", 5) && strncmp(name, "_MTL", 4)) continue;
            Class super = class_getSuperclass(classes[i]);
            for (size_t k = 0; k < sizeof noops / sizeof noops[0]; k++) {
                Method m = class_getInstanceMethod(classes[i], noops[k].sel);
                if (m && (!super || method_getImplementation(m) != class_getMethodImplementation(super, noops[k].sel))) {
                    method_setImplementation(m, noops[k].imp);
                    replaced++;
                }
            }
        }
        free(classes);
        for (size_t k = 0; k < sizeof noops / sizeof noops[0]; k++)
            class_addMethod([NSObject class], noops[k].sel, noops[k].imp, noops[k].types);
        RLOG(@"Metal: %@ (Mac families reported, managed storage -> shared, %d managed-sync methods made no-ops)", dev.name, replaced);
    }
}
