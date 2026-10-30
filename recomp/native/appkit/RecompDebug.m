// Diagnostics: a shipping game exits without a log, so the game's calls to
// exit/_Exit/abort (bound to the shim, see INTERCEPT in unreal_ios.py) print
// where they came from before doing what was asked. Mac game binaries usually
// keep their symbol table, so the backtrace names the engine functions.
#import "RecompAppKit.h"
#import <dlfcn.h>
#import <execinfo.h>

void *RecompRealSym(const char *name, void *mine);

static void Backtrace(const char *what, int code) {
    void *frames[48];
    int n = backtrace(frames, 48);
    char **names = backtrace_symbols(frames, n);
    NSMutableString *s = [NSMutableString stringWithFormat:@"%s(%d) called from:", what, code];
    for (int i = 1; i < n; i++) [s appendFormat:@"\n  %s", names[i]];
    free(names);
    RLOG(@"%@", s);
}

void exit(int code) {
    static void (*real)(int);
    if (!real) real = RecompRealSym("exit", (void *)exit);
    if (code) Backtrace("exit", code);
    real(code);
    __builtin_unreachable();
}

void _Exit(int code) {
    static void (*real)(int);
    if (!real) real = RecompRealSym("_Exit", (void *)_Exit);
    if (code) Backtrace("_Exit", code);
    real(code);
    __builtin_unreachable();
}

// UE4's clean quit asks the engine loop to end and exits with 0, so the hooks
// above stay silent. FMacPlatformMisc::RequestExit (QuitGame, the exit command,
// a closed game window), the fatal-error log device and the exit-time teardown
// are the engine's only callers of notify_cancel: its backtrace names who quit.
uint32_t notify_cancel(int token) {
    static uint32_t (*real)(int);
    if (!real) real = RecompRealSym("notify_cancel", (void *)notify_cancel);
    Backtrace("notify_cancel", token);
    return real(token);
}

void abort(void) {
    static void (*real)(void);
    if (!real) real = RecompRealSym("abort", (void *)abort);
    Backtrace("abort", 0);
    real();
    __builtin_unreachable();
}

// --- heartbeat and screenshots -----------------------------------------------------
// Every 10 s: drawables the game took (frames), the longest wait between two
// (a freeze), how many presented frames reached the screen (presentedTime > 0; iOS
// stops showing an app it no longer has in front, while the app keeps presenting),
// memory left before iOS ends the app, GPU time per frame, the CPU
// time of the busiest threads, and the time spent making pipeline states and
// loading shader libraries. A file named recomp-screenshot in Documents (put there with
// `devicectl device copy to`) makes the next tick save Documents/recomp-screen.png;
// one named recomp-press, holding gamepad steps ("down down A"), presses them
// on the on-screen gamepad's controller (RecompPadScript).

#import <objc/runtime.h>
#import <os/proc.h>
#import <stdatomic.h>
#import <mach/mach.h>
#import <Metal/Metal.h>
#import <GameController/GameController.h>
#import <pthread.h>

double RecompGPUSeconds(void);
void RecompMetalTimes(double out[6]);
static pthread_t gMainThread;

// The app's memory as iOS counts it against its limit, in MB.
static unsigned long long Footprint(void) {
    task_vm_info_data_t vm;
    mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &n) != KERN_SUCCESS) return 0;
    return vm.phys_footprint >> 20;
}

// CPU time of the app's threads since the last call, as % of one core: the
// total, then the busiest names. Threads named alike but for a number (the
// engine's task graph and pool workers) are summed, with their count; unnamed
// ones (the engine's game thread among them) go by their place in the list. nil on
// the first call, which only takes the starting times.
static NSString *ThreadCPU(double seconds) {
    static NSMutableDictionary<NSNumber *, NSNumber *> *last;
    NSMutableDictionary<NSNumber *, NSNumber *> *now = [NSMutableDictionary new];
    NSMutableDictionary<NSString *, NSNumber *> *used = [NSMutableDictionary new], *count = [NSMutableDictionary new];
    thread_act_array_t threads;
    mach_msg_type_number_t n = 0;
    if (task_threads(mach_task_self(), &threads, &n) != KERN_SUCCESS) return nil;
    NSCharacterSet *number = [NSCharacterSet characterSetWithCharactersInString:@"0123456789 #-_()"];
    double total = 0;
    for (mach_msg_type_number_t i = 0; i < n; i++) {
        thread_identifier_info_data_t ident;
        thread_extended_info_data_t ext;
        mach_msg_type_number_t c1 = THREAD_IDENTIFIER_INFO_COUNT, c2 = THREAD_EXTENDED_INFO_COUNT;
        if (thread_info(threads[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ident, &c1) == KERN_SUCCESS &&
            thread_info(threads[i], THREAD_EXTENDED_INFO, (thread_info_t)&ext, &c2) == KERN_SUCCESS) {
            uint64_t ns = ext.pth_user_time + ext.pth_system_time;
            now[@(ident.thread_id)] = @(ns);
            double t = (ns - [last[@(ident.thread_id)] unsignedLongLongValue]) / 1e9;
            NSString *name = [@(ext.pth_name) stringByTrimmingCharactersInSet:number];
            if (!name.length)
                name = pthread_from_mach_thread_np(threads[i]) == gMainThread ? @"main" : [NSString stringWithFormat:@"thread %u", i];
            used[name] = @(used[name].doubleValue + t);
            count[name] = @(count[name].intValue + 1);
            total += t;
        }
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, n * sizeof *threads);
    BOOL first = !last;
    last = now;
    if (first) return nil;
    NSMutableString *s = [NSMutableString stringWithFormat:@"CPU %.0f%%:", total / seconds * 100];
    NSArray *busiest = [used keysSortedByValueUsingSelector:@selector(compare:)].reverseObjectEnumerator.allObjects;
    for (NSString *name in [busiest subarrayWithRange:NSMakeRange(0, MIN(busiest.count, 6))]) {
        int k = count[name].intValue;
        [s appendFormat:@" %@%@ %.0f%%,", name, k > 1 ? [NSString stringWithFormat:@" x%d", k] : @"",
                        used[name].doubleValue / seconds * 100];
    }
    [s deleteCharactersInRange:NSMakeRange(s.length - 1, 1)];
    return s;
}

static atomic_uint gDrawables, gLongestFrameMs, gSlowFrames, gPresented, gOnScreen;
static atomic_uint gPresentedAll, gOnScreenAll; // since launch, for CheckShown
static IMP oNextDrawable;

// Only the engine's RHI thread takes drawables, so the last time needs no lock.
static id CountNextDrawable(id self, SEL s) {
    static double last;
    double now = CACurrentMediaTime();
    if (last) {
        unsigned ms = (now - last) * 1000;
        if (ms > atomic_load(&gLongestFrameMs)) atomic_store(&gLongestFrameMs, ms);
        if (ms > 100) atomic_fetch_add(&gSlowFrames, 1);
    }
    last = now;
    atomic_fetch_add(&gDrawables, 1);
    id<CAMetalDrawable> d = ((id (*)(id, SEL))oNextDrawable)(self, s);
    [d addPresentedHandler:^(id<MTLDrawable> p) {
        atomic_fetch_add(&gPresented, 1);
        atomic_fetch_add(&gPresentedAll, 1);
        if (p.presentedTime > 0) {
            atomic_fetch_add(&gOnScreen, 1);
            atomic_fetch_add(&gOnScreenAll, 1);
        }
    }];
    return d;
}

// iOS sometimes stops showing the app while it stays active: the screen is black,
// touch buttons included, the game renders and presents normally, and every drawable
// comes back unshown (presentedTime 0). Seen mid-play on 2026-10-30 at 16:17 (killed by
// iOS 1.5 min later) and after a relaunch over a running copy; going to the home screen
// and back brought the picture back. Called every 2 s: after two checks in a row where
// at least 20 frames were presented and none was shown, the window is hidden and shown
// again, at most once every 10 s.
static void CheckShown(void) {
    static unsigned lastPresented, lastShown, dark;
    static double lastTry;
    unsigned presented = atomic_load(&gPresentedAll), shown = atomic_load(&gOnScreenAll);
    BOOL black = presented - lastPresented >= 20 && shown == lastShown &&
                 UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    lastPresented = presented;
    lastShown = shown;
    dark = black ? dark + 1 : 0;
    if (dark < 2 || CACurrentMediaTime() - lastTry < 10) return;
    lastTry = CACurrentMediaTime();
    UIWindow *w = RecompRoot().window;
    static const char *scene[] = {"foreground active", "foreground inactive", "background"};
    UISceneActivationState st = w.windowScene.activationState;
    RLOG(@"screen: no frame shown for %u s while active (window %s, key %d, scene %s, layer hidden %d opacity %.1f): "
         @"window hidden and shown again", dark * 2, w ? (w.hidden ? "hidden" : "visible") : "none", w.isKeyWindow,
         st >= 0 && st <= 2 ? scene[st] : "unattached", w.layer.hidden, w.layer.opacity);
    w.hidden = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ [w makeKeyAndVisible]; });
}

// The app's state changes, with the state it is in: a black screen while the game
// keeps rendering, then a kill with no crash or jetsam report, pointed to the app
// losing the front without the game knowing.
static void LogAppStates(void) {
    static const char *state[] = {"active", "inactive", "background"};
    NSDictionary<NSNotificationName, NSString *> *names = @{
        UIApplicationWillResignActiveNotification: @"will resign active",
        UIApplicationDidBecomeActiveNotification: @"did become active",
        UIApplicationDidEnterBackgroundNotification: @"did enter background",
        UIApplicationWillEnterForegroundNotification: @"will enter foreground",
        UIApplicationDidReceiveMemoryWarningNotification: @"memory warning",
        UIApplicationProtectedDataWillBecomeUnavailable: @"device locking",
        UIApplicationWillTerminateNotification: @"will terminate",
    };
    for (NSNotificationName n in names)
        [NSNotificationCenter.defaultCenter addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *note) {
            UIApplicationState now = UIApplication.sharedApplication.applicationState;
            RLOG(@"app: %@ (state %s, %zu MB memory left)", names[n], now <= 2 ? state[now] : "?",
                 os_proc_available_memory() >> 20);
        }];
}

void RecompPadScript(NSArray<NSString *> *steps);

static void Press(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *trigger = [docs stringByAppendingPathComponent:@"recomp-press"];
    NSString *text = [NSString stringWithContentsOfFile:trigger encoding:NSUTF8StringEncoding error:nil];
    if (!text) return;
    [NSFileManager.defaultManager removeItemAtPath:trigger error:nil];
    NSPredicate *some = [NSPredicate predicateWithFormat:@"length > 0"];
    RecompPadScript([[text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                     filteredArrayUsingPredicate:some]);
}

static NSString *TagName(unsigned tag, BOOL file) {
    if (file) return @"file mappings";
    switch (tag) {
        case 0: return @"untagged (mmap/vm_allocate)";
        case 1: return @"malloc"; case 2: return @"malloc small"; case 3: return @"malloc large";
        case 4: return @"malloc huge"; case 7: return @"malloc tiny"; case 8: case 9: return @"malloc large reusable";
        case 11: return @"malloc nano"; case 12: return @"malloc medium"; case 21: return @"IOKit";
        case 30: return @"stacks"; case 33: return @"dylib"; case 51: return @"Core Animation";
        case 60: case 61: return @"dyld"; case 88: return @"IOSurface"; case 90: return @"audio";
        case 100: return @"IOAccelerator (Metal)";
    }
    return [NSString stringWithFormat:@"tag %u", tag];
}

// Dirty plus compressed memory (what iOS counts against the app) by kind of
// region, largest first, and the largest single regions.
static void MemoryBreakdown(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *trigger = [docs stringByAppendingPathComponent:@"recomp-memory"];
    if (![NSFileManager.defaultManager fileExistsAtPath:trigger]) return;
    [NSFileManager.defaultManager removeItemAtPath:trigger error:nil];
    NSMutableDictionary<NSString *, NSNumber *> *byKind = [NSMutableDictionary new], *virt = [NSMutableDictionary new];
    NSMutableArray *big = [NSMutableArray new];
    vm_address_t addr = 0;
    natural_t depth = 0;
    for (;;) {
        vm_size_t size = 0;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t n = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &addr, &size, &depth, (vm_region_recurse_info_t)&info, &n) != KERN_SUCCESS)
            break;
        if (info.is_submap) { depth++; continue; }
        unsigned long long cost = ((unsigned long long)info.pages_dirtied + info.pages_swapped_out) * vm_page_size;
        NSString *kind = TagName(info.user_tag, info.external_pager);
        byKind[kind] = @(byKind[kind].unsignedLongLongValue + cost);
        virt[kind] = @(virt[kind].unsignedLongLongValue + size);
        if (cost > (64ULL << 20))
            [big addObject:@[@(cost), [NSString stringWithFormat:@"0x%llx %llu MB virtual, %llu MB dirty+compressed, %@",
                                         (unsigned long long)addr, (unsigned long long)size >> 20, cost >> 20, kind]]];
        addr += size;
    }
    NSMutableString *out = [NSMutableString stringWithString:@"memory by kind (dirty+compressed / virtual):"];
    for (NSString *k in [byKind keysSortedByValueUsingSelector:@selector(compare:)].reverseObjectEnumerator)
        if (byKind[k].unsignedLongLongValue >= (8ULL << 20))
            [out appendFormat:@"\n  %@: %llu / %llu MB", k, byKind[k].unsignedLongLongValue >> 20, virt[k].unsignedLongLongValue >> 20];
    [big sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [b[0] compare:a[0]]; }];
    [out appendString:@"\nlargest regions:"];
    for (NSArray *r in [big subarrayWithRange:NSMakeRange(0, MIN(big.count, 12))]) [out appendFormat:@"\n  %@", r[1]];
    RLOG(@"%@", out);
}

// --- recording and replaying the gamepad ------------------------------------------
// A file named recomp-record in Documents starts recording the gamepad into
// Documents/recomp-recording, 60 times a second, a line per change: seconds since
// the start, both sticks, the d-pad, then the buttons and triggers. A second
// recomp-record ends it. recomp-replay plays the recording back on the gamepad's
// software controller (the on-screen one), so a heat run can repeat a player's walk
// without the player. The game is not deterministic: hitches and physics make a
// long replay drift away from the walk recorded.

// The axes, then the buttons; NSNull for a button this gamepad lacks.
static NSArray *PadElements(GCExtendedGamepad *g) {
    return @[g.leftThumbstick.xAxis, g.leftThumbstick.yAxis, g.rightThumbstick.xAxis, g.rightThumbstick.yAxis,
             g.dpad.xAxis, g.dpad.yAxis, g.buttonA, g.buttonB, g.buttonX, g.buttonY, g.leftShoulder,
             g.rightShoulder, g.leftTrigger, g.rightTrigger, g.leftThumbstickButton ?: NSNull.null,
             g.rightThumbstickButton ?: NSNull.null, g.buttonMenu, g.buttonOptions ?: NSNull.null];
}

static NSTimer *gPadTimer;

static void StopPadTimer(NSString *what) {
    [gPadTimer invalidate];
    gPadTimer = nil;
    RLOG(@"gamepad %@", what);
}

static void RecordPad(NSString *path) {
    GCExtendedGamepad *g = GCController.controllers.firstObject.extendedGamepad;
    if (!g) { RLOG(@"gamepad recording: no gamepad"); return; }
    [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:path];
    double start = CACurrentMediaTime();
    __block NSString *last = nil;
    RLOG(@"gamepad recording started");
    gPadTimer = [NSTimer scheduledTimerWithTimeInterval:1 / 60.0 repeats:YES block:^(NSTimer *t) {
        NSMutableArray *values = [NSMutableArray new];
        for (id e in PadElements(g))
            [values addObject:[NSString stringWithFormat:@"%.3f", [e isKindOfClass:[GCControllerAxisInput class]]
                                                                     ? ((GCControllerAxisInput *)e).value
                                                                     : e == NSNull.null ? 0
                                                                     : ((GCControllerButtonInput *)e).value]];
        NSString *state = [values componentsJoinedByString:@" "];
        if ([state isEqualToString:last]) return;
        last = state;
        [out writeData:[[NSString stringWithFormat:@"%.3f %@\n", CACurrentMediaTime() - start, state]
                           dataUsingEncoding:NSUTF8StringEncoding]];
    }];
}

static void ReplayPad(NSString *path) {
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    GCExtendedGamepad *g = GCController.controllers.firstObject.extendedGamepad;
    if (!text || !g) { RLOG(@"gamepad replay: %@", g ? @"no recording" : @"no gamepad"); return; }
    NSArray<NSString *> *rows = [text componentsSeparatedByString:@"\n"];
    NSArray *elements = PadElements(g);
    double start = CACurrentMediaTime();
    __block NSUInteger next = 0;
    RLOG(@"gamepad replay started: %lu changes over %@ s", (unsigned long)rows.count - 1,
         [rows[rows.count > 1 ? rows.count - 2 : 0] componentsSeparatedByString:@" "].firstObject);
    gPadTimer = [NSTimer scheduledTimerWithTimeInterval:1 / 120.0 repeats:YES block:^(NSTimer *t) {
        double now = CACurrentMediaTime() - start;
        NSArray<NSString *> *v = nil;
        for (; next < rows.count; next++) {
            NSArray<NSString *> *row = [rows[next] componentsSeparatedByString:@" "];
            if (row.count < elements.count + 1) continue;
            if (row[0].doubleValue > now) break;
            v = row;
        }
        if (v) {
            [g.leftThumbstick setValueForXAxis:v[1].floatValue yAxis:v[2].floatValue];
            [g.rightThumbstick setValueForXAxis:v[3].floatValue yAxis:v[4].floatValue];
            [g.dpad setValueForXAxis:v[5].floatValue yAxis:v[6].floatValue];
            for (NSUInteger i = 6; i < elements.count; i++)
                if (elements[i] != NSNull.null) [(GCControllerButtonInput *)elements[i] setValue:v[i + 1].floatValue];
        }
        if (next >= rows.count) StopPadTimer(@"replay ended");
    }];
}

static void PadRecording(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *record = [docs stringByAppendingPathComponent:@"recomp-record"],
             *replay = [docs stringByAppendingPathComponent:@"recomp-replay"],
             *recording = [docs stringByAppendingPathComponent:@"recomp-recording"];
    if ([fm fileExistsAtPath:record]) {
        [fm removeItemAtPath:record error:nil];
        if (gPadTimer) StopPadTimer(@"recording or replay stopped");
        else RecordPad(recording);
    } else if ([fm fileExistsAtPath:replay]) {
        [fm removeItemAtPath:replay error:nil];
        if (gPadTimer) StopPadTimer(@"recording or replay stopped");
        ReplayPad(recording);
    }
}

static void Screenshot(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *trigger = [docs stringByAppendingPathComponent:@"recomp-screenshot"];
    if (![NSFileManager.defaultManager fileExistsAtPath:trigger]) return;
    [NSFileManager.defaultManager removeItemAtPath:trigger error:nil];
    UIWindow *w = RecompRoot().window;
    if (!w) return;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithBounds:w.bounds];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [w drawViewHierarchyInRect:w.bounds afterScreenUpdates:NO];
    }];
    [UIImagePNGRepresentation(img) writeToFile:[docs stringByAppendingPathComponent:@"recomp-screen.png"] atomically:YES];
    RLOG(@"screenshot saved");
}

__attribute__((constructor)) static void RecompHeartbeat(void) {
    gMainThread = pthread_self();
    Method m = class_getInstanceMethod([CAMetalLayer class], @selector(nextDrawable));
    oNextDrawable = method_setImplementation(m, (IMP)CountNextDrawable);
    LogAppStates();
    dispatch_async(dispatch_get_main_queue(), ^{
        __block unsigned last = 0;
        __block int ticks = 0;
        __block double lastTime = CACurrentMediaTime(), lastGPU = RecompGPUSeconds();
        ThreadCPU(1);
        [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *t) {
            Screenshot();
            Press();
            PadRecording();
            MemoryBreakdown();
            CheckShown();
            if (++ticks % 5) return;
            unsigned now = atomic_load(&gDrawables);
            static id<MTLDevice> gpu;
            if (!gpu) gpu = MTLCreateSystemDefaultDevice();
            // A phone that runs hot slows its CPU and GPU down: frames and sound stutter.
            static const char *heat[] = {"nominal", "fair", "serious", "critical"};
            NSProcessInfoThermalState hot = NSProcessInfo.processInfo.thermalState;
            // Battery drain per minute is a quicker gauge of power than the thermal state;
            // a phone on its cable or at full brightness runs warmer.
            UIDevice *device = UIDevice.currentDevice;
            device.batteryMonitoringEnabled = YES;
            static const char *power[] = {"?", "unplugged", "charging", "full"};
            // GPU busy near 100% (ms per frame near the frame time) means the GPU
            // limits the game; a thread near 100% of a core means that thread does.
            double time = CACurrentMediaTime(), elapsed = time - lastTime, gpuTime = RecompGPUSeconds() - lastGPU;
            unsigned frames = now - last;
            double metal[6];
            RecompMetalTimes(metal);
            RLOG(@"heartbeat: %.1f frames/s (longest %u ms, %u over 100 ms; %u of %u presented reached the screen), %zu MB memory left (app %llu MB, of which "
                 @"Metal %lu MB), thermal %s, battery %.0f%% %s, brightness %.0f%%, GPU %.1f ms/frame (busy %.0f%%), %@; %.0f pipeline states made in %.0f ms "
                 @"(longest %.0f), %.0f shader libraries loaded in %.0f ms (longest %.0f)",
                 frames / elapsed, atomic_exchange(&gLongestFrameMs, 0), atomic_exchange(&gSlowFrames, 0),
                 atomic_exchange(&gOnScreen, 0), atomic_exchange(&gPresented, 0),
                 os_proc_available_memory() >> 20, Footprint(),
                 (unsigned long)(gpu.currentAllocatedSize >> 20), hot <= 3 ? heat[hot] : "?",
                 device.batteryLevel * 100, power[device.batteryState <= 3 ? device.batteryState : 0],
                 UIScreen.mainScreen.brightness * 100,
                 frames ? gpuTime * 1000 / frames : 0.0, gpuTime / elapsed * 100, ThreadCPU(elapsed),
                 metal[0], metal[1] * 1000, metal[2] * 1000, metal[3], metal[4] * 1000, metal[5] * 1000);
            last = now;
            lastTime = time;
            lastGPU += gpuTime;
        }];
    });
}
