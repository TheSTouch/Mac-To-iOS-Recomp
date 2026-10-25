// Metal on iOS versus macOS, for the same Apple GPU:
//  - MTLStorageModeManaged does not exist (creating a managed resource aborts);
//    it becomes Shared, which on unified memory needs no synchronisation, so
//    -didModifyRange: and the blit encoder's -synchronize* calls become no-ops;
//  - Mac GPU families and feature sets are reported as supported, since the
//    game checks for them and an M-series iPad has the same GPU as the Mac;
//  - Mac-only device and layer properties get the values an Apple Silicon Mac reports;
//  - metallibs from older tools (file format 2.3, e.g. Bink's) are refused while
//    their header says macOS; with that flag cleared the same code loads and runs.
#import "RecompAppKit.h"
#import <Metal/Metal.h>
#import <objc/runtime.h>

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
    NSError *e = nil;
    id lib = ((id (*)(id, SEL, dispatch_data_t, NSError **))oLibData)(self, s, data, &e);
    if (!lib && [e.domain isEqualToString:MTLLibraryErrorDomain]) {
        dispatch_data_t fixed = WithoutMacFlag(data);
        if (fixed) lib = ((id (*)(id, SEL, dispatch_data_t, NSError **))oLibData)(self, s, fixed, &e);
        if (lib) RLOG(@"metallib from older tools: loaded with the macOS flag cleared");
    }
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
    NSError *e = nil;
    id lib = ((id (*)(id, SEL, NSString *, NSError **))oLibFile)(self, s, path, &e);
    return LibFromPath(self, path, err, lib, e);
}
static id FixLibURL(id self, SEL s, NSURL *url, NSError **err) {
    NSError *e = nil;
    id lib = ((id (*)(id, SEL, NSURL *, NSError **))oLibURL)(self, s, url, &e);
    return LibFromPath(self, url.path, err, lib, e);
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
