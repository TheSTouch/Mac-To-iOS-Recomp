// IOKit registry answers a Mac game expects about its GPU and machine.
//
// Unreal (FMacPlatformGPUManager) finds an Apple Silicon GPU by matching
// AppleARMIODevice entries whose device_type is "sgx" and reading their
// IOAccelerator child; on iOS the sandbox hides the registry, the GPU list
// comes back empty and the Metal RHI indexes into it. These functions are
// bound to the shim for the game (see INTERCEPT in unreal_ios.py) and answer
// those queries with what an M1 Mac reports, using the real Metal device's
// name and registry ID; every other query goes to the real IOKit.
#import "RecompAppKit.h"
#import <Metal/Metal.h>
#import <dlfcn.h>
#import <sys/sysctl.h>

typedef uint32_t io_object_t;
typedef int32_t kern_return_t;

enum { kFakeBase = 0x7FFE0000, kSGX = kFakeBase + 1, kAccel, kPlatform, kIterBase = kFakeBase + 0x100 };

static void *IOKitSym(const char *name) {
    static void *h;
    if (!h) h = dlopen("/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit", RTLD_LAZY | RTLD_NOLOAD);
    if (!h) h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    return h ? dlsym(h, name) : NULL;
}
#define REAL(ret, name, ...) static ret (*real)(__VA_ARGS__); if (!real) real = IOKitSym(#name)

static BOOL IsFake(io_object_t o) { return o > kFakeBase && o < kFakeBase + 0x10000; }

// Fake iterators: handle -> remaining entries.
static NSMutableDictionary<NSNumber *, NSMutableArray *> *gIters;
static io_object_t gNextIter = kIterBase;

static io_object_t NewIterator(NSArray *entries) {
    @synchronized ([NSObject class]) {
        if (!gIters) gIters = [NSMutableDictionary new];
        io_object_t h = gNextIter++;
        gIters[@(h)] = [entries mutableCopy];
        return h;
    }
}

static NSDictionary *Props(io_object_t o) {
    static NSDictionary *sgx, *accel, *platform;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        NSString *model = [dev.name stringByReplacingOccurrencesOfString:@" GPU" withString:@""] ?: @"Apple M1";
        uint32_t vendor = 0x106B; // Apple
        sgx = @{@"device_type": [NSData dataWithBytes:"sgx" length:4], @"name": [NSData dataWithBytes:"sgx" length:4],
                @"IOClass": @"AppleARMIODevice"};
        accel = @{@"IOClass": @"AGXAcceleratorG13X", @"IOMatchCategory": @"IOAccelerator",
                  @"IOProviderClass": @"AppleARMIODevice", @"CFBundleIdentifier": @"com.apple.AGXG13X",
                  @"MetalPluginName": @"AGXMetalG13X", @"MetalPluginClassName": @"AGXG13XDevice",
                  @"IOGLBundleName": @"AppleMetalOpenGLRenderer", @"model": model,
                  @"vendor-id": [NSData dataWithBytes:&vendor length:4], @"gpu-core-count": @8,
                  @"IORegistryEntryID": @(dev.registryID)};
        NSString *uuid = UIDevice.currentDevice.identifierForVendor.UUIDString ?: @"00000000-0000-0000-0000-000000000000";
        platform = @{@"IOPlatformUUID": uuid, @"model": @"iPad", @"IOPlatformSerialNumber": @"0"};
    });
    return o == kSGX ? sgx : o == kAccel ? accel : o == kPlatform ? platform : nil;
}

static NSString *ProviderClass(CFDictionaryRef matching) {
    if (!matching) return nil;
    id v = ((__bridge NSDictionary *)matching)[@"IOProviderClass"];
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

kern_return_t IOServiceGetMatchingServices(uint32_t port, CFDictionaryRef matching, io_object_t *iter) {
    REAL(kern_return_t, IOServiceGetMatchingServices, uint32_t, CFDictionaryRef, io_object_t *);
    if ([ProviderClass(matching) isEqualToString:@"AppleARMIODevice"]) {
        CFRelease(matching); // consumed, as by IOKit
        *iter = NewIterator(@[@(kSGX)]);
        return 0;
    }
    return real(port, matching, iter);
}

io_object_t IOServiceGetMatchingService(uint32_t port, CFDictionaryRef matching) {
    REAL(io_object_t, IOServiceGetMatchingService, uint32_t, CFDictionaryRef);
    if ([ProviderClass(matching) isEqualToString:@"IOPlatformExpertDevice"]) {
        CFRelease(matching);
        return kPlatform;
    }
    return real(port, matching);
}

io_object_t IOIteratorNext(io_object_t iter) {
    REAL(io_object_t, IOIteratorNext, io_object_t);
    if (!IsFake(iter)) return real(iter);
    @synchronized ([NSObject class]) {
        NSMutableArray *left = gIters[@(iter)];
        if (!left.count) return 0;
        io_object_t e = [left[0] unsignedIntValue];
        [left removeObjectAtIndex:0];
        return e;
    }
}

kern_return_t IOObjectRelease(io_object_t o) {
    REAL(kern_return_t, IOObjectRelease, io_object_t);
    if (!IsFake(o)) return real(o);
    @synchronized ([NSObject class]) { [gIters removeObjectForKey:@(o)]; }
    return 0;
}

kern_return_t IORegistryEntryCreateCFProperties(io_object_t e, CFMutableDictionaryRef *props, CFAllocatorRef a, uint32_t opts) {
    REAL(kern_return_t, IORegistryEntryCreateCFProperties, io_object_t, CFMutableDictionaryRef *, CFAllocatorRef, uint32_t);
    if (!IsFake(e)) return real(e, props, a, opts);
    *props = (CFMutableDictionaryRef)CFBridgingRetain([Props(e) mutableCopy] ?: [NSMutableDictionary new]);
    return 0;
}

CFTypeRef IORegistryEntryCreateCFProperty(io_object_t e, CFStringRef key, CFAllocatorRef a, uint32_t opts) {
    REAL(CFTypeRef, IORegistryEntryCreateCFProperty, io_object_t, CFStringRef, CFAllocatorRef, uint32_t);
    if (!IsFake(e)) return real(e, key, a, opts);
    id v = Props(e)[(__bridge NSString *)key];
    return v ? CFBridgingRetain(v) : NULL;
}

CFTypeRef IORegistryEntrySearchCFProperty(io_object_t e, const char *plane, CFStringRef key, CFAllocatorRef a, uint32_t opts) {
    REAL(CFTypeRef, IORegistryEntrySearchCFProperty, io_object_t, const char *, CFStringRef, CFAllocatorRef, uint32_t);
    if (!IsFake(e)) return real(e, plane, key, a, opts);
    NSString *k = (__bridge NSString *)key;
    id v = Props(e)[k];
    if (!v && e == kSGX && (opts & 1)) v = Props(kAccel)[k];  // kIORegistryIterateRecursively: children
    if (!v && e == kAccel && (opts & 2)) v = Props(kSGX)[k];  // kIORegistryIterateParents
    return v ? CFBridgingRetain(v) : NULL;
}

kern_return_t IORegistryEntryGetChildIterator(io_object_t e, const char *plane, io_object_t *iter) {
    REAL(kern_return_t, IORegistryEntryGetChildIterator, io_object_t, const char *, io_object_t *);
    if (!IsFake(e)) return real(e, plane, iter);
    *iter = NewIterator(e == kSGX ? @[@(kAccel)] : @[]);
    return 0;
}

kern_return_t IORegistryEntryGetRegistryEntryID(io_object_t e, uint64_t *id) {
    REAL(kern_return_t, IORegistryEntryGetRegistryEntryID, io_object_t, uint64_t *);
    if (!IsFake(e)) return real(e, id);
    *id = e == kAccel ? [Props(kAccel)[@"IORegistryEntryID"] unsignedLongLongValue] : (uint64_t)e;
    return 0;
}
