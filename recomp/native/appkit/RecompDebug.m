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
#import <mach/mach.h>
#import <Metal/Metal.h>

// The app's memory as iOS counts it against its limit, in MB.
static unsigned long long Footprint(void) {
    task_vm_info_data_t vm;
    mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &n) != KERN_SUCCESS) return 0;
    return vm.phys_footprint >> 20;
}

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
            MemoryBreakdown();
            if (++ticks % 5) return;
            unsigned now = atomic_load(&gDrawables);
            static id<MTLDevice> gpu;
            if (!gpu) gpu = MTLCreateSystemDefaultDevice();
            RLOG(@"heartbeat: %.1f frames/s, %zu MB memory left (app %llu MB, of which Metal %lu MB)", (now - last) / 10.0,
                 os_proc_available_memory() >> 20, Footprint(), (unsigned long)(gpu.currentAllocatedSize >> 20));
            last = now;
        }];
    });
}
