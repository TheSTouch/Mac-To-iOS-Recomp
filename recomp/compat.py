"""How likely a scanned game is to port without changes, for the library list.

  tested      a profile records the game as played on an iPad ("tested")
  untested    nothing found that its route is known to trip over: may work out of the box
  needs_work  the route applies, but something here is known to stop it or to need a profile

The Unity checks mirror what unity_ios.py does with a game; the Unreal check runs
unreal_ios.py's import binding as a dry run (cached, since it reads the whole binary).
Each check returns (status, detail, checks): checks are the lines the app lists
under Compatibility.
"""
import contextlib
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys

from recomp import iossdk, paths, unity_ios, unreal_ios

PROFILES = os.path.join(paths.CODE, "recomp", "profiles")
CACHE = os.path.join(paths.HOME, "cache")

# The Unity line recomp/il2cpp_patches.py was written against. The patches check
# libil2cpp's exact source text, so another line most likely needs them redone.
PATCHED_UNITY = "6000"
# Shipped with the Unity player itself, not the game.
UNITY_RUNTIME = {"UnityPlayer.dylib", "libmonobdwgc-2.0.dylib", "libMonoPosixHelper.dylib", "libmono-native.dylib",
                 "MonoBleedingEdge"}
# Libraries that generate code at run time, which IL2CPP (no JIT on iOS) cannot do.
RUNTIME_CODEGEN = {
    "0Harmony.dll": "Harmony patches methods at run time",
    "MonoMod.RuntimeDetour.dll": "MonoMod patches methods at run time",
    "Handlebars.dll": "Handlebars.Net compiles its templates at run time",
}
# Class library and engine assemblies: they never P/Invoke a game's plugin.
NOT_GAME_CODE = ("System", "Mono.", "mscorlib", "netstandard", "Microsoft.", "UnityEngine")


def profiles():
    out = []
    for n in sorted(os.listdir(PROFILES)):
        if n.endswith(".json"):
            with open(os.path.join(PROFILES, n)) as f:
                out.append(json.load(f))
    return out


def tested(report):
    """(status, detail, checks) from the profile that records this game as tested, or None."""
    contents = os.path.join(report["app"], "Contents")
    for p in profiles():
        if not p.get("tested"):
            continue
        if report["engine"] == "Unity" and p.get("when_assembly"):
            hit = os.path.exists(os.path.join(contents, "Resources", "Data", "Managed", p["when_assembly"]))
        elif report["engine"] == "Unreal" and p.get("unreal_project"):
            hit = os.path.isdir(os.path.join(contents, "UE4", p["unreal_project"]))
        else:
            hit = False
        if hit:
            return "tested", f"Tested: {p['tested']}", []
    return None


# --- Unity (Mono) ------------------------------------------------------------------

def unity_version(contents):
    try:
        with open(os.path.join(contents, "Info.plist"), "rb") as f:
            info = plistlib.load(f)
    except Exception:
        return None
    m = re.search(r"Unity Player version (\S+) \(", info.get("CFBundleGetInfoString", ""))
    return m.group(1) if m else None


def native_plugins(contents):
    """{module name: file} for native libraries the game ships besides Unity's own."""
    found = {}
    for sub in ("PlugIns", "Frameworks"):
        d = os.path.join(contents, sub)
        if not os.path.isdir(d):
            continue
        for n in sorted(os.listdir(d)):
            if n in UNITY_RUNTIME or not n.endswith((".bundle", ".dylib", ".so")):
                continue
            module = re.sub(r"^lib", "", os.path.splitext(n)[0])
            found.setdefault(module, n)
    return found


def called_from_game(managed, modules):
    """The modules some game assembly names: a P/Invoke keeps its module name as a whole
    string in the metadata heap, with or without "lib" and the file extension."""
    wanted = {m: [b"\0" + v.encode() + b"\0" for v in {m, "lib" + m, f, os.path.splitext(f)[0]}]
              for m, f in modules.items()}
    hit = set()
    for n in os.listdir(managed):
        if not n.endswith(".dll") or n.startswith(NOT_GAME_CODE):
            continue
        try:
            with open(os.path.join(managed, n), "rb") as f:
                data = f.read()
        except OSError:
            continue
        hit.update(m for m, bs in wanted.items() if m not in hit and any(b in data for b in bs))
        if len(hit) == len(wanted):
            break
    return hit


def unity(report):
    contents = os.path.join(report["app"], "Contents")
    managed = os.path.join(contents, "Resources", "Data", "Managed")
    version = unity_version(contents)
    blockers, notes = [], []

    if not version:
        blockers.append("The Unity version is not in Info.plist; the route reads it to fetch the matching editor.")
    elif version.split(".")[0] != PATCHED_UNITY:
        blockers.append(f"Unity {version}: the libil2cpp patches were written against Unity 6 ({PATCHED_UNITY}.x) "
                        "and check its exact source, so this IL2CPP version will most likely need them redone.")

    stubbed = {m for prof in unity_ios.STUB_PROFILES.values() for m in prof["modules"]}
    plugins = {m: f for m, f in native_plugins(contents).items() if m not in stubbed}
    used = called_from_game(managed, plugins) if plugins and os.path.isdir(managed) else set()
    if used:
        blockers.append("Native plugins with no iOS version: " + ", ".join(sorted(plugins[m] for m in used)) +
                        ". Calls into them fail on iOS unless they get a stub (stubs/).")
    if set(plugins) - used:
        notes.append("Ships native libraries no game assembly calls (harmless on iOS): " +
                     ", ".join(sorted(plugins[m] for m in set(plugins) - used)) + ".")

    for dll, why in sorted(RUNTIME_CODEGEN.items()):
        if os.path.exists(os.path.join(managed, dll)):
            blockers.append(f"Ships {dll}: {why}, which IL2CPP cannot do. The code that uses it needs a "
                            "guard in a game profile (recomp/profiles).")

    if not os.path.exists(os.path.join(managed, "Unity.InputSystem.dll")):
        notes.append("Uses Unity's legacy input: taps act as left clicks (Unity's own touch-to-mouse); "
                     "the touch gestures for right click, scroll and drags need the Input System package.")
    if "arm64" not in report["archs"]:
        notes.append("Intel-only on the Mac does not matter here: the game's .NET code is recompiled for iOS.")

    label = f"Unity {version or '?'} (Mono)"
    if blockers:
        return "needs_work", f"{label}: the route applies, but something here needs work first.", blockers + notes
    return ("untested", f"Untested: {label}, nothing the route is known to trip over. May work out of the box.",
            notes)


# --- Unreal --------------------------------------------------------------------------

def shim_exports():
    """Symbols RecompAppKit.dylib exports, built once per version of its sources."""
    h = hashlib.sha256()
    src = os.path.join(unreal_ios.NATIVE_SRC, "appkit")
    for p in sorted(os.path.join(src, n) for n in os.listdir(src)) + [unreal_ios.__file__]:
        with open(p, "rb") as f:
            h.update(f.read())
    work = os.path.join(CACHE, "appkit-shim-" + h.hexdigest()[:12])
    shim = os.path.join(work, "shims", unreal_ios.SHIM_NAME)
    if not os.path.exists(shim):
        unreal_ios.build_shims(work)
    return h.hexdigest()[:12], unreal_ios.exported(shim)


def import_blockers(app):
    """unreal_ios.blockers() for this game, cached on the main binary and the shim's version."""
    game = unreal_ios.Game(app)
    main = os.path.join(game.contents, "MacOS", game.executable)
    shim_id, shim_syms = shim_exports()
    st = os.stat(main)
    key = f"{shim_id}:{iossdk.sdk_version()}:{st.st_size}:{int(st.st_mtime)}"
    cache_file = os.path.join(CACHE, "compat-unreal.json")
    try:
        with open(cache_file) as f:
            cache = json.load(f)
    except (OSError, ValueError):
        cache = {}
    if cache.get(app, {}).get("key") == key:
        return cache[app]["blockers"]
    found = unreal_ios.blockers(game, iossdk.index(CACHE), shim_syms)
    cache[app] = {"key": key, "blockers": found}
    os.makedirs(CACHE, exist_ok=True)
    with open(cache_file, "w") as f:
        json.dump(cache, f, indent=1)
    return found


def unreal(report):
    contents = os.path.join(report["app"], "Contents")
    if not os.path.isdir(os.path.join(contents, "UE4")):
        layout = "Unreal Engine 5 (Contents/UE)" if os.path.isdir(os.path.join(contents, "UE")) else "This layout"
        return ("needs_work", "Unreal: the route applies, but something here needs work first.",
                [f"{layout}: the route only knows Unreal Engine 4's bundle layout (Contents/UE4)."])
    try:
        # The route's own logging would end up in the scan's JSON on stdout.
        with contextlib.redirect_stdout(sys.stderr):
            blockers = import_blockers(report["app"])
    except (OSError, subprocess.CalledProcessError, SystemExit) as e:
        return ("untested", "Untested: Unreal Engine 4, arm64. Imports not checked.",
                [f"Could not check the imports (needs Xcode's iOS SDK): {e}"])
    if blockers:
        return "needs_work", "Unreal Engine 4: the route applies, but something here needs work first.", blockers
    return "untested", "Untested: Unreal Engine 4, arm64, every import binds on iOS. May work out of the box.", []


def classify(report):
    """(status, detail, checks) for a game the Unity (Mono) or Unreal (arm64) route handles."""
    return tested(report) or (unity(report) if report["engine"] == "Unity" else unreal(report))
