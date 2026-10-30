"""Port a Qt 6 Mac app (not only games: OpenSCAD) to iOS by retargeting its binaries and swapping its Qt.

A Qt app's own code and libraries are arm64 already; what ties them to macOS
is Qt's Cocoa platform plugin and a handful of system calls. So:

  toolchain  build the app's Qt version for iOS from source, once per version
             and SDK: shared frameworks like the Mac app's (so its imports
             match), desktop OpenGL run on OpenGL ES by gl4es (ios_opengl.py),
             and recomp/patches/qt-<version>-ios.patch (Qt's iOS plugin starts
             UIKit for a main() that is already running, QProcess and QPrinter
             exist, ...)
  prepare    retarget every Mach-O of the bundle except Qt's own: each keeps
             its library list, slot for slot (older-format binaries bind by
             slot number), with iOS paths; a slot whose symbols the iOS library
             lacks goes to RecompQt.dylib, built per app, which re-exports that
             library and adds the rest (recomp/native/qt, then "return 0" stubs)
  xcode      generate a small Xcode project and build it: the run-script phase
             puts the app, its libraries, the iOS Qt frameworks and plugins and
             the Mac bundle's Resources (as MacResources/) into the app
  install    install it on a connected device, or on the booted simulator

--sim builds for the iOS simulator on this Mac instead (arm64), to debug with lldb.
"""
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys

from recomp import events, ios_opengl, iossdk, macho, paths, xcodeproj

ROOT = paths.CODE
NATIVE_SRC = os.path.join(ROOT, "recomp", "native", "qt")
PROFILES = os.path.join(ROOT, "recomp", "profiles")
PATCHES = os.path.join(ROOT, "recomp", "patches")
RESOURCES = "MacResources"  # the Mac bundle's Contents/Resources; 12 letters, like "../Resources"
MIN_IOS = "17.0"
SHIM_NAME = "RecompQt.dylib"
QT_MODULES = ["qtbase", "qtshadertools", "qtsvg", "qt5compat", "qtmultimedia"]
# Plugin folders the port carries (the rest are desktop- or Linux-only).
QT_PLUGINS = ["platforms/libqios.dylib", "imageformats", "iconengines", "tls", "networkinformation", "multimedia"]
# Imports bound to the shim even though iOS exports them.
INTERCEPT = {"_dlopen"}
PLATFORM = {"iphoneos": macho.PLATFORM_IOS, "iphonesimulator": 7}


def log(msg):
    print(f"[recomp] {msg}", flush=True)


def run(cmd, **kw):
    shown = cmd if len(cmd) < 24 else cmd[:8] + [f"... ({len(cmd) - 10} more)"] + cmd[-2:]
    log("$ " + " ".join(shown))
    return subprocess.run(cmd, check=True, **kw)


def stream(cmd, on_line, **kw):
    log("$ " + " ".join(cmd))
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1, **kw)
    for line in proc.stdout:
        on_line(line.rstrip("\n"))
    if proc.wait() != 0:
        raise subprocess.CalledProcessError(proc.returncode, cmd)


def is_macho(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe")
    except OSError:
        return False


class App:
    def __init__(self, app):
        self.app = os.path.abspath(app.rstrip("/"))
        self.contents = os.path.join(self.app, "Contents")
        with open(os.path.join(self.contents, "Info.plist"), "rb") as f:
            self.info = plistlib.load(f)
        self.executable = self.info["CFBundleExecutable"]
        self.name = os.path.basename(self.app)[:-len(".app")]
        self.slug = re.sub(r"[^A-Za-z0-9]", "", self.name) or "App"
        core = os.path.join(self.contents, "Frameworks", "QtCore.framework")
        if not os.path.isdir(core):
            sys.exit(f"{self.app}: no Contents/Frameworks/QtCore.framework; this route handles Qt apps")
        out = subprocess.run(["otool", "-L", os.path.join(self.contents, "MacOS", self.executable)],
                             capture_output=True, text=True).stdout
        m = re.search(r"QtCore\.framework/\S+ \(compatibility version [\d.]+, current version (\d+\.\d+\.\d+)\)", out)
        if not m:
            sys.exit(f"{self.app}: the executable does not link QtCore.framework")
        self.qt_version = m.group(1)
        self.profile = load_profile(self)

    def binaries(self):
        """Relative paths (under Contents) of the Mach-Os to retarget, main executable first: Qt's
        own frameworks and plugins are replaced by the iOS build instead."""
        main = os.path.join("MacOS", self.executable)
        out = [main]
        for root, dirs, files in os.walk(self.contents):
            rel_root = os.path.relpath(root, self.contents)
            dirs[:] = [d for d in dirs if not (rel_root == "Frameworks" and re.match(r"Qt\w+\.framework$", d))
                       and not (rel_root == "." and d in ("PlugIns", "_CodeSignature"))]
            for n in files:
                rel = os.path.normpath(os.path.join(rel_root, n))
                p = os.path.join(root, n)
                if rel != main and not os.path.islink(p) and is_macho(p):
                    out.append(rel)
        return out


def load_profile(app):
    """The first recomp/profiles/*.json whose "bundle_id" is the app's."""
    for n in sorted(os.listdir(PROFILES)):
        if n.endswith(".json"):
            with open(os.path.join(PROFILES, n)) as f:
                p = json.load(f)
            if p.get("bundle_id") == app.info.get("CFBundleIdentifier"):
                log(f"profile {n}: {p.get('why', '')}")
                return p
    return {}


# --- toolchain: Qt for iOS -------------------------------------------------------------

def qt_root(version):
    return os.path.join(paths.TOOLCHAIN, f"qt-{version}")


def _gl_cmake_args(sdk):
    gl = ios_opengl.build(sdk)
    fw_dir, inc = os.path.dirname(gl), ios_opengl.include_dir()
    flags = f"-F{fw_dir} -isystem {inc}"
    link = f"-F{fw_dir} -framework OpenGLES"
    return [f"-DCMAKE_OSX_DEPLOYMENT_TARGET={MIN_IOS}", "-DCMAKE_OSX_ARCHITECTURES=arm64",
            f"-DOPENGL_INCLUDE_DIR={inc}", f"-DOPENGL_gl_LIBRARY={gl}", f"-DCMAKE_C_FLAGS=-isystem {inc}",
            f"-DCMAKE_OBJC_FLAGS=-isystem {inc}", f"-DCMAKE_CXX_FLAGS={flags}", f"-DCMAKE_OBJCXX_FLAGS={flags}",
            f"-DCMAKE_SHARED_LINKER_FLAGS={link}", f"-DCMAKE_MODULE_LINKER_FLAGS={link}",
            f"-DCMAKE_EXE_LINKER_FLAGS={link}"]


def _qt_sources(version):
    """Qt's module sources under toolchain/qt-<version>/src, downloaded and patched once."""
    src = os.path.join(qt_root(version), "src")
    patch = os.path.join(PATCHES, f"qt-{version}-ios.patch")
    if not os.path.exists(patch):
        sys.exit(f"Qt {version}: no recomp/patches/qt-{version}-ios.patch; only Qt versions with one are supported")
    marker = os.path.join(src, ".recomp-patched")
    if os.path.exists(marker):
        return src
    os.makedirs(src, exist_ok=True)
    series = ".".join(version.split(".")[:2])
    for m in QT_MODULES:
        if os.path.isdir(os.path.join(src, f"{m}-everywhere-src-{version}")):
            continue
        tar = os.path.join(src, f"{m}.tar.xz")
        run(["curl", "-fsSL", "-o", tar,
             f"https://download.qt.io/archive/qt/{series}/{version}/src/submodules/{m}-everywhere-opensource-src-{version}.tar.xz"])
        run(["tar", "xf", tar, "-C", src])
        os.remove(tar)
    run(["git", "apply", "-p1", patch], cwd=src)
    open(marker, "w").close()
    return src


def _qt_host(version, src):
    """Qt for this Mac: the tools (moc, rcc, qsb...) a cross build of the same version needs."""
    root = qt_root(version)
    host = os.path.join(root, "host")
    if os.path.exists(os.path.join(host, "bin", "qsb")):
        return host
    build = os.path.join(root, "build-host")
    os.makedirs(build, exist_ok=True)
    run([os.path.join(src, f"qtbase-everywhere-src-{version}", "configure"), "-prefix", host, "-release",
         "-nomake", "examples", "-nomake", "tests", "-no-feature-sql", "-no-feature-testlib"], cwd=build,
        stdout=subprocess.DEVNULL)
    run(["cmake", "--build", ".", "--parallel"], cwd=build, stdout=subprocess.DEVNULL)
    run(["cmake", "--install", "."], cwd=build, stdout=subprocess.DEVNULL)
    tools = os.path.join(root, "build-host-shadertools")
    run(["cmake", "-S", os.path.join(src, f"qtshadertools-everywhere-src-{version}"), "-B", tools, "-G", "Ninja",
         f"-DCMAKE_PREFIX_PATH={host}", f"-DCMAKE_INSTALL_PREFIX={host}", "-DCMAKE_BUILD_TYPE=Release"],
        stdout=subprocess.DEVNULL)
    run(["cmake", "--build", tools, "--parallel"], stdout=subprocess.DEVNULL)
    run(["cmake", "--install", tools], stdout=subprocess.DEVNULL)
    return host


def _merge_headers(prefix):
    # Qt installs iOS frameworks flat but leaves their headers in the macOS place.
    lib = os.path.join(prefix, "lib")
    for n in os.listdir(lib):
        headers = os.path.join(lib, n, "Versions", "A", "Headers")
        if n.endswith(".framework") and os.path.isdir(headers):
            shutil.copytree(headers, os.path.join(lib, n, "Headers"), dirs_exist_ok=True)


def toolchain(version, sdk="iphoneos"):
    """Install prefix of Qt <version> for sdk ("iphoneos" or "iphonesimulator"), built if needed."""
    root = qt_root(version)
    prefix = os.path.join(root, sdk)
    marker = os.path.join(prefix, ".recomp-built")
    if os.path.exists(marker):
        return prefix
    src = _qt_sources(version)
    host = _qt_host(version, src)
    gl_args = _gl_cmake_args(sdk)
    build = os.path.join(root, f"build-{sdk}")
    os.makedirs(build, exist_ok=True)
    events.progress(None, f"Building Qt {version} for iOS")
    run([os.path.join(src, f"qtbase-everywhere-src-{version}", "configure"), "-xplatform", "macx-ios-clang",
         "-sdk", sdk, "-prefix", prefix, "-qt-host-path", host, "-release", "-force-debug-info", "-shared",
         "-opengl", "desktop", "-feature-dbus", "-feature-process", "-no-feature-printdialog",
         "-no-feature-printpreviewdialog", "-no-feature-sql", "-no-feature-testlib", "-nomake", "examples",
         "-nomake", "tests", "--", *gl_args], cwd=build, stdout=subprocess.DEVNULL)
    run(["cmake", "--build", ".", "--parallel"], cwd=build, stdout=subprocess.DEVNULL)
    run(["cmake", "--install", "."], cwd=build, stdout=subprocess.DEVNULL)
    _merge_headers(prefix)
    for m in QT_MODULES[1:]:
        mb = os.path.join(root, f"build-{sdk}-{m}")
        os.makedirs(mb, exist_ok=True)
        run([os.path.join(prefix, "bin", "qt-configure-module"), os.path.join(src, f"{m}-everywhere-src-{version}"),
             "--", *gl_args], cwd=mb, stdout=subprocess.DEVNULL)
        run(["cmake", "--build", ".", "--parallel"], cwd=mb, stdout=subprocess.DEVNULL)
        run(["cmake", "--install", "."], cwd=mb, stdout=subprocess.DEVNULL)
        _merge_headers(prefix)
    open(marker, "w").close()
    return prefix


# --- prepare ---------------------------------------------------------------------------

def exported(path):
    r = subprocess.run(["nm", "-gUj", path], capture_output=True, text=True, check=True)
    return set(r.stdout.split())


def _is_system(path):
    return path.startswith(("/System/", "/usr/lib/"))


def _qt_framework(path):
    m = re.match(r"@(?:rpath|executable_path/\.\./Frameworks|loader_path/\.\./Frameworks)/(Qt\w+)\.framework/", path)
    return m.group(1) if m else None


class Plan:
    """New library paths for every binary, slot for slot, and what the shim must carry."""

    def __init__(self, idx, qt_prefix, gl_framework):
        self.idx = idx
        self.qt_prefix = qt_prefix
        self.gl = gl_framework
        self.gl_syms = exported(os.path.join(gl_framework, "OpenGL"))
        self.qt_frameworks = set()
        self.reexports = set()  # iOS install names (and the GL framework) the shim re-exports
        self.needed = {}  # symbol -> binary that imports it, for the shim to define

    def slot(self, rel, path, syms):
        qt = _qt_framework(path)
        if qt:
            if not os.path.isdir(os.path.join(self.qt_prefix, "lib", qt + ".framework")):
                sys.exit(f"{rel}: links {qt}, which the iOS Qt build lacks")
            self.qt_frameworks.add(qt)
            return f"@rpath/{qt}.framework/{qt}"
        if not _is_system(path):
            return "@rpath/" + os.path.basename(path)
        if "/OpenGL.framework/" in path and syms <= self.gl_syms:
            return "@rpath/OpenGL.framework/OpenGL"
        ios = iossdk.framework_path(self.idx, path)
        have = self.idx.get(ios, set()) if ios else set()
        if ios and syms <= have and not syms & INTERCEPT:
            return ios
        if not ios and syms and syms <= self.gl_syms:
            return "@rpath/OpenGL.framework/OpenGL"
        if ios:
            self.reexports.add(ios)
        if syms & self.gl_syms:
            self.reexports.add("OpenGL")
        for s in syms - have - self.gl_syms:
            self.needed.setdefault(s, rel)
        return "@rpath/" + SHIM_NAME


def _thin(src, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    r = subprocess.run(["lipo", "-archs", src], capture_output=True, text=True)
    if r.stdout.split() == ["arm64"]:
        shutil.copy2(src, dst)
    else:
        run(["lipo", "-thin", "arm64", src, "-output", dst])


def _sdk_lib(sdk_path, ios):
    """Linker arguments that re-export an iOS library from the shim."""
    m = re.match(r"/System/Library/Frameworks/(\w+)\.framework/", ios)
    if m:
        return ["-Wl,-reexport_framework," + m.group(1)]
    return ["-Wl,-reexport_library," + os.path.join(sdk_path, ios.lstrip("/")[:-len(".dylib")] + ".tbd")]


def build_shim(work, plan, sdk):
    out = os.path.join(work, "shim")
    os.makedirs(out, exist_ok=True)
    sdk_path = subprocess.run(["xcrun", "--sdk", sdk, "--show-sdk-path"], capture_output=True, text=True,
                              check=True).stdout.strip()
    target = f"arm64-apple-ios{MIN_IOS}" + ("-simulator" if sdk == "iphonesimulator" else "")
    sources = sorted(os.path.join(NATIVE_SRC, n) for n in os.listdir(NATIVE_SRC) if n.endswith((".m", ".c")))
    qt_lib = os.path.join(plan.qt_prefix, "lib")
    # The Qt side (RecompQtHooks.mm) needs C++17, which clang refuses for the C and
    # Objective-C files in the same command: compiled on its own.
    for n in sorted(os.listdir(NATIVE_SRC)):
        if n.endswith(".mm"):
            obj = os.path.join(out, n[:-3] + ".o")
            try:
                run(["xcrun", "--sdk", sdk, "clang++", "-target", target, "-O2", "-g", "-std=c++17", "-fobjc-arc",
                     "-F", qt_lib, "-isystem", ios_opengl.include_dir(), "-c", os.path.join(NATIVE_SRC, n), "-o", obj])
            except subprocess.CalledProcessError:
                sys.exit(f"building {n} failed (compiler errors above)")
            sources.append(obj)

    def link(extra_sources, dst):
        reexports = []
        for ios in sorted(plan.reexports):
            reexports += (["-Wl,-reexport_library," + os.path.join(plan.gl, "OpenGL")] if ios == "OpenGL"
                          else _sdk_lib(sdk_path, ios))
        try:
            run(["xcrun", "--sdk", sdk, "clang", "-target", target, "-O2", "-g", "-dynamiclib", "-fobjc-arc",
                 "-install_name", "@rpath/" + SHIM_NAME, "-current_version", "1.0", "-compatibility_version", "1.0",
                 "-F", os.path.dirname(plan.gl), "-F", qt_lib, "-lc++", "-framework", "CoreFoundation",
                 "-framework", "QtCore", "-framework", "QtGui", "-framework", "QtWidgets",
                 "-framework", "QtOpenGLWidgets",
                 "-Wl,-rpath,@executable_path/Frameworks", *reexports, *sources,
                 *extra_sources, "-o", dst])
        except subprocess.CalledProcessError:
            sys.exit(f"building {SHIM_NAME} failed (compiler errors above)")

    shim = os.path.join(out, SHIM_NAME)
    link([], shim)
    missing = sorted(set(plan.needed) - exported(shim))
    classes = [s for s in missing if s.startswith(("_OBJC_CLASS_$_", "_OBJC_METACLASS_$_"))]
    if classes:
        sys.exit("Objective-C classes iOS lacks and recomp/native/qt does not provide:\n  " +
                 "\n  ".join(f"{s} (imported by {plan.needed[s]})" for s in classes))
    if missing:
        c = os.path.join(out, "stubs.c")
        with open(c, "w") as f:
            f.write("// Generated by recomp/qt_ios.py: imports iOS lacks, answered with 0.\n#include <stdint.h>\n")
            for i, s in enumerate(missing):
                f.write(f'__attribute__((used, visibility("default"))) intptr_t recomp_stub_{i}(void) '
                        f'__asm__("{s}");\nintptr_t recomp_stub_{i}(void) {{ return 0; }}\n')
        link([c], shim)
        for s in missing:
            log(f"{SHIM_NAME}: {s} (imported by {plan.needed[s]}) returns 0")
    return shim


def _qt_closure(prefix, names, plugins):
    """Qt frameworks needed by the named ones and by the plugins, transitively."""
    todo = [os.path.join(prefix, "lib", f"{n}.framework", n) for n in names] + plugins
    seen, out = set(), set(names)
    while todo:
        p = todo.pop()
        if p in seen:
            continue
        seen.add(p)
        for line in subprocess.run(["otool", "-L", p], capture_output=True, text=True).stdout.splitlines()[1:]:
            m = re.search(r"@rpath/(Qt\w+)\.framework/", line)
            if m and m.group(1) not in out:
                out.add(m.group(1))
                todo.append(os.path.join(prefix, "lib", f"{m.group(1)}.framework", m.group(1)))
    return out


def _distinct(slots):
    """dyld refuses a library listed twice; slots that share one get spellings of its path that
    differ (@rpath/./X, @rpath/././X) but name the same file, which loads once."""
    seen, out = set(), []
    for cmd, path in slots:
        spelled, k = path, 0
        while spelled in seen:
            k += 1
            spelled = path.replace("@rpath/", "@rpath/" + "./" * k, 1)
            if spelled == path:
                sys.exit(f"{path} is needed in two library slots and cannot be spelled twice")
        seen.add(spelled)
        out.append((cmd, spelled))
    return out


def prepare(app, work, sdk="iphoneos"):
    qt = toolchain(app.qt_version, sdk)
    gl = ios_opengl.build(sdk)
    idx = iossdk.index(os.path.join(paths.HOME, "cache"))
    sdk_version = iossdk.sdk_version()
    plan = Plan(idx, qt, gl)
    thin_dir = os.path.join(work, "thin")
    bins = app.binaries()
    loaded, slots = {}, {}
    for i, rel in enumerate(bins):
        events.progress(i / len(bins) / 2, f"Reading {os.path.basename(rel)}")
        thin = os.path.join(thin_dir, rel)
        _thin(os.path.join(app.contents, rel), thin)
        m = macho.MachO(thin)
        by_slot = {}
        for lib, name in m.bound_imports():
            by_slot.setdefault(lib, set()).add(name)
        slots[rel] = _distinct([(cmd, plan.slot(rel, path, by_slot.get(n, set()))) for n, (cmd, path) in
                                enumerate(m.dylibs(), 1)])
        loaded[rel] = m
    shim = build_shim(work, plan, sdk)

    bin_dir = os.path.join(work, "bin")
    shutil.rmtree(bin_dir, ignore_errors=True)
    main = bins[0]
    for i, rel in enumerate(bins):
        events.progress(0.5 + i / len(bins) / 2, f"Retargeting {os.path.basename(rel)}")
        m = loaded[rel]
        if rel == main:
            dst = os.path.join(bin_dir, app.executable)
            m.retarget(MIN_IOS, sdk_version, dylibs=slots[rel], rpaths=["@executable_path/Frameworks"],
                       platform=PLATFORM[sdk])
            for p in app.profile.get("patches", []):
                m.patch_bytes(bytes.fromhex(p["find"]), bytes.fromhex(p["replace"]), count=p.get("count", 1))
        else:
            dst = os.path.join(bin_dir, "Frameworks", os.path.basename(rel))
            name = m.install_name()
            m.retarget(MIN_IOS, sdk_version, dylibs=slots[rel], rpaths=[],
                       install_name="@rpath/" + os.path.basename(rel) if name else None, platform=PLATFORM[sdk])
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        m.save(dst)
        os.chmod(dst, 0o755)
    shutil.copy2(shim, os.path.join(bin_dir, "Frameworks", SHIM_NAME))
    shutil.copytree(gl, os.path.join(bin_dir, "Frameworks", "OpenGL.framework"),
                    ignore=shutil.ignore_patterns("build"))

    plugins = []
    for p in QT_PLUGINS:
        src = os.path.join(qt, "plugins", p)
        if os.path.isdir(src):
            plugins += [os.path.join(src, n) for n in sorted(os.listdir(src)) if n.endswith(".dylib")]
        elif os.path.exists(src):
            plugins.append(src)
    for p in plugins:
        dst = os.path.join(bin_dir, "PlugIns", os.path.relpath(p, os.path.join(qt, "plugins")))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(p, dst)
    frameworks = _qt_closure(qt, plan.qt_frameworks, plugins)
    for n in sorted(frameworks):
        src = os.path.join(qt, "lib", f"{n}.framework")
        dst = os.path.join(bin_dir, "Frameworks", f"{n}.framework")
        os.makedirs(dst, exist_ok=True)
        shutil.copy2(os.path.join(src, n), os.path.join(dst, n))
        with open(os.path.join(src, "Info.plist"), "rb") as f:
            info = plistlib.load(f)
        info.setdefault("MinimumOSVersion", MIN_IOS)
        info.setdefault("CFBundleSupportedPlatforms", ["iPhoneSimulator" if sdk == "iphonesimulator" else "iPhoneOS"])
        with open(os.path.join(dst, "Info.plist"), "wb") as f:
            plistlib.dump(info, f)
    patched = {}
    for rp in app.profile.get("resource_patches", []):
        if rp["file"] not in patched:
            with open(os.path.join(app.contents, "Resources", rp["file"])) as f:
                patched[rp["file"]] = f.read()
        text = patched[rp["file"]]
        if text.count(rp["find"]) != rp.get("count", 1):
            sys.exit(f"Resources/{rp['file']}: expected {rp.get('count', 1)} of {rp['find']!r}")
        patched[rp["file"]] = text.replace(rp["find"], rp["replace"])
    for name, text in patched.items():
        dst = os.path.join(bin_dir, RESOURCES, name)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "w") as f:
            f.write(text)
    with open(os.path.join(bin_dir, "qt.conf"), "w") as f:
        f.write("[Paths]\nPlugins = PlugIns\n")
    with open(os.path.join(work, "manifest.json"), "w") as f:
        json.dump({"app": app.app, "executable": app.executable, "sdk": sdk, "binaries": bins,
                   "qt_frameworks": sorted(frameworks)}, f, indent=2)
    log(f"retargeted {len(bins)} binaries; Qt {app.qt_version}: {len(frameworks)} frameworks, "
        f"{len(plugins)} plugins; {SHIM_NAME} re-exports {len(plan.reexports)} libraries -> {bin_dir}")


# --- Xcode project ---------------------------------------------------------------------

BUNDLE_SCRIPT = r'''set -e
APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
WORK="{work}"
SIGN="${{EXPANDED_CODE_SIGN_IDENTITY:--}}"
cp "$WORK/bin/{exe}" "$APP/$EXECUTABLE_NAME.tmp"
mv -f "$APP/$EXECUTABLE_NAME.tmp" "$APP/$EXECUTABLE_NAME"
rm -rf "$APP/Frameworks" "$APP/PlugIns"
cp -Rc "$WORK/bin/Frameworks" "$WORK/bin/PlugIns" "$WORK/bin/qt.conf" "$APP/"
rm -rf "$APP/{resources}"
cp -Rc "{contents}/Resources" "$APP/{resources}"
rm -f "$APP/{resources}/qt.conf"
if [ -d "$WORK/bin/{resources}" ]; then cp -R "$WORK/bin/{resources}/." "$APP/{resources}/"; fi
find "$APP/PlugIns" "$APP/Frameworks" -name "*.dylib" | while read -r f; do
  /usr/bin/codesign --force --sign "$SIGN" --timestamp=none "$f"
done
for f in "$APP"/Frameworks/*.framework; do
  /usr/bin/codesign --force --sign "$SIGN" --timestamp=none "$f"
done
'''

PLACEHOLDER_MAIN = "// Replaced by the app's executable before signing (see the Bundle app phase).\nint main(void) { return 0; }\n"


def info_plist(app):
    info = app.info
    return {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": app.name,
        "CFBundleDisplayName": app.name,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": str(info.get("CFBundleShortVersionString", "1.0")),
        "CFBundleVersion": str(info.get("CFBundleVersion", "1")),
        "LSRequiresIPhoneOS": True,
        "UIRequiresFullScreen": True,
        # Qt follows the system's dark mode with a dark palette, which Mac Qt apps'
        # own colours and style sheets were not drawn for (dark text on dark).
        "UIUserInterfaceStyle": "Light",
        "UILaunchScreen": {"UIColorName": "", "UIImageRespectsSafeAreaInsets": False},
        "UISupportedInterfaceOrientations": ["UIInterfaceOrientationLandscapeLeft",
                                             "UIInterfaceOrientationLandscapeRight", "UIInterfaceOrientationPortrait"],
        "UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationLandscapeLeft",
                                                  "UIInterfaceOrientationLandscapeRight",
                                                  "UIInterfaceOrientationPortrait",
                                                  "UIInterfaceOrientationPortraitUpsideDown"],
        "UIDeviceFamily": [1, 2],
        "UIApplicationSupportsIndirectInputEvents": True,
        "UIFileSharingEnabled": True,
        "LSSupportsOpeningDocumentsInPlace": True,
        "ITSAppUsesNonExemptEncryption": False,
    }


def app_icon(app):
    name = app.info.get("CFBundleIconFile")
    if not name:
        return None
    path = os.path.join(app.contents, "Resources", name if name.endswith(".icns") else name + ".icns")
    return path if os.path.exists(path) else None


def xcode(app, work, team, bundle_id):
    with open(os.path.join(work, "manifest.json")) as f:
        manifest = json.load(f)
    sdk = manifest["sdk"]
    proj = os.path.join(work, "xcode")
    os.makedirs(proj, exist_ok=True)
    with open(os.path.join(proj, "main.c"), "w") as f:
        f.write(PLACEHOLDER_MAIN)
    with open(os.path.join(proj, "Info.plist"), "wb") as f:
        plistlib.dump(info_plist(app), f)
    resources = []
    icns = app_icon(app)
    if icns:
        from recomp import pyenv
        iconset = os.path.join(proj, "Assets.xcassets", "AppIcon.appiconset")
        os.makedirs(iconset, exist_ok=True)
        with open(os.path.join(proj, "Assets.xcassets", "Contents.json"), "w") as f:
            json.dump({"info": {"author": "xcode", "version": 1}}, f)
        run([pyenv.python(), os.path.join(ROOT, "recomp", "appicon.py"), icns, iconset])
        resources.append("Assets.xcassets")
    script = BUNDLE_SCRIPT.format(work=work, contents=app.contents, exe=manifest["executable"], resources=RESOURCES)
    settings = {
        "INFOPLIST_FILE": "Info.plist", "PRODUCT_BUNDLE_IDENTIFIER": bundle_id, "PRODUCT_NAME": app.slug,
        "IPHONEOS_DEPLOYMENT_TARGET": MIN_IOS, "TARGETED_DEVICE_FAMILY": "1,2", "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon" if icns else "", "ENABLE_BITCODE": "NO",
        "DEAD_CODE_STRIPPING": "NO", "STRIP_INSTALLED_PRODUCT": "NO", "COPY_PHASE_STRIP": "NO",
        "DEBUG_INFORMATION_FORMAT": "dwarf", "ARCHS": "arm64",
    }
    if sdk == "iphoneos":
        settings["DEVELOPMENT_TEAM"] = team
    else:
        settings.update({"CODE_SIGN_IDENTITY": "-", "CODE_SIGN_STYLE": "Manual"})
    xcodeproj.write(proj, app.slug, ["main.c"], settings, script=script, resources=resources)
    derived = os.path.join(work, "DerivedData")
    tail = []

    def on_line(line):
        events.check_hints(line)
        tail.append(line)
        del tail[:-40]
        if line.startswith(("CompileC ", "Ld ", "PhaseScriptExecution", "CodeSign ")):
            events.progress(None, line.split(" ")[0])
        elif " error: " in line:
            events.emit("log", line=line)

    destination = "generic/platform=iOS" if sdk == "iphoneos" else "generic/platform=iOS Simulator"
    try:
        stream(["xcodebuild", "-project", os.path.join(proj, app.slug + ".xcodeproj"), "-scheme", app.slug,
                "-configuration", "Release", "-destination", destination, "-derivedDataPath", derived,
                "-allowProvisioningUpdates", "build"], on_line)
    except subprocess.CalledProcessError:
        sys.exit("xcodebuild failed. Last lines:\n" + "\n".join(tail))
    log(f"built {built_app(work, sdk)}")


def built_app(work, sdk="iphoneos"):
    products = os.path.join(work, "DerivedData", "Build", "Products", f"Release-{sdk}")
    apps = [n for n in os.listdir(products) if n.endswith(".app")] if os.path.isdir(products) else []
    if not apps:
        sys.exit("no built .app - run the xcode stage first")
    return os.path.join(products, apps[0])


def install(work, device):
    with open(os.path.join(work, "manifest.json")) as f:
        sdk = json.load(f)["sdk"]
    app = built_app(work, sdk)
    if sdk == "iphonesimulator":
        run(["xcrun", "simctl", "install", device or "booted", app])
        return
    from recomp import storage

    def on_line(line):
        events.check_hints(line)
        print(line, flush=True)
    storage.check_install(device, app)
    stream(["xcrun", "devicectl", "device", "install", "app", "--device", device, app], on_line)
