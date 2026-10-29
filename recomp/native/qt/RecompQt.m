// RecompQt.dylib: what a Qt app's Mac binaries take from macOS and iOS lacks
// (built per app by recomp/qt_ios.py, which re-exports from it the iOS
// libraries it stands in for and adds a "return 0" stub for anything else).
#import <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <syslog.h>

#define EXPORT __attribute__((visibility("default")))

void *RecompRealSym(const char *name, void *mine) {
    void *p = dlsym(RTLD_DEFAULT, name);
    return p && p != mine ? p : dlsym(RTLD_NEXT, name);
}

// Mac apps load OpenGL by path (GLAD and the like dlopen
// /System/Library/Frameworks/OpenGL.framework/OpenGL); on iOS it is the
// app's own framework, gl4es (recomp/ios_opengl.py).
EXPORT void *dlopen(const char *path, int mode) {
    static void *(*real)(const char *, int);
    if (!real)
        real = RecompRealSym("dlopen", (void *)dlopen);
    if (path && strstr(path, "OpenGL.framework/")) {
        void *h = real("@executable_path/Frameworks/OpenGL.framework/OpenGL", mode);
        fprintf(stderr, "[recomp] dlopen(%s): the app's OpenGL.framework%s\n", path, h ? "" : " failed to load");
        return h;
    }
    return real(path, mode);
}

// macOS's syslog with POSIX format checks, from libSystem; iOS has only syslog.
EXPORT void recomp_syslog_extsn(int priority, const char *format, ...) __asm__("_syslog$DARWIN_EXTSN");
void recomp_syslog_extsn(int priority, const char *format, ...) {
    va_list args;
    va_start(args, format);
    vsyslog(priority, format, args);
    va_end(args);
}

// Apple events: a Mac app installs handlers (open document, quit) that iOS never calls.
EXPORT short AEInstallEventHandler(unsigned theAEEventClass, unsigned theAEEventID, void *handler, void *refcon,
                                   unsigned char isSysHandler) {
    return 0;
}

// Unicode collation (CoreServices, used by glib's g_utf8_collate): compared with CFString instead.
EXPORT int UCCompareTextDefault(unsigned options, const UniChar *text1, unsigned long length1, const UniChar *text2,
                                unsigned long length2, Boolean *equivalent, int *order) {
    CFStringRef a = CFStringCreateWithCharactersNoCopy(NULL, text1, length1, kCFAllocatorNull);
    CFStringRef b = CFStringCreateWithCharactersNoCopy(NULL, text2, length2, kCFAllocatorNull);
    CFComparisonResult r = CFStringCompare(a, b, kCFCompareLocalized | kCFCompareNonliteral);
    CFRelease(a);
    CFRelease(b);
    if (order)
        *order = r == kCFCompareLessThan ? -1 : r == kCFCompareGreaterThan ? 1 : 0;
    if (equivalent)
        *equivalent = r == kCFCompareEqualTo;
    return 0;
}

// Collation keys: refused (paramErr), so glib falls back to comparing the strings themselves.
EXPORT int UCCreateCollator(const void *locale, unsigned opVariant, unsigned options, void **collatorRef) {
    if (collatorRef)
        *collatorRef = NULL;
    return -50;
}

EXPORT int UCGetCollationKey(void *collatorRef, const UniChar *text, unsigned long length, unsigned long maxKeySize,
                             unsigned long *actualKeySize, void *key) {
    if (actualKeySize)
        *actualKeySize = 0;
    return -50;
}
