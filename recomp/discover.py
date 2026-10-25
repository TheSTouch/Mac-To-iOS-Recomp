"""Find installed Mac games and the local build environment.

scan(): .app bundles in the usual store and launcher locations plus any extra
folders, each triaged by tools/inspect_app.py. environment(): tools the
pipeline needs, signing identities and connected devices.
"""
import json
import os
import plistlib
import re
import shutil
import subprocess

import inspect_app

HOME = os.path.expanduser("~")
STEAM_ROOTS = [os.path.join(HOME, "Library", "Application Support", "Steam")]
FIXED_ROOTS = [
    ("Applications", "/Applications", 1),
    ("Applications", os.path.join(HOME, "Applications"), 1),
    ("GOG", "/Applications/GOG Games", 2),
    ("Epic", "/Users/Shared/Epic Games", 2),
    ("itch", os.path.join(HOME, "Library", "Application Support", "itch", "apps"), 2),
    ("Heroic", os.path.join(HOME, "Games", "Heroic"), 2),
]
GAME_CATEGORY = "public.app-category."


def steam_libraries():
    libs = []
    for root in STEAM_ROOTS:
        vdf = os.path.join(root, "steamapps", "libraryfolders.vdf")
        paths = [root]
        if os.path.exists(vdf):
            paths += re.findall(r'"path"\s+"([^"]+)"', open(vdf, errors="replace").read())
        for p in paths:
            common = os.path.join(p, "steamapps", "common")
            if os.path.isdir(common) and common not in libs:
                libs.append(common)
    return libs


def find_apps(root, depth):
    found = []
    if not os.path.isdir(root):
        return found
    try:
        entries = sorted(os.listdir(root))
    except OSError:
        return found
    for name in entries:
        path = os.path.join(root, name)
        if name.endswith(".app"):
            found.append(path)
        elif depth > 1 and os.path.isdir(path) and not os.path.islink(path):
            found += find_apps(path, depth - 1)
    return found


def looks_like_game(app):
    """For general app folders: keep bundles that say they are games or use a known engine."""
    try:
        with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
            info = plistlib.load(f)
    except Exception:
        return False
    if str(info.get("LSApplicationCategoryType", "")).startswith(GAME_CATEGORY + "games") or \
            "games" in str(info.get("LSApplicationCategoryType", "")):
        return True
    res = os.path.join(app, "Contents", "Resources")
    fw = os.path.join(app, "Contents", "Frameworks")
    markers = [os.path.join(res, "Data", "Managed"), os.path.join(fw, "UnityPlayer.dylib"),
               os.path.join(res, "renpy"), os.path.join(fw, "love.framework")]
    if any(os.path.exists(m) for m in markers):
        return True
    return any(n.endswith((".pck", ".pak", ".love")) for n in os.listdir(res)) if os.path.isdir(res) else False


def status_of(report):
    engine = report["engine"]
    if not report["archs"]:
        return "missing", "No game code in this bundle (a launcher shortcut, or not fully installed)."
    if engine == "Unity" and report.get("engine_backend") == "Mono":
        return "supported", "Unity (Mono): recompiled to native iPad code with IL2CPP."
    if engine == "Unity":
        return "planned", "Unity (IL2CPP): needs the planned binary retarget route."
    if "x86_64" in report["archs"] and "arm64" not in report["archs"]:
        return "unsupported", "Intel-only: iPadOS forbids the JIT a translator would need."
    if engine in ("Godot", "RenPy", "LOVE", "Defold") or engine.startswith(("RPGMaker", "Electron")):
        return "planned", f"{engine}: planned engine-runtime route."
    if engine in ("Java", "Adobe AIR", "Wine wrapper (not native)", "GameMaker"):
        return "unsupported", f"{engine}: no generic route."
    return "planned", "Native Apple Silicon: planned binary retarget route."


def scan(extra_dirs=(), quick=True):
    seen, games = set(), []
    sources = [(f"Steam", lib, 2) for lib in steam_libraries()]
    sources += FIXED_ROOTS + [("Custom", d, 3) for d in extra_dirs]
    for source, root, depth in sources:
        for app in find_apps(root, depth):
            real = os.path.realpath(app)
            if real in seen:
                continue
            seen.add(real)
            if source in ("Applications",) and not looks_like_game(app):
                continue
            report = inspect_app.inspect(app, quick=quick)
            report["source"] = source
            report["status"], report["status_detail"] = status_of(report)
            games.append(report)
    return games


def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def environment():
    tools = {
        "xcode": bool(run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"]).strip()),
        "dotnet": shutil.which("dotnet") is not None or os.path.exists("/usr/local/share/dotnet/dotnet")
                  or os.path.exists("/opt/homebrew/bin/dotnet"),
        "python3": True,
    }
    identities = []
    for line in run(["security", "find-identity", "-v", "-p", "codesigning"]).splitlines():
        m = re.search(r'"(Apple Development: .+ \((\w+)\))"', line)
        if m:
            identities.append({"name": m.group(1)})
    teams = []
    for ident in identities:
        pem = run(["security", "find-certificate", "-c", ident["name"], "-p"])
        subj = subprocess.run(["openssl", "x509", "-noout", "-subject"], input=pem,
                              capture_output=True, text=True).stdout
        m = re.search(r"OU\s*=\s*(\w+)", subj)
        if m and m.group(1) not in [t["id"] for t in teams]:
            teams.append({"id": m.group(1), "identity": ident["name"]})
    devices = []
    out = os.path.join(os.environ.get("TMPDIR", "/tmp"), "recomp-devices.json")
    run(["xcrun", "devicectl", "list", "devices", "--json-output", out])
    try:
        with open(out) as f:
            for d in json.load(f)["result"]["devices"]:
                props, hw = d.get("deviceProperties", {}), d.get("hardwareProperties", {})
                if hw.get("platform") != "iOS":
                    continue
                devices.append({"id": d.get("identifier"), "name": props.get("name"),
                                "model": hw.get("marketingName"), "type": hw.get("deviceType"),
                                "state": d.get("connectionProperties", {}).get("tunnelState")})
        os.remove(out)
    except (OSError, KeyError, ValueError):
        pass
    return {"tools": tools, "teams": teams, "devices": devices}
