// macOS display services games call: Quartz Display Services (CGDisplay*,
// cursor control), CVDisplayLink, and the IOKit/Kext queries iOS lacks.
// There is one display: the iPad screen, sized in points like NSScreen.
#import "RecompAppKit.h"
#import <mach/mach_time.h>

typedef uint32_t CGDirectDisplayID;

static CGDirectDisplayID const kMainDisplay = 1;

// --- display modes ------------------------------------------------------------------

@interface RecompDisplayMode : NSObject
@property size_t width, height;
@property double refresh;
@end
@implementation RecompDisplayMode
@end

static NSArray *Modes(void) {
    static NSArray *modes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGSize s = RecompScreenSize();
        CGFloat scale = RecompScreenScale();
        double hz = UIScreen.mainScreen.maximumFramesPerSecond >= 120 ? 120 : 60;
        NSMutableArray *a = [NSMutableArray new];
        // Native pixels first, then the point size and steps between: windows larger
        // than the screen in points are scaled down to fit, so each one is a render resolution.
        // Render targets at full native resolution take a lot of shared memory:
        // devices with 8 GB or less stop at 1.5x the point size.
        CGFloat cap = NSProcessInfo.processInfo.physicalMemory <= (8.5 * (1ULL << 30)) ? MIN(scale, 1.5) : scale;
        for (NSNumber *f in @[@(scale), @(scale * 0.75), @1.0, @0.75]) {
            CGFloat k = f.doubleValue;
            if (k > cap + 0.01) continue;
            RecompDisplayMode *m = [RecompDisplayMode new];
            m.width = (size_t)round(s.width * k);
            m.height = (size_t)round(s.height * k);
            m.refresh = hz;
            BOOL dup = NO;
            for (RecompDisplayMode *o in a) dup |= o.width == m.width;
            if (!dup) [a addObject:m];
        }
        modes = a;
    });
    return modes;
}

static RecompDisplayMode *gCurrentMode;

CGDirectDisplayID CGMainDisplayID(void) { return kMainDisplay; }

CGError CGGetActiveDisplayList(uint32_t max, CGDirectDisplayID *displays, uint32_t *count) {
    if (displays && max > 0) displays[0] = kMainDisplay;
    if (count) *count = 1;
    return 0;
}

// Quartz global coordinates: origin top-left of the main display.
CGRect CGDisplayBounds(CGDirectDisplayID d) {
    CGSize s = RecompScreenSize();
    return CGRectMake(0, 0, s.width, s.height);
}
size_t CGDisplayPixelsWide(CGDirectDisplayID d) { return (size_t)RecompScreenSize().width; }
size_t CGDisplayPixelsHigh(CGDirectDisplayID d) { return (size_t)RecompScreenSize().height; }

// Physical size in millimetres, from the screen's native pixels (264 ppi on iPad Pro).
CGSize CGDisplayScreenSize(CGDirectDisplayID d) {
    CGSize s = RecompScreenSize();
    CGFloat px = RecompScreenScale();
    return CGSizeMake(s.width * px / 264.0 * 25.4, s.height * px / 264.0 * 25.4);
}
uint32_t CGDisplayModelNumber(CGDirectDisplayID d) { return 0; }
uint32_t CGDisplayVendorNumber(CGDirectDisplayID d) { return 0x610; } // Apple
uint32_t CGDisplaySerialNumber(CGDirectDisplayID d) { return 0; }

void *CGDisplayCopyDisplayMode(CGDirectDisplayID d) {
    RecompDisplayMode *m = gCurrentMode ?: Modes().firstObject;
    return (void *)CFBridgingRetain(m);
}
CFArrayRef CGDisplayCopyAllDisplayModes(CGDirectDisplayID d, CFDictionaryRef options) {
    return (CFArrayRef)CFBridgingRetain(Modes());
}
size_t CGDisplayModeGetWidth(void *m) { return m ? [(__bridge RecompDisplayMode *)m width] : 0; }
size_t CGDisplayModeGetHeight(void *m) { return m ? [(__bridge RecompDisplayMode *)m height] : 0; }
size_t CGDisplayModeGetPixelWidth(void *m) { return CGDisplayModeGetWidth(m); }
size_t CGDisplayModeGetPixelHeight(void *m) { return CGDisplayModeGetHeight(m); }
double CGDisplayModeGetRefreshRate(void *m) { return m ? [(__bridge RecompDisplayMode *)m refresh] : 60; }
bool CGDisplayModeIsUsableForDesktopGUI(void *m) { return true; }
void *CGDisplayModeRetain(void *m) { if (m) CFRetain(m); return m; }
void CGDisplayModeRelease(void *m) { if (m) CFRelease(m); }
CGError CGDisplaySetDisplayMode(CGDirectDisplayID d, void *m, CFDictionaryRef o) {
    if (m) gCurrentMode = (__bridge RecompDisplayMode *)m;
    return 0;
}
CGError CGDisplayRegisterReconfigurationCallback(void *cb, void *ctx) { return 0; }
CGError CGDisplayRemoveReconfigurationCallback(void *cb, void *ctx) { return 0; }
const CFStringRef kCGDisplayShowDuplicateLowResolutionModes = CFSTR("kCGDisplayShowDuplicateLowResolutionModes");

// --- cursor ------------------------------------------------------------------------

static BOOL gCursorVisible = YES;
CGError CGDisplayHideCursor(CGDirectDisplayID d) { gCursorVisible = NO; RecompSetCursorHidden(YES); return 0; }
CGError CGDisplayShowCursor(CGDirectDisplayID d) { gCursorVisible = YES; RecompSetCursorHidden(NO); return 0; }
int CGCursorIsVisible(void) { return gCursorVisible; }
CGError CGAssociateMouseAndMouseCursorPosition(int connected) { RecompSetPointerLocked(!connected); return 0; }
CGError CGWarpMouseCursorPosition(CGPoint p) {
    RecompMouseLocation = CGPointMake(p.x, RecompScreenSize().height - p.y);
    return 0;
}

// --- fades and sessions -------------------------------------------------------------

CGError CGAcquireDisplayFadeReservation(float seconds, uint32_t *token) { if (token) *token = 1; return 0; }
CGError CGDisplayFade(uint32_t token, float duration, float from, float to, float r, float g, float b, int sync) { return 0; }
CGError CGReleaseDisplayFadeReservation(uint32_t token) { return 0; }
CFDictionaryRef CGSessionCopyCurrentDictionary(void) {
    return (CFDictionaryRef)CFBridgingRetain(@{@"kCGSessionOnConsoleKey": @YES, @"kCGSessionLoginDoneKey": @YES});
}

// --- CVDisplayLink ---------------------------------------------------------------------

typedef struct {
    uint32_t version;
    int32_t videoTimeScale;
    int64_t videoTime;
    uint64_t hostTime;
    double rateScalar;
    int64_t videoRefreshPeriod;
    int16_t smpte[12]; // CVSMPTETime, unused
    uint64_t flags;
    uint64_t reserved;
} RecompCVTimeStamp;

typedef int32_t (*RecompCVOutput)(void *link, const RecompCVTimeStamp *now, const RecompCVTimeStamp *out,
                                  uint64_t flagsIn, uint64_t *flagsOut, void *ctx);

// Drives the callback from a CADisplayLink on its own thread, as CVDisplayLink does.
@interface RecompDisplayLink : NSObject
@property RecompCVOutput callback;
@property void *context;
@property (strong) NSThread *thread;
@end
@implementation RecompDisplayLink
- (void)run {
    CADisplayLink *dl = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    NSInteger fps = UIScreen.mainScreen.maximumFramesPerSecond;
    dl.preferredFrameRateRange = CAFrameRateRangeMake(60, fps, fps);
    [dl addToRunLoop:NSRunLoop.currentRunLoop forMode:NSDefaultRunLoopMode];
    while (!NSThread.currentThread.isCancelled) @autoreleasepool { [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]]; }
    [dl invalidate];
}
- (void)tick:(CADisplayLink *)dl {
    if (!self.callback) return;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    RecompCVTimeStamp now = {0}, out = {0};
    int32_t scale = 1000000000;
    now.videoTimeScale = out.videoTimeScale = scale;
    now.rateScalar = out.rateScalar = 1;
    now.videoRefreshPeriod = out.videoRefreshPeriod = (int64_t)((dl.targetTimestamp - dl.timestamp) * scale);
    now.hostTime = mach_absolute_time();
    now.videoTime = (int64_t)(dl.timestamp * scale);
    out.hostTime = now.hostTime + (uint64_t)((dl.targetTimestamp - CACurrentMediaTime()) * 1e9 * tb.denom / tb.numer);
    out.videoTime = (int64_t)(dl.targetTimestamp * scale);
    now.flags = out.flags = 1 | 2; // video time and host time valid
    uint64_t flagsOut = 0;
    self.callback((__bridge void *)self, &now, &out, 0, &flagsOut, self.context);
}
@end

int32_t CVDisplayLinkCreateWithActiveCGDisplays(void **out) {
    *out = (void *)CFBridgingRetain([RecompDisplayLink new]);
    return 0;
}
int32_t CVDisplayLinkCreateWithCGDisplay(CGDirectDisplayID d, void **out) { return CVDisplayLinkCreateWithActiveCGDisplays(out); }
int32_t CVDisplayLinkSetOutputCallback(void *link, RecompCVOutput cb, void *ctx) {
    RecompDisplayLink *l = (__bridge RecompDisplayLink *)link;
    l.callback = cb;
    l.context = ctx;
    return 0;
}
int32_t CVDisplayLinkStart(void *link) {
    RecompDisplayLink *l = (__bridge RecompDisplayLink *)link;
    if (l.thread) return 0;
    l.thread = [[NSThread alloc] initWithTarget:l selector:@selector(run) object:nil];
    l.thread.name = @"CVDisplayLink";
    l.thread.qualityOfService = NSQualityOfServiceUserInteractive;
    [l.thread start];
    return 0;
}
int32_t CVDisplayLinkStop(void *link) {
    RecompDisplayLink *l = (__bridge RecompDisplayLink *)link;
    [l.thread cancel];
    l.thread = nil;
    return 0;
}
void CVDisplayLinkRelease(void *link) { if (link) CFRelease(link); }
int CVDisplayLinkIsRunning(void *link) { return [(__bridge RecompDisplayLink *)link thread] != nil; }
double CVDisplayLinkGetActualOutputVideoRefreshPeriod(void *link) {
    return 1.0 / MAX(UIScreen.mainScreen.maximumFramesPerSecond, 1);
}
CGDirectDisplayID CVDisplayLinkGetCurrentCGDisplay(void *link) { return kMainDisplay; }
int32_t CVDisplayLinkSetCurrentCGDisplay(void *link, CGDirectDisplayID d) { return 0; }

// --- IOKit and Metal bits iOS does not export -------------------------------------------

CFDictionaryRef IODisplayCreateInfoDictionary(uint32_t service, uint32_t options) {
    return (CFDictionaryRef)CFBridgingRetain(@{});
}
CFDictionaryRef KextManagerCopyLoadedKextInfo(CFArrayRef ids, CFArrayRef keys) {
    return (CFDictionaryRef)CFBridgingRetain(@{});
}
CFURLRef KextManagerCreateURLForBundleIdentifier(CFAllocatorRef a, CFStringRef bundleID) { return NULL; }
void MTLRemoveDeviceObserver(id observer) {}
