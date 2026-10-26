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

void abort(void) {
    static void (*real)(void);
    if (!real) real = RecompRealSym("abort", (void *)abort);
    Backtrace("abort", 0);
    real();
    __builtin_unreachable();
}

// --- heartbeat and screenshots -----------------------------------------------------
// Every 10 s: drawables the game took (frames) and memory left before iOS ends
// the app. A file named recomp-screenshot in Documents (put there with
// `devicectl device copy to`) makes the next tick save Documents/recomp-screen.png;
// one named recomp-press, holding gamepad steps ("down down A"), presses them
// on the on-screen gamepad's controller (RecompPadScript).

#import <objc/runtime.h>
#import <os/proc.h>
#import <stdatomic.h>

static atomic_uint gDrawables;
static IMP oNextDrawable;

static id CountNextDrawable(id self, SEL s) {
    atomic_fetch_add(&gDrawables, 1);
    return ((id (*)(id, SEL))oNextDrawable)(self, s);
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
    Method m = class_getInstanceMethod([CAMetalLayer class], @selector(nextDrawable));
    oNextDrawable = method_setImplementation(m, (IMP)CountNextDrawable);
    dispatch_async(dispatch_get_main_queue(), ^{
        __block unsigned last = 0;
        __block int ticks = 0;
        [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *t) {
            Screenshot();
            Press();
            if (++ticks % 5) return;
            unsigned now = atomic_load(&gDrawables);
            RLOG(@"heartbeat: %.1f frames/s, %zu MB memory left", (now - last) / 10.0, os_proc_available_memory() >> 20);
            last = now;
        }];
    });
}
