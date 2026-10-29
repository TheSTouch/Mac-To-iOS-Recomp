// The iOS stand-in for macOS's OpenGL.framework (built by recomp/ios_opengl.py).
//
// gl4es runs desktop OpenGL 2.1 on the device's OpenGL ES 2; the framework
// exports its functions under the desktop names (glBegin, glGenBuffersARB, ...),
// so a Mac app that dlopens OpenGL.framework and looks the functions up finds
// them, and so does GLU, linked in beside it. What a Mac app links from the
// real framework besides GL (CGL, NSOpenGLContext) is here as stubs that fail
// cleanly: windows get their OpenGL contexts from the toolkit (Qt's iOS
// plugin, an EAGLContext), which tells gl4es about them through RecompGL_*.
#import <Foundation/Foundation.h>
#import <OpenGLES/EAGL.h>
#include <dlfcn.h>
#include <stdlib.h>

#define EXPORT __attribute__((visibility("default")))

void set_getprocaddress(void *(*proc)(const char *));
void set_getmainfbsize(void (*size)(int *w, int *h));
void initialize_gl4es(void);
void *gl4es_GetProcAddress(const char *name);
void *NewGLState(void *shared, int es2only);
void ActivateGLState(void *state);
void DeleteGLState(void *state);

static void *gles;
static int main_w, main_h;

static void *gles_proc(const char *name) {
    return dlsym(gles, name);
}

static void main_fb_size(int *w, int *h) {
    *w = main_w;
    *h = main_h;
}

// gl4es reads the hardware's extensions when it starts, so it starts with the
// first context, made current for the purpose.
static void start(EAGLContext *context) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gles = dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_NOW | RTLD_LOCAL);
        setenv("LIBGL_ES", "2", 0);
        setenv("LIBGL_GL", "21", 0);
        setenv("LIBGL_NOBANNER", "1", 0);
        setenv("LIBGL_SILENTSTUB", "1", 0);
        // Old ARB assembly programs are half done in gl4es; apps that see no
        // GL_ARB_fragment_program use GLSL or the fixed pipeline instead (OpenCSG does).
        setenv("LIBGL_NOARBPROGRAM", "1", 0);
        set_getprocaddress(gles_proc);
        set_getmainfbsize(main_fb_size);
        EAGLContext *previous = [EAGLContext currentContext];
        [EAGLContext setCurrentContext:context];
        initialize_gl4es();
        NSLog(@"[recomp] OpenGL: gl4es on %s", (const char *)((const unsigned char *(*)(unsigned))gles_proc("glGetString"))(0x1F01));
        [EAGLContext setCurrentContext:previous];
    });
}

// A toolkit context was created: its gl4es state, sharing objects with `share`'s.
EXPORT void *RecompGL_ContextCreated(EAGLContext *context, void *share) {
    start(context);
    EAGLContext *previous = [EAGLContext currentContext];
    [EAGLContext setCurrentContext:context];
    void *state = NewGLState(share, 0);
    [EAGLContext setCurrentContext:previous];
    return state;
}

EXPORT void RecompGL_MakeCurrent(void *state) {
    if (state)
        ActivateGLState(state);
}

EXPORT void RecompGL_ContextDestroyed(void *state) {
    DeleteGLState(state);
}

EXPORT void RecompGL_SetMainFramebufferSize(int w, int h) {
    main_w = w;
    main_h = h;
}

EXPORT void *RecompGL_GetProcAddress(const char *name) {
    return gl4es_GetProcAddress(name);
}

// --- CGL: no Mac contexts on iOS --------------------------------------------------

typedef int CGLError;
enum { kCGLNoError = 0, kCGLBadAttribute = 10000, kCGLBadContext = 10006 };

EXPORT CGLError CGLChoosePixelFormat(const int *attribs, void **pix, int *npix) {
    *pix = NULL;
    if (npix)
        *npix = 0;
    return kCGLBadAttribute;
}

EXPORT CGLError CGLCreateContext(void *pix, void *share, void **ctx) {
    *ctx = NULL;
    return kCGLBadContext;
}

EXPORT CGLError CGLDestroyContext(void *ctx) { return kCGLNoError; }
EXPORT CGLError CGLDestroyPixelFormat(void *pix) { return kCGLNoError; }
EXPORT CGLError CGLSetCurrentContext(void *ctx) { return ctx ? kCGLBadContext : kCGLNoError; }
EXPORT void *CGLGetCurrentContext(void) { return NULL; }

EXPORT const char *CGLErrorString(CGLError error) {
    return error ? "no CGL contexts on iOS" : "no error";
}

// --- NSOpenGL: the same, for code that asks AppKit ---------------------------------

EXPORT @interface NSOpenGLPixelFormat : NSObject
@end

@implementation NSOpenGLPixelFormat
- (instancetype)initWithAttributes:(const uint32_t *)attribs { return nil; }
@end

EXPORT @interface NSOpenGLContext : NSObject
@end

@implementation NSOpenGLContext
+ (NSOpenGLContext *)currentContext { return nil; }
+ (void)clearCurrentContext {}
- (instancetype)initWithFormat:(NSOpenGLPixelFormat *)format shareContext:(NSOpenGLContext *)share { return nil; }
- (void)makeCurrentContext {}
- (void)flushBuffer {}
@end
