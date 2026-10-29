"""OpenGL.framework for iOS: desktop OpenGL 2.1 for Mac apps, on the device's OpenGL ES.

iOS has no desktop OpenGL. gl4es (MIT, https://github.com/ptitSeb/gl4es)
translates it to OpenGL ES 2; this module builds it, with GLU (SGI Free
Software License B, the tessellator and matrix helpers Mac apps link from the
real framework) and recomp/native/opengl/RecompGL.m, into one framework whose
install name is @rpath/OpenGL.framework/OpenGL. Every function gl4es serves
is exported under its desktop name (an ld64 alias list made from gl4es's own
lookup table), so code that links, dlsyms or GetProcAddresses glBegin or
glGenBuffersARB finds it.

  build(sdk)   -> path of the framework for "iphoneos" or "iphonesimulator"
  include_dir() -> the desktop GL headers (GL/gl.h, GL/glext.h, GL/glu.h)
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys

from recomp import paths

GL4ES = ("https://github.com/ptitSeb/gl4es.git", "c9895df34cd466c23bc60c2bd3db3d87e98fcbe7")  # v1.1.6
GLU = ("https://github.com/ptitSeb/GLU.git", "2fed2bda2b725d2b9e32c435b48d5141cc95827f")
PATCHES = os.path.join(paths.CODE, "recomp", "patches")
GLUE = os.path.join(paths.CODE, "recomp", "native", "opengl", "RecompGL.m")
MIN_IOS = "17.0"
GLU_SOURCES = ["libutil/error.c", "libutil/glue.c", "libutil/project.c", "libutil/registry.c"] + [
    f"libtess/{n}.c" for n in ("dict", "geom", "memalloc", "mesh", "normal", "priorityq", "render", "sweep", "tess",
                               "tessmono")]


def log(msg):
    print(f"[recomp] {msg}", flush=True)


def run(cmd, **kw):
    log("$ " + " ".join(cmd if len(cmd) < 24 else cmd[:8] + [f"... ({len(cmd) - 10} more)"] + cmd[-2:]))
    return subprocess.run(cmd, check=True, **kw)


def _checkout(url, commit, patch=None):
    """A clone of url at commit under toolchain/, with recomp/patches/<patch> applied (git am)."""
    dest = os.path.join(paths.TOOLCHAIN, os.path.basename(url)[:-len(".git")])
    if not os.path.isdir(os.path.join(dest, ".git")):
        run(["git", "clone", "-q", url, dest])
    want = commit
    if patch:
        with open(os.path.join(PATCHES, patch), "rb") as f:
            want += " " + hashlib.sha256(f.read()).hexdigest()
    marker = os.path.join(dest, ".git", "recomp-checkout")
    if os.path.exists(marker) and open(marker).read() == want:
        return dest
    run(["git", "-C", dest, "fetch", "-q", "origin", commit])
    run(["git", "-C", dest, "checkout", "-q", "-f", "-B", "recomp", commit])
    if patch:
        run(["git", "-C", dest, "-c", "user.name=recomp", "-c", "user.email=recomp@localhost", "am", "-q",
             os.path.join(PATCHES, patch)])
    with open(marker, "w") as f:
        f.write(want)
    return dest


def include_dir():
    return os.path.join(paths.TOOLCHAIN, "ios-opengl", "include")


def _headers(gl4es, glu):
    inc = include_dir()
    shutil.copytree(os.path.join(gl4es, "include", "GL"), os.path.join(inc, "GL"), dirs_exist_ok=True)
    # On Apple gl4es's header renames every function to gl4es_*; the framework
    # exports the desktop names, which are what its users should call.
    gl_h = os.path.join(inc, "GL", "gl.h")
    with open(gl_h) as f:
        text = f.read()
    apple = "#if defined(__EMSCRIPTEN__) || defined(__APPLE__)\n#define USE_MGL_NAMESPACE"
    if apple not in text:
        sys.exit(f"{gl_h}: gl4es's Apple name mangling not found; check the header")
    with open(gl_h, "w") as f:
        f.write(text.replace(apple, "#if defined(__EMSCRIPTEN__)\n#define USE_MGL_NAMESPACE"))
    shutil.copy2(os.path.join(glu, "include", "GL", "glu.h"), os.path.join(inc, "GL", "glu.h"))
    # gl4es's GL/gl.h pulls in its GLES headers for the shared types.
    for sub in ("GLES", "GLES2", "KHR"):
        src = os.path.join(gl4es, "include", sub)
        if os.path.isdir(src):
            shutil.copytree(src, os.path.join(inc, sub), dirs_exist_ok=True)


def _aliases(gl4es, sdk, lib, out):
    """ld64 alias list: every name gl4es_GetProcAddress answers, bound to the function it returns."""
    pre = subprocess.run(["xcrun", "--sdk", sdk, "clang", "-E", "-target", f"arm64-apple-ios{MIN_IOS}",
                          "-I", os.path.join(gl4es, "include"), "-I", os.path.join(gl4es, "src"),
                          "-DNOX11", "-DNOEGL", "-DSTATICLIB", "-DNO_LOADER", "-DDEFAULT_ES=2",
                          os.path.join(gl4es, "src", "gl", "gl_lookup.c")], capture_output=True, text=True, check=True)
    defined = set(subprocess.run(["nm", "-gUj", lib], capture_output=True, text=True).stdout.split())
    pairs = {}
    for m in re.finditer(r'strcmp\(name, "(\w+)"(?: "(\w+)")?\) == 0\) (?:\{[^}]*?)?return \(void \*\)(\w+);',
                         pre.stdout):
        name, target = m.group(1) + (m.group(2) or ""), m.group(3)
        if name.startswith("gl") and name != target and "_" + target in defined and "_" + name not in defined:
            pairs.setdefault(name, target)
    with open(out, "w") as f:
        for name, target in sorted(pairs.items()):
            f.write(f"_{target} _{name}\n")
    return len(pairs)


def build(sdk="iphoneos"):
    gl4es = _checkout(*GL4ES, patch="gl4es-ios.patch")
    glu = _checkout(*GLU)
    out = os.path.join(paths.TOOLCHAIN, "ios-opengl", sdk)
    fw = os.path.join(out, "OpenGL.framework")
    binary = os.path.join(fw, "OpenGL")
    inputs = [GLUE, os.path.join(PATCHES, "gl4es-ios.patch"), os.path.join(gl4es, ".git", "recomp-checkout"), __file__]
    if os.path.exists(binary) and all(os.path.getmtime(binary) > os.path.getmtime(p) for p in inputs):
        return fw
    work = os.path.join(out, "build")
    os.makedirs(work, exist_ok=True)
    run(["cmake", "-S", gl4es, "-B", os.path.join(work, "gl4es"), "-G", "Ninja", "-DCMAKE_SYSTEM_NAME=iOS",
         f"-DCMAKE_OSX_SYSROOT={sdk}", "-DCMAKE_OSX_ARCHITECTURES=arm64", f"-DCMAKE_OSX_DEPLOYMENT_TARGET={MIN_IOS}",
         "-DCMAKE_BUILD_TYPE=RelWithDebInfo", "-DNOX11=ON", "-DNOEGL=ON", "-DSTATICLIB=ON", "-DNO_LOADER=ON",
         "-DDEFAULT_ES=2", f"-DCMAKE_ARCHIVE_OUTPUT_DIRECTORY={work}",
         "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"], stdout=subprocess.DEVNULL)  # v1.1.6 predates CMake 4
    run(["cmake", "--build", os.path.join(work, "gl4es")], stdout=subprocess.DEVNULL)
    lib = os.path.join(work, "libGL.a")
    if not os.path.exists(lib):  # gl4es puts it in its source tree's lib/ whatever the build folder
        shutil.move(os.path.join(gl4es, "lib", "libGL.a"), lib)
    _headers(gl4es, glu)
    alias_file = os.path.join(work, "aliases.txt")
    n = _aliases(gl4es, sdk, lib, alias_file)
    os.makedirs(fw, exist_ok=True)
    glu_src = [os.path.join(glu, "src", s) for s in GLU_SOURCES]
    target = f"arm64-apple-ios{MIN_IOS}" + ("-simulator" if sdk == "iphonesimulator" else "")
    try:
        run(["xcrun", "--sdk", sdk, "clang", "-target", target, "-O2", "-g", "-dynamiclib", "-fobjc-arc",
             "-install_name", "@rpath/OpenGL.framework/OpenGL", "-current_version", "1.0",
             "-compatibility_version", "1.0", "-I", include_dir(), "-I", os.path.join(gl4es, "include"),
             "-I", os.path.join(glu, "include"), "-I", os.path.join(glu, "src", "include"),
             "-DLIBRARYBUILD", "-Wno-implicit-function-declaration", "-Wno-deprecated-declarations",
             "-Wl,-alias_list," + alias_file, "-Wl,-force_load," + lib,
             "-framework", "Foundation", "-framework", "OpenGLES", GLUE, *glu_src, "-o", binary])
    except subprocess.CalledProcessError:
        sys.exit("building OpenGL.framework failed (compiler errors above)")
    with open(os.path.join(fw, "Info.plist"), "wb") as f:
        import plistlib
        plistlib.dump({"CFBundleExecutable": "OpenGL", "CFBundleIdentifier": "com.thestouch.recomp.opengl",
                       "CFBundleName": "OpenGL", "CFBundlePackageType": "FMWK", "CFBundleShortVersionString": "1.0",
                       "CFBundleVersion": "1", "MinimumOSVersion": MIN_IOS}, f)
    log(f"{sdk}: OpenGL.framework, gl4es with {n} desktop names, GLU")
    return fw


if __name__ == "__main__":
    for s in sys.argv[1:] or ["iphoneos"]:
        print(build(s))
