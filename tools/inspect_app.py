#!/usr/bin/env python3
"""Triage a macOS game bundle and report which iOS porting route applies.

Usage: inspect_app.py /path/to/Game.app [--json]

Read-only: it runs lipo/otool/plutil on the bundle and never modifies it.
"""
import json
import os
import plistlib
import subprocess
import sys

# Frameworks that exist on macOS but not on iPadOS. A binary linking these
# needs a shim (or a rewrite of the code that uses them).
MAC_ONLY_FRAMEWORKS = {
    "AppKit", "Cocoa", "Carbon", "OpenGL", "IOKit", "ApplicationServices",
    "CoreServices", "IOSurface", "ForceFeedback", "DiskArbitration",
    "SystemConfiguration", "Quartz", "QuartzCore", "CoreVideo", "AGL",
    "GLUT", "OpenCL", "ScreenCaptureKit", "Kernel", "Security",
}
# Frameworks present on both platforms (QuartzCore/CoreVideo/Security exist on
# iOS too but with a smaller API surface, so they are listed as "partial").
PARTIAL_FRAMEWORKS = {"QuartzCore", "CoreVideo", "Security", "SystemConfiguration",
                      "IOSurface", "CoreServices"}

PLATFORMS = {1: "macOS", 2: "iOS", 3: "tvOS", 4: "watchOS", 6: "MacCatalyst",
             7: "iOSSimulator"}


def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def is_macho(path):
    try:
        with open(path, "rb") as f:
            magic = f.read(4)
    except OSError:
        return False
    return magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe",
                     b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")


def archs(path):
    return run(["lipo", "-archs", path]).split()


def linked_libs(path, arch):
    out = run(["otool", "-arch", arch, "-L", path]).splitlines()[1:]
    return [line.strip().split(" (")[0] for line in out if line.strip()]


def build_version(path, arch):
    out = run(["otool", "-arch", arch, "-l", path]).splitlines()
    for i, line in enumerate(out):
        line = line.strip()
        if line == "cmd LC_BUILD_VERSION":
            info = {}
            for nxt in out[i + 1:i + 6]:
                parts = nxt.split()
                if len(parts) >= 2 and parts[0] in ("platform", "minos", "sdk"):
                    info[parts[0]] = parts[1]
            p = info.get("platform")
            if p and p.isdigit():
                info["platform"] = PLATFORMS.get(int(p), p)
            return info
        if line == "cmd LC_VERSION_MIN_MACOSX":
            ver = out[i + 2].split()[-1] if i + 2 < len(out) else "?"
            return {"platform": "macOS", "minos": ver}
    return {}


def framework_name(lib):
    if ".framework/" in lib:
        return lib.split(".framework/")[0].rsplit("/", 1)[-1]
    return None


def walk(root, limit=200000):
    n = 0
    for dirpath, dirnames, filenames in os.walk(root):
        for name in dirnames + filenames:
            n += 1
            if n > limit:
                return
            yield os.path.join(dirpath, name), name


def detect_engine(app, names, rels):
    lower = {n.lower() for n in names}

    def has(*xs):
        return any(x.lower() in lower for x in xs)

    def rel_has(fragment):
        return any(fragment in r for r in rels)

    if has("UnityPlayer.dylib") or has("globalgamemanagers", "data.unity3d") or rel_has("/Resources/Data/Managed/"):
        backend = "IL2CPP" if has("GameAssembly.dylib") else "Mono"
        return "Unity", backend
    if any(n.endswith(".pak") for n in lower) or rel_has("/Engine/Binaries/") or has("UE4Game", "UnrealGame"):
        return "Unreal", None
    if any(n.endswith(".pck") for n in lower) and rel_has("/Resources/"):
        return "Godot", None
    if has("game.ios", "game.unx", "data.win", "game.droid") or has("YoYoGames"):
        return "GameMaker", None
    if has("renpy") or any(n.endswith(".rpa") or n.endswith(".rpyc") for n in lower):
        return "RenPy", None
    if any(n.endswith(".love") for n in lower) or has("love.framework"):
        return "LOVE", None
    if has("rpg_core.js", "rmmz_core.js", "rpg_managers.js"):
        return "RPGMaker-MV/MZ (HTML5)", None
    if has("FNA.dll", "MonoGame.Framework.dll", "XNA.dll") or has("MonoBundle"):
        return "FNA/MonoGame (.NET)", None
    if has("Electron Framework.framework") or has("nwjs Framework.framework") or has("app.asar"):
        return "Electron/NW.js (HTML5)", None
    if has("Adobe AIR.framework"):
        return "Adobe AIR", None
    if any(n.endswith(".jar") for n in lower):
        return "Java", None
    if has("Wineskin", "wswine.bundle") or has("CrossOver") or rel_has("/drive_c/"):
        return "Wine wrapper (not native)", None
    if has("libSDL2.dylib", "SDL2.framework", "libSDL2-2.0.0.dylib", "SDL3.framework", "libSDL3.0.dylib"):
        return "Native (SDL)", None
    if has("Defold") or has("game.projectc"):
        return "Defold", None
    return "Native / unknown", None


ROUTES = {
    "retarget": "Route A - Mach-O retarget: patch the arm64 binaries to the iOS platform, "
                "redirect Mac-only imports to shim frameworks (AppKit-on-UIKit etc.), re-sign, package as .ipa.",
    "recompile": "Route B - static recompilation: x86_64-only code must be translated to arm64 "
                 "(iPadOS forbids JIT, so Rosetta-style dynamic translation is not available). Per-game effort.",
    "runtime": "Route C - engine runtime swap: keep the game's data/scripts, run them on the engine's own iOS runtime.",
    "webview": "Route C - HTML5 game: host its web content in a WKWebView iOS shell.",
    "il2cpp": "Route C - Unity: rebuild a matching-version Unity iOS player around the game's data; "
              "Mono assemblies can be AOT-converted with IL2CPP. Hard, version-specific.",
    "missing": "Nothing to port: the bundle has no executable code (a launcher shortcut, or the game is not installed).",
    "none": "No generic route: needs source code or the developer's iOS build.",
}


def recommend(engine, all_archs, mac_only):
    if not all_archs:
        return ["missing"]
    has_arm = "arm64" in all_archs
    if engine in ("Godot", "RenPy", "LOVE", "Defold"):
        return ["runtime"]
    if engine.startswith("RPGMaker") or engine.startswith("Electron"):
        return ["webview"]
    if engine == "Unity":
        return ["il2cpp", "retarget"] if has_arm else ["il2cpp"]
    if engine.startswith("FNA"):
        return ["runtime"]
    if engine in ("Java", "Adobe AIR", "Wine wrapper (not native)", "GameMaker"):
        return ["none"]
    if engine == "Unreal":
        return ["retarget"] if has_arm else ["none"]
    return ["retarget"] if has_arm else ["recompile"]


def inspect(app):
    app = os.path.abspath(app.rstrip("/"))
    contents = os.path.join(app, "Contents")
    info_path = os.path.join(contents, "Info.plist")
    info = {}
    if os.path.exists(info_path):
        with open(info_path, "rb") as f:
            try:
                info = plistlib.load(f)
            except Exception:
                info = {}
    exe_name = info.get("CFBundleExecutable", "")
    exe = os.path.join(contents, "MacOS", exe_name)

    names, rels, binaries = [], [], []
    total = 0
    for path, name in walk(app):
        names.append(name)
        rels.append(path[len(app):])
        if os.path.isfile(path) and not os.path.islink(path):
            total += os.path.getsize(path)
            if is_macho(path):
                binaries.append(path)

    engine, backend = detect_engine(app, names, rels)

    report_bins = []
    all_archs, mac_only, partial = set(), set(), set()
    for b in binaries:
        a = archs(b)
        all_archs.update(a)
        arch = "arm64" if "arm64" in a else (a[0] if a else None)
        libs = linked_libs(b, arch) if arch else []
        fws = sorted({framework_name(l) for l in libs if framework_name(l)})
        for fw in fws:
            if fw in PARTIAL_FRAMEWORKS:
                partial.add(fw)
            elif fw in MAC_ONLY_FRAMEWORKS:
                mac_only.add(fw)
        report_bins.append({
            "path": b[len(app) + 1:],
            "archs": a,
            "build": build_version(b, arch) if arch else {},
            "frameworks": fws,
            "dylibs": sorted(l for l in libs if not framework_name(l) and not l.startswith("/usr/lib/")),
        })

    main_ok = exe_name and os.path.exists(exe) and is_macho(exe)
    flags = []
    if exe_name and not main_ok:
        flags.append(f"Main executable '{exe_name}' is not a Mach-O binary (launcher script or shortcut?).")
        try:
            with open(exe, errors="replace") as f:
                script = f.read(4096)
            if "steam://run/" in script:
                appid = script.split("steam://run/")[1].split()[0]
                flags.append(f"Steam shortcut for app {appid}: inspect the real bundle under <SteamLibrary>/steamapps/common/.")
        except OSError:
            pass
    if os.path.exists(os.path.join(contents, "_MASReceipt")):
        flags.append("Mac App Store build (check for FairPlay encryption with `otool -l | grep cryptid`).")
    if any(n.startswith("libsteam_api") for n in names):
        flags.append("Links the Steamworks API: needs a stub libsteam_api for iOS (no Steam client there).")
    if "x86_64" in all_archs and "arm64" not in all_archs:
        flags.append("Intel-only: no arm64 code to reuse.")
    if engine == "Native / unknown" and "OpenGL" in mac_only:
        flags.append("Uses desktop OpenGL: iPadOS has none; needs a GL->Metal layer (e.g. MoltenGL/ANGLE/gl4es-style).")
    if total > 4 * 1024**3:
        flags.append(f"Bundle is {total / 1024**3:.1f} GB: check iPad storage and RAM limits.")

    return {
        "app": app,
        "name": info.get("CFBundleName") or os.path.basename(app),
        "bundle_id": info.get("CFBundleIdentifier"),
        "min_macos": info.get("LSMinimumSystemVersion"),
        "size_mb": round(total / 1024**2, 1),
        "engine": engine,
        "engine_backend": backend,
        "archs": sorted(all_archs),
        "mac_only_frameworks": sorted(mac_only),
        "partial_frameworks": sorted(partial),
        "binaries": report_bins,
        "flags": flags,
        "routes": [ROUTES[r] for r in recommend(engine, all_archs, mac_only)],
    }


def print_report(r):
    print(f"# {r['name']}  ({r['bundle_id']})")
    print(f"  path:     {r['app']}")
    print(f"  size:     {r['size_mb']} MB   min macOS: {r['min_macos']}")
    eng = r["engine"] + (f" [{r['engine_backend']}]" if r["engine_backend"] else "")
    print(f"  engine:   {eng}")
    print(f"  archs:    {', '.join(r['archs']) or '-'}")
    print(f"  Mac-only frameworks: {', '.join(r['mac_only_frameworks']) or 'none'}")
    print(f"  partial on iOS:      {', '.join(r['partial_frameworks']) or 'none'}")
    print(f"  Mach-O binaries ({len(r['binaries'])}):")
    for b in r["binaries"][:25]:
        bv = b["build"]
        print(f"    - {b['path']}  [{','.join(b['archs'])}]  {bv.get('platform', '?')} {bv.get('minos', '')}")
    if len(r["binaries"]) > 25:
        print(f"    ... {len(r['binaries']) - 25} more")
    for f in r["flags"]:
        print(f"  ! {f}")
    print("  Suggested route:")
    for route in r["routes"]:
        print(f"    * {route}")


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    if not args:
        print(__doc__.strip())
        return 2
    for app in args:
        r = inspect(app)
        if "--json" in argv:
            print(json.dumps(r, indent=2))
        else:
            print_report(r)
            print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
