"""Port a Unity (Mono) macOS game to iOS (iPhone and iPad) by recompiling its managed code with IL2CPP.

Stages, each runnable on its own (see recomp.py):
  prepare   generate a shell Unity project holding the game's own assemblies as iOS plugins
  player    run the matching Unity editor in batchmode to produce an iOS Xcode project
  inject    replace the shell's data in that Xcode project with the game's real data
  xcode     build and sign the app with xcodebuild
  install   install it on a connected device
"""
import hashlib
import json
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import time

from recomp import events, paths, storage

ROOT = paths.CODE
# Built helpers live under HOME: CODE may be a signed, read-only app bundle.
ASMTOOL = os.path.join(paths.HOME, "bin", "asmtool", "asmtool")
STUBS = os.path.join(ROOT, "stubs")
EDITOR_SRC = os.path.join(ROOT, "recomp", "unity_editor")
SHIMS = os.path.join(ROOT, "recomp", "shims")
BUILTIN_MODS = os.path.join(ROOT, "recomp", "builtin_mods")
NATIVE_SRC = os.path.join(ROOT, "recomp", "native")
PROFILES = os.path.join(ROOT, "recomp", "profiles")
# The Unreal route's libsteam_api stand-in; Unity ports get SteamAPI_* from recomp_native_stubs.c.
NATIVE_SKIP = {"steam_api_stub.c"}

# Managed shims added to the game, each enabled when the game ships the
# assembly it builds on (every game when "requires" is None), and started
# through RuntimeInitializeOnLoads.json.
SHIM_SPECS = [
    {"project": "RecompPhone", "assembly": "Recomp.Phone", "requires": None,
     "init": [{"nameSpace": "Recomp", "className": "PhoneSettings", "methodName": "Install", "loadTypes": 1},
              {"nameSpace": "Recomp", "className": "BuiltinMods", "methodName": "Install", "loadTypes": 1}]},
    {"project": "RecompTouchMouse", "assembly": "Recomp.TouchMouse", "requires": "Unity.InputSystem.dll",
     "init": [{"nameSpace": "Recomp", "className": "TouchMouse", "methodName": "Install", "loadTypes": 1}]},
]

# Native libraries with a hand-written override file in stubs/. Their P/Invokes
# are redirected to a generated static stub instead of a library iOS lacks.
STUB_PROFILES = {
    "steamworks": {
        "modules": ["steam_api", "steam_api64", "sdkencryptedappticket", "sdkencryptedappticket64"],
        "overrides": ["steamworks.overrides.c"],
    },
    # Crossplay networking: fails to initialise, so games stay offline.
    "playfab-party": {
        "modules": ["PlayFabPartyMacOS", "PartyXboxLiveWin32"],
        "overrides": ["playfab-party.overrides.c"],
    },
    # Apple's Unity plug-ins in their Mac build (Game Center and friends).
    "apple-plugins": {
        "modules": ["AppleCoreNativeMac", "GameKitWrapper"],
        "overrides": ["apple-plugins.overrides.c"],
    },
    "valheim": {
        "modules": ["DiskSpacePlugin", "libHasPreciseScrolling", "libMacScreenScale"],
        "overrides": ["valheim.overrides.c"],
    },
}

# Data files that come from the shell build rather than the game: the IL2CPP
# metadata must describe the code we compiled, and the default resources hold
# iOS-compiled built-in shaders.
KEEP_FROM_SHELL = {"Managed", "unity default resources", "Resources/unity default resources"}

# What every Unity port does on an iPhone, under a profile's "iphone" block (Recomp.Phone
# applies it at startup, only on iPhones):
#   render_scale       0-1, the render resolution as a fraction of native (Screen.SetResolution)
#   target_frame_rate  Application.targetFrameRate
#   quality_level      an index into the game's QualitySettings (each game has its own: per game only)
#   player_prefs       {key: value}, each written only when the player has none yet
#   portrait           true: the iPhone also plays upright (home indicator down) and rotates with
#                      the phone; the iPad stays landscape (Info.plist ~ipad key, and at runtime)
#   static_fields      {"<Assembly>.dll": {"Namespace.Type::field": value}}: a static field of the game's
#                      set at startup (e.g. a UI layout constant; per game only)
#   portrait_horizontal_fov  upright, the degrees across a perspective camera shows (default: the
#                      game's own, vertical, field of view, so upright is as wide as landscape is tall)
PHONE_DEFAULTS = {"render_scale": 0.75, "portrait": False}

# Serialized-file target platform ids (BuildTarget).
TARGET_OSX, TARGET_IOS = 2, 9


def log(msg):
    print(f"[recomp] {msg}", flush=True)


def run(cmd, **kw):
    log("$ " + " ".join(cmd))
    subprocess.run(cmd, check=True, **kw)


def stream(cmd, on_line, **kw):
    """Run cmd, passing each output line to on_line; raise on failure."""
    log("$ " + " ".join(cmd))
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1, **kw)
    for line in proc.stdout:
        on_line(line.rstrip("\n"))
    if proc.wait() != 0:
        raise subprocess.CalledProcessError(proc.returncode, cmd)


def dotnet_build(project, out, *props):
    """Build a .NET project from a copy under HOME, keeping obj/ out of CODE."""
    src = os.path.join(paths.HOME, "src", os.path.basename(project))
    shutil.rmtree(src, ignore_errors=True)
    shutil.copytree(project, src, ignore=shutil.ignore_patterns("bin", "obj"))
    run(["dotnet", "build", src, "-c", "Release", "-nologo", "-v", "q", "-o", out, *props])


class Game:
    def __init__(self, app):
        self.app = os.path.abspath(app.rstrip("/"))
        contents = os.path.join(self.app, "Contents")
        with open(os.path.join(contents, "Info.plist"), "rb") as f:
            self.info = plistlib.load(f)
        self.data = os.path.join(contents, "Resources", "Data")
        self.managed = os.path.join(self.data, "Managed")
        if not os.path.isdir(self.managed):
            sys.exit(f"{self.app}: no Contents/Resources/Data/Managed - not a Unity Mono build")
        m = re.search(r"Unity Player version (\S+) \((\w+)\)", self.info.get("CFBundleGetInfoString", ""))
        if not m:
            sys.exit("Could not read the Unity version from Info.plist")
        self.unity_version, self.changeset = m.group(1), m.group(2)
        self.name = self.info.get("CFBundleName") or os.path.splitext(os.path.basename(self.app))[0]
        self.slug = re.sub(r"[^A-Za-z0-9]", "", self.name)


def editor_paths(version, unity_root=None):
    base = unity_root or os.path.join(paths.TOOLCHAIN, f"Unity-{version}")
    unity = os.path.join(base, "Unity.app")
    ios = os.path.join(base, "PlaybackEngines", "iOSSupport")
    if not os.path.isdir(unity) or not os.path.isdir(ios):
        sys.exit(f"Unity {version} with iOS support not found under {base}.\n"
                 "Run: python3 recomp.py toolchain <Game.app>")
    return unity, ios


def aot_profile(unity):
    """The class library IL2CPP compiles against, and its facades."""
    prof = os.path.join(unity, "Contents", "Resources", "Scripting", "MonoBleedingEdge", "lib", "mono", "unityaot-macos")
    return [prof, os.path.join(prof, "Facades")]


def engine_assemblies(unity, ios):
    """Assembly names IL2CPP supplies itself: engine modules and the AOT class library."""
    names = set()
    dirs = [os.path.join(ios, "Variations", "il2cpp", "Releasearm64_managed")] + aot_profile(unity)
    for d in dirs:
        if os.path.isdir(d):
            names.update(n for n in os.listdir(d) if n.endswith(".dll"))
    return names


def is_engine(name, engine_names):
    return name in engine_names or name == "UnityEngine.dll" or re.fullmatch(r"UnityEngine\.\w+Module\.dll", name) is not None


def ensure_asmtool():
    """Build asmtool when missing or older than its sources."""
    src = os.path.join(ROOT, "tools", "asmtool")
    newest = max(os.path.getmtime(os.path.join(src, n)) for n in os.listdir(src) if n.endswith((".cs", ".csproj")))
    if not os.path.exists(ASMTOOL) or os.path.getmtime(ASMTOOL) < newest:
        dotnet_build(os.path.join(ROOT, "tools", "asmtool"), os.path.dirname(ASMTOOL))


def scan_pinvokes(managed_dir):
    ensure_asmtool()
    out = subprocess.run([ASMTOOL, "scan", managed_dir], capture_output=True, text=True, check=True).stdout
    libs = {}
    section = None
    for line in out.splitlines():
        if line.startswith("== "):
            section = line
        elif "P/Invoke" in (section or "") and ": " in line:
            lib, users = line.rsplit(": ", 1)
            libs[lib] = users.split(", ")
    return libs


def plugin_meta(name):
    guid = hashlib.md5(("recomp:" + name).encode()).hexdigest()
    return f"""fileFormatVersion: 2
guid: {guid}
PluginImporter:
  externalObjects: {{}}
  serializedVersion: 2
  iconMap: {{}}
  executionOrder: {{}}
  defineConstraints: []
  isPreloaded: 0
  isOverridable: 0
  isExplicitlyReferenced: 1
  validateReferences: 0
  platformData:
  - first:
      Any:
    second:
      enabled: 0
      settings: {{}}
  - first:
      Editor: Editor
    second:
      enabled: 0
      settings:
        DefaultValueInitialized: true
  - first:
      iPhone: iOS
    second:
      enabled: 1
      settings: {{}}
  userData:
  assetBundleName:
  assetBundleVariant:
"""


def native_meta(name):
    guid = hashlib.md5(("recomp-native:" + name).encode()).hexdigest()
    return f"""fileFormatVersion: 2
guid: {guid}
PluginImporter:
  externalObjects: {{}}
  serializedVersion: 2
  iconMap: {{}}
  executionOrder: {{}}
  defineConstraints: []
  isPreloaded: 0
  isOverridable: 0
  isExplicitlyReferenced: 0
  validateReferences: 1
  platformData:
  - first:
      Any:
    second:
      enabled: 0
      settings: {{}}
  - first:
      iPhone: iOS
    second:
      enabled: 1
      settings: {{}}
  userData:
  assetBundleName:
  assetBundleVariant:
"""


def prepare(game, work, unity, ios):
    shell = os.path.join(work, "shell")
    plugins = os.path.join(shell, "Assets", "Plugins", "Game")
    native = os.path.join(shell, "Assets", "Plugins", "iOS")
    if os.path.isdir(shell):
        # Keep Library/ (the import cache) but regenerate everything we own.
        for sub in ("Assets", "Packages", "ProjectSettings"):
            shutil.rmtree(os.path.join(shell, sub), ignore_errors=True)
    os.makedirs(plugins)
    os.makedirs(native)
    os.makedirs(os.path.join(shell, "Packages"))
    os.makedirs(os.path.join(shell, "ProjectSettings"))

    engine_names = engine_assemblies(unity, ios)
    game_dlls = sorted(n for n in os.listdir(game.managed) if n.endswith(".dll") and not is_engine(n, engine_names))
    log(f"{len(game_dlls)} game assemblies to recompile, {len(os.listdir(game.managed)) - len(game_dlls)} supplied by Unity")

    # Decide which native libraries to replace with stubs.
    pinvokes = scan_pinvokes(game.managed)
    to_stub, overrides = set(), []
    # A game profile can swap a stub profile's overrides ("stub_overrides"),
    # e.g. Steamworks that signs in instead of reporting "no Steam".
    swap = (game_profile(game) or {}).get("stub_overrides", {})
    for key, prof in STUB_PROFILES.items():
        hit = [m for m in prof["modules"] if m in pinvokes and any(u in game_dlls for u in pinvokes[m])]
        if hit:
            to_stub.update(hit)
            overrides += [os.path.join(STUBS, o) for o in swap.get(key, prof["overrides"])]
    users = sorted({u for m in to_stub for u in pinvokes[m] if u in game_dlls})

    for n in game_dlls:
        if n not in users:
            shutil.copy2(os.path.join(game.managed, n), os.path.join(plugins, n))
    if users:
        cmd = [ASMTOOL, "internalize", "--out", plugins, "--stub", os.path.join(native, "recomp_native_stubs.c")]
        for o in overrides:
            cmd += ["--overrides", o]
        for m in sorted(to_stub):
            cmd += ["--module", m]
        run(cmd + [os.path.join(game.managed, u) for u in users])
        with open(os.path.join(native, "recomp_native_stubs.c.meta"), "w") as f:
            f.write(native_meta("recomp_native_stubs.c"))
    applied = apply_profiles(game, game_dlls, plugins)
    shims = build_shims(game, os.path.join(work, "shims"))
    for dll in shims:
        shutil.copy2(dll, plugins)
    game_dlls += [os.path.basename(d) for d in shims]
    mod_list, mod_dlls = prepare_mods(game, work, unity, plugins, game_dlls, engine_names)
    game_dlls += mod_dlls
    for n in game_dlls:
        with open(os.path.join(plugins, n + ".meta"), "w") as f:
            f.write(plugin_meta(n))

    # Native start-up fixes shared by every port.
    for n in sorted(os.listdir(NATIVE_SRC)):
        src = os.path.join(NATIVE_SRC, n)
        if n in NATIVE_SKIP or not os.path.isfile(src) or not n.endswith((".c", ".m", ".mm")):
            continue
        shutil.copy2(src, native)
        with open(os.path.join(native, n + ".meta"), "w") as f:
            f.write(native_meta(n))

    # Preserve every game assembly from the managed linker: reflection-driven
    # code (dependency injection, serializers) would otherwise lose types. Engine
    # modules too: the game's data references engine types (e.g. UI Toolkit's
    # UxmlSerializedData) that the empty shell scene never uses.
    engine_used = sorted(n for n in os.listdir(game.managed)
                         if n in engine_names and n.startswith("UnityEngine"))
    with open(os.path.join(shell, "Assets", "link.xml"), "w") as f:
        f.write("<linker>\n")
        for n in game_dlls + engine_used:
            f.write(f'  <assembly fullname="{n[:-4]}" preserve="all"/>\n')
        f.write("</linker>\n")

    builtin = os.path.join(unity, "Contents", "Resources", "PackageManager", "BuiltInPackages")
    modules = sorted(n for n in os.listdir(builtin) if n.startswith("com.unity.modules.") and not n.endswith(".sha1"))
    with open(os.path.join(shell, "Packages", "manifest.json"), "w") as f:
        json.dump({"dependencies": {m: "1.0.0" for m in modules}}, f, indent=2)
    with open(os.path.join(shell, "ProjectSettings", "ProjectVersion.txt"), "w") as f:
        f.write(f"m_EditorVersion: {game.unity_version}\nm_EditorVersionWithRevision: {game.unity_version} ({game.changeset})\n")

    shutil.copytree(EDITOR_SRC, os.path.join(shell, "Assets", "Editor"))
    with open(os.path.join(work, "prepare.json"), "w") as f:
        json.dump({"game": game.app, "unity": game.unity_version, "assemblies": game_dlls,
                   "stubbed_modules": sorted(to_stub), "internalized": users,
                   "shims": [os.path.basename(d)[:-4] for d in shims], "profiles": applied,
                   "mods": mod_list}, f, indent=2)
    log(f"shell project ready: {shell}")


def mods_config(game, work):
    """The profile's "mods" block, with the folder its built-in mods are laid out in."""
    from recomp import mods
    cfg = mods.config(game_profile(game))
    if cfg and cfg.get("builtin"):
        cfg = dict(cfg, builtin_dir=os.path.join(work, "builtin-mods"))
    return cfg


def stage_builtin_mods(game, cfg, shims=None, harmony=None):
    """Lay out the profile's built-in mods (recomp/builtin_mods/<path>) as mod folders in
    work/builtin-mods: the manifest and, given the port's shim build folder and the Harmony
    stand-in's, the mod's DLL."""
    out = (cfg or {}).get("builtin_dir")
    if not out:
        return
    for rel in cfg["builtin"]:
        src = os.path.join(BUILTIN_MODS, rel)
        dst = os.path.join(out, os.path.basename(rel))
        os.makedirs(dst, exist_ok=True)
        shutil.copy2(os.path.join(src, cfg.get("manifest", "manifest.json")), dst)
        if shims:
            dotnet_build(src, dst, f"-p:GameManaged={game.managed}", f"-p:RecompShims={shims}",
                         f"-p:RecompHarmony={harmony}")


def prepare_mods(game, work, unity, plugins, game_dlls, engine_names):
    """Compile in the code of the mods installed on the Mac (recomp/mods.py).
    Writes work/mods.json for inject; returns (mods for prepare.json, plugin file names)."""
    from recomp import mods
    table = os.path.join(work, "mods.json")
    if os.path.exists(table):
        os.remove(table)
    cfg = mods_config(game, work)
    if not cfg:
        return [], []
    existing = {n[:-4] for n in game_dlls} | {n[:-4] for n in engine_names}
    version = game.info.get("CFBundleShortVersionString", "0")
    harmony = os.path.join(work, "harmony")
    dotnet_build(os.path.join(SHIMS, "RecompHarmony"), harmony)
    shims = os.path.join(work, "shims")
    stage_builtin_mods(game, cfg, shims, harmony)
    search = aot_profile(unity) + [game.managed, shims]
    found, assemblies = mods.prepare(cfg, version, ASMTOOL, search, existing,
                                     {"0Harmony": os.path.join(harmony, "0Harmony.dll")}, mods.excluded(work))
    added = []
    for name, a in sorted(assemblies.items()):
        if a["path"]:  # not one the game already ships
            shutil.copy2(a["path"], os.path.join(plugins, name + ".dll"))
            added.append(name + ".dll")
    mods.weave(ASMTOOL, plugins, search, found, assemblies)
    mods.report(found, log)
    with open(table, "w") as f:
        json.dump({"assemblies": {n: a["hashes"] for n, a in assemblies.items() if a["path"]}}, f, indent=2)
    log(f"mods: {len(added)} mod assemblies compiled in" + (f" ({', '.join(n[:-4] for n in added)})" if added else ""))
    return found, added


def plan_mods(game, work, unity=None):
    """What the next port would do with each mod on the Mac (selection and checks), without
    building anything. Without the game's Unity editor the checks cannot run: status "unchecked"."""
    from recomp import mods
    cfg = mods_config(game, work)
    if not cfg:
        return None, []
    stage_builtin_mods(game, cfg)
    version = game.info.get("CFBundleShortVersionString", "0")
    skip = mods.excluded(work)
    base = unity or os.path.join(paths.TOOLCHAIN, f"Unity-{game.unity_version}")
    unity_app, ios = os.path.join(base, "Unity.app"), os.path.join(base, "PlaybackEngines", "iOSSupport")
    if not os.path.isdir(unity_app) or not os.path.isdir(ios):
        found = mods.find(cfg, version)
        for m in found:
            m.setdefault("status", "excluded" if m["id"] in skip else "unchecked")
            if m["status"] == "unchecked":
                m["reason"] = f"checked once Unity {game.unity_version} is installed (first port)"
        return cfg, found
    ensure_asmtool()
    engine_names = engine_assemblies(unity_app, ios)
    game_dlls = [n for n in os.listdir(game.managed) if n.endswith(".dll") and not is_engine(n, engine_names)]
    existing = {n[:-4] for n in game_dlls} | {n[:-4] for n in engine_names}
    harmony = os.path.join(work, "harmony")
    if not os.path.exists(os.path.join(harmony, "0Harmony.dll")):
        dotnet_build(os.path.join(SHIMS, "RecompHarmony"), harmony)
    found, _ = mods.prepare(cfg, version, ASMTOOL, aot_profile(unity_app) + [game.managed, os.path.join(work, "shims")],
                            existing, {"0Harmony": os.path.join(harmony, "0Harmony.dll")}, skip)
    for m in found:
        if m["source"] == mods.BUILTIN and m["status"] == "data only":  # its DLL is built by the first port
            m.update(status="unchecked", reason="built and checked when the game is ported")
    return cfg, found


def push_mods(game, work, device, bundle_id, everything=False):
    """Copy the mods the last port handled (compiled in, or data only) to the iOS device's mod folder.
    everything: also mods whose code is not in the port (their data loads, their code is skipped)."""
    from recomp import mods
    cfg = mods_config(game, work)
    if not cfg:
        return
    try:
        with open(os.path.join(work, "prepare.json")) as f:
            last = {m["folder"]: m for m in json.load(f).get("mods", [])}
    except (OSError, ValueError):
        last = {}
    found = mods.find(cfg, game.info.get("CFBundleShortVersionString", "0"))
    for m in found:
        m.update({k: v for k, v in last.get(m["folder"], {}).items() if k in ("status", "reason")})
        m.setdefault("status", "not ported (installed after the last port)")
    chosen = [m for m in found if everything or m["status"] in ("compiled", "data only")]
    if not chosen:
        log("mods: none to copy to the iPhone or iPad")
        return
    mods.push(chosen, cfg, os.path.join(work, "mods-stage"), device, bundle_id, log)
    log(f"mods: {len(chosen)} copied to {cfg['ios']}; not copied: " + (", ".join(m["name"] for m in found if m not in chosen) or "none"))


def mod_assemblies(work):
    path = os.path.join(work, "mods.json")
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        return json.load(f)["assemblies"]


def game_profile(game):
    """The recomp/profiles/*.json entry for this game, if any (matched by its when_assembly)."""
    for name in sorted(os.listdir(PROFILES)):
        if name.endswith(".json"):
            with open(os.path.join(PROFILES, name)) as f:
                profile = json.load(f)
            if os.path.exists(os.path.join(game.managed, profile.get("when_assembly") or "\0")):
                return profile
    return None


def phone_settings(profile):
    """recomp.json "phone": the profile's "iphone" block over PHONE_DEFAULTS, shaped for
    JsonUtility (PlayerPrefs as a list, each value as a string with its type)."""
    phone = dict(PHONE_DEFAULTS, **(profile.get("iphone") or {}))
    def typed(value):
        kind = "int" if isinstance(value, (bool, int)) else "float" if isinstance(value, float) else "string"
        return {"type": kind, "value": str(int(value) if isinstance(value, bool) else value)}
    prefs = [dict(typed(value), key=key) for key, value in (phone.get("player_prefs") or {}).items()]
    fields = [dict(typed(value), assembly=dll, name=name)
              for dll, values in (phone.get("static_fields") or {}).items() for name, value in values.items()]
    return {"renderScale": float(phone.get("render_scale") or 0),
            "targetFrameRate": int(phone.get("target_frame_rate") or 0),
            "qualityLevel": int(phone["quality_level"]) if phone.get("quality_level") is not None else -1,
            "playerPrefs": prefs,
            "staticFields": fields,
            "portrait": bool(phone.get("portrait")),
            "portraitHorizontalFov": float(phone.get("portrait_horizontal_fov") or 0)}


def write_shim_config(game, data):
    """StreamingAssets/recomp.json (Data/Raw on iOS): per-game switches the managed shims read,
    e.g. the on-screen gamepad that action games opt into with the profile's "touch_gamepad",
    the extra on-screen keys of its "touch_keys" ([{"label", "keys": [Input System key names]}]),
    the corner they go in ("touch_keys_corner": "left", "right", or "island": beside a
    phone's Dynamic Island when held sideways, bottom-right otherwise), touches on the game's UI left
    to it as real touches ("touch_ui"),
    the iPhone settings of its "iphone" block (see PHONE_DEFAULTS),
    and the PlayerPrefs keys that keep the port's built-in mods on (mods.builtin_enabled_prefs)."""
    from recomp import mods
    profile = game_profile(game) or {}
    os.makedirs(os.path.join(data, "Raw"), exist_ok=True)
    phone = phone_settings(profile)
    builtin = mods.builtin_enabled_prefs(mods.config(profile), BUILTIN_MODS)
    with open(os.path.join(data, "Raw", "recomp.json"), "w") as f:
        json.dump({"touchGamepad": bool(profile.get("touch_gamepad")),
                   "touchUi": bool(profile.get("touch_ui")),
                   "touchKeys": profile.get("touch_keys", []),
                   "touchKeysCorner": profile.get("touch_keys_corner", "left"),
                   "phone": phone,
                   "builtinModPrefs": builtin}, f)
    log(f"recomp.json phone settings: {phone}")
    if builtin:
        log(f"recomp.json built-in mods kept enabled: {', '.join(builtin)}")


def write_save_info(game, xcode_dir):
    """Info.plist keys of the port's save sync (recomp/steam_cloud.py): the game's name,
    RecompSavesMode, and RecompSaves for the iCloud Drive sync (RecompSaves.m) or
    RecompSteamCloud for Steam Cloud (RecompSteam/cloud*.m). recomp.py sets game.saves_mode
    from --saves; without it, the default for the game."""
    from recomp import steam_cloud
    path = os.path.join(xcode_dir, "Info.plist")
    with open(path, "rb") as f:
        info = plistlib.load(f)
    info["RecompGame"] = game.name
    for k in ("RecompSavesMode", "RecompSaves", "RecompSteamCloud"):
        info.pop(k, None)
    info.update(steam_cloud.plist_keys(game.app, game_profile(game), getattr(game, "saves_mode", None), "ios", log))
    with open(path, "wb") as f:
        plistlib.dump(info, f)
    log(f"Info.plist: RecompGame={game.name}, RecompSavesMode={info['RecompSavesMode']}")


def apply_profiles(game, game_dlls, plugins):
    """Per-game compatibility rules (recomp/profiles/*.json) for code that cannot run on iOS."""
    applied = []
    for name in sorted(os.listdir(PROFILES)):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(PROFILES, name)) as f:
            profile = json.load(f)
        if profile.get("when_assembly") not in game_dlls:  # Unreal profiles have none
            continue
        for dll, methods in profile.get("guard", {}).items():
            cmd = [ASMTOOL, "guard", "--search", game.managed]
            for m in methods:
                cmd += ["--method", m]
            run(cmd + [os.path.join(plugins, dll)])
        for dll, methods in profile.get("returns", {}).items():
            cmd = [ASMTOOL, "returns", "--search", game.managed]
            for m, value in methods.items():
                cmd += ["--method", m, "--value", str(value).lower() if isinstance(value, bool) else str(value)]
            run(cmd + [os.path.join(plugins, dll)])
        log(f"profile {profile['name']}: {profile['why']}")
        applied.append(profile["name"])
    return applied


def active_shims(game):
    return [spec for spec in SHIM_SPECS
            if spec["requires"] is None or os.path.exists(os.path.join(game.managed, spec["requires"]))]


def build_shims(game, out):
    built = []
    for spec in active_shims(game):
        dotnet_build(os.path.join(SHIMS, spec["project"]), out, f"-p:GameManaged={game.managed}")
        built.append(os.path.join(out, spec["assembly"] + ".dll"))
    return built


def register_mods(data, assemblies):
    """List the compiled-in mod assemblies with the game's, so the player can resolve their
    script types (e.g. a MonoBehaviour in a mod's asset bundle)."""
    if not assemblies:
        return
    sa_path = os.path.join(data, "ScriptingAssemblies.json")
    with open(sa_path) as f:
        sa = json.load(f)
    for name in sorted(assemblies):
        if name + ".dll" not in sa["names"]:
            sa["names"].append(name + ".dll")
            sa["types"].append(16)  # user assembly
    with open(sa_path, "w") as f:
        json.dump(sa, f)


def register_shims(game, data):
    """Add the shims to the game's assembly list and startup hooks."""
    shims = active_shims(game)
    if not shims:
        return
    sa_path = os.path.join(data, "ScriptingAssemblies.json")
    with open(sa_path) as f:
        sa = json.load(f)
    rt_path = os.path.join(data, "RuntimeInitializeOnLoads.json")
    with open(rt_path) as f:
        rt = json.load(f)
    for spec in shims:
        dll = spec["assembly"] + ".dll"
        if dll not in sa["names"]:
            sa["names"].append(dll)
            sa["types"].append(16)  # user assembly
        for init in spec["init"]:
            entry = dict(init, assemblyName=spec["assembly"], isUnityClass=False)
            if entry not in rt["root"]:
                rt["root"].append(entry)
    with open(sa_path, "w") as f:
        json.dump(sa, f)
    with open(rt_path, "w") as f:
        json.dump(rt, f)
    log(f"registered shims: {', '.join(s['assembly'] for s in shims)}")


def player(game, work, unity, bundle_id, team):
    shell = os.path.join(work, "shell")
    out = os.path.join(work, "xcode")
    logfile = os.path.join(work, "unity-build.log")
    exe = os.path.join(unity, "Contents", "MacOS", "Unity")
    # -disable-assembly-updater: the API Updater otherwise scans every precompiled
    # game assembly for obsolete Unity APIs, which never finishes on large games
    # and is pointless since they were built against this exact Unity version.
    cmd = [exe, "-batchmode", "-nographics", "-quit", "-disable-assembly-updater",
           "-projectPath", shell, "-buildTarget", "iOS",
           "-executeMethod", "Recomp.Build.Run", "-logFile", logfile,
           "-recompOut", out, "-recompBundleId", bundle_id, "-recompTeam", team,
           "-recompProduct", game.name, "-recompVersion", game.info.get("CFBundleShortVersionString", "1.0").split("-")[0],
           "-recompPortrait", "1" if phone_settings(game_profile(game) or {})["portrait"] else "0"]
    log(f"Unity batchmode build (log: {logfile})")
    if os.path.exists(logfile):
        os.remove(logfile)
    # inject's snapshot of the shell data must match the code this build generates,
    # and Unity's iOS post-processor fails ("Directory not empty") on an output
    # folder that inject or an interrupted build left behind: start clean.
    shutil.rmtree(os.path.join(work, "shell-data"), ignore_errors=True)
    shutil.rmtree(out, ignore_errors=True)
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    follow_unity_log(logfile, proc)
    if proc.returncode != 0 or not os.path.isdir(out):
        tail = subprocess.run(["tail", "-60", logfile], capture_output=True, text=True).stdout
        sys.exit(f"Unity build failed ({proc.returncode}). Last log lines:\n{tail}")
    log(f"Xcode project: {out}")


# Unity's build system prints "[ done/total  time] step"; IL2CPP and the
# player build dominate the run, so their counter is the progress bar.
BEE_PROGRESS = re.compile(r"^\[\s*(\d+)/\s*(\d+)\s")


def follow_unity_log(logfile, proc):
    """Turn the Unity log into progress events until the editor exits."""
    pos, last_emit = 0, 0.0
    phase = "Starting Unity"
    phases = [("Requested script compilation", "Compiling scripts"), ("Building player", "Building player"),
              ("il2cpp", "Converting code with IL2CPP"), ("Xcode", "Writing Xcode project")]
    while True:
        done = proc.poll() is not None
        if os.path.exists(logfile):
            with open(logfile, errors="replace") as f:
                f.seek(pos)
                chunk = f.read()
                pos = f.tell()
            for line in chunk.splitlines():
                events.check_hints(line)
                for needle, name in phases:
                    if needle in line:
                        phase = name
                m = BEE_PROGRESS.match(line)
                now = time.time()
                if m and now - last_emit > 0.5:
                    a, b = int(m.group(1)), int(m.group(2))
                    events.progress(a / b if b else None, f"{phase}: step {a} of {b}")
                    last_emit = now
                elif now - last_emit > 2:
                    events.progress(None, phase)
                    last_emit = now
                if line.startswith(("Error", "error")) or ": error" in line:
                    events.emit("log", line=line)
        if done:
            return
        time.sleep(0.5)


def patch_target_platform(path, target):
    """Rewrite the BuildTarget field in a Unity SerializedFile header, in place.

    The header starts with four big-endian u32 (metadata size, file size, format
    version, data offset) and a u8 endianness flag plus 3 reserved bytes; format
    22+ then repeats the sizes as u32 + 3x u64. The metadata that follows begins
    with the NUL-terminated Unity version and the u32 target platform.
    """
    with open(path, "r+b") as f:
        head = f.read(64)
        if len(head) < 48:
            return False
        version = struct.unpack(">I", head[8:12])[0]
        if version < 9 or version > 30:
            return False
        endian = head[16]
        meta_start = 48 if version >= 22 else 20
        f.seek(meta_start)
        chunk = f.read(64)
        nul = chunk.find(b"\0")
        if nul <= 0 or not re.fullmatch(rb"\d+\.\d+\.\w+", chunk[:nul]):
            return False
        pos = meta_start + nul + 1
        fmt = ">I" if endian else "<I"
        f.seek(pos)
        current = struct.unpack(fmt, f.read(4))[0]
        if current == target:
            return True
        if current not in (TARGET_OSX, 5, 19, 24, 27):  # standalone targets only
            return False
        f.seek(pos)
        f.write(struct.pack(fmt, target))
        return True


def inject(game, work):
    xcode = os.path.join(work, "xcode")
    data = os.path.join(xcode, "Data")
    if not os.path.isdir(data):
        sys.exit(f"{data} missing - run the player stage first")
    shell_data = os.path.join(work, "shell-data")
    if not os.path.isdir(shell_data):
        shutil.copytree(data, shell_data)  # pristine copy of what Unity produced

    shutil.rmtree(data)
    os.makedirs(data)
    patched = 0
    for name in os.listdir(game.data):
        src = os.path.join(game.data, name)
        if name == "Managed":
            continue
        if name == "StreamingAssets":
            shutil.copytree(src, os.path.join(data, "Raw"))
            continue
        dst = os.path.join(data, name)
        if os.path.isdir(src):
            shutil.copytree(src, dst)
        else:
            shutil.copy2(src, dst)
    # Shell-owned pieces override the game's copies.
    for rel in KEEP_FROM_SHELL:
        src = os.path.join(shell_data, rel)
        if os.path.exists(src):
            dst = os.path.join(data, rel)
            if os.path.isdir(dst):
                shutil.rmtree(dst)
            elif os.path.exists(dst):
                os.remove(dst)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            (shutil.copytree if os.path.isdir(src) else shutil.copy2)(src, dst)
    # The shell's boot.config carries iOS player switches; keep the game's build guid.
    merge_boot_config(os.path.join(shell_data, "boot.config"), os.path.join(game.data, "boot.config"),
                      os.path.join(data, "boot.config"))
    register_shims(game, data)
    mod_asms = mod_assemblies(work)
    register_mods(data, mod_asms)
    write_shim_config(game, data)
    write_save_info(game, xcode)
    from recomp import steam_license
    steam_license.write_plist(game.app, game_profile(game), os.path.join(xcode, "Info.plist"), log)
    from recomp import il2cpp_patches, pyenv
    with open(os.path.join(game.data, "ScriptingAssemblies.json")) as f:
        listed = [n[:-4] if n.endswith(".dll") else n for n in json.load(f)["names"]]
    il2cpp_patches.apply(xcode, ["mscorlib"] + [n for n in listed if n != "mscorlib"], log, mod_asms)
    events.progress(None, "Converting textures to ASTC")
    run([pyenv.python(), "-I", os.path.join(ROOT, "recomp", "textures.py"), data,
         os.path.join(paths.HOME, "cache", "bundles", game.slug)])
    icns = game_icon(game)
    appiconset = os.path.join(xcode, "Unity-iPhone", "Images.xcassets", "AppIcon.appiconset")
    if icns and os.path.isdir(appiconset):
        run([pyenv.python(), "-I", os.path.join(ROOT, "recomp", "appicon.py"), icns, appiconset])
    for dirpath, _, files in os.walk(data):
        for n in files:
            p = os.path.join(dirpath, n)
            if n.endswith((".resS", ".resource", ".json", ".config", ".dat")) or "Raw" in p.split(os.sep):
                continue
            if patch_target_platform(p, TARGET_IOS):
                patched += 1
    log(f"game data injected into {data} ({patched} serialized files retargeted to iOS)")


def game_icon(game):
    """The game's own .icns, as named by its Info.plist."""
    name = game.info.get("CFBundleIconFile")
    if not name:
        return None
    path = os.path.join(game.app, "Contents", "Resources", name)
    if not path.endswith(".icns"):
        path += ".icns"
    return path if os.path.exists(path) else None


def merge_boot_config(shell_cfg, game_cfg, out):
    def read(p):
        d = {}
        if os.path.exists(p):
            for line in open(p):
                if "=" in line:
                    k, v = line.rstrip("\n").split("=", 1)
                    d[k] = v
        return d
    merged = read(shell_cfg)
    g = read(game_cfg)
    if "build-guid" in g:
        merged["build-guid"] = g["build-guid"]
    with open(out, "w") as f:
        for k, v in merged.items():
            f.write(f"{k}={v}\n")


def xcode(work, team):
    proj = os.path.join(work, "xcode", "Unity-iPhone.xcodeproj")
    derived = os.path.join(work, "DerivedData")
    sources = sum(1 for _, _, files in os.walk(os.path.join(work, "xcode"))
                  for n in files if n.endswith((".cpp", ".c", ".m", ".mm")))
    compiled = [0]
    tail = []

    def on_line(line):
        events.check_hints(line)
        tail.append(line)
        del tail[:-40]
        if line.startswith("CompileC "):
            compiled[0] += 1
            if compiled[0] % 20 == 0:
                events.progress(min(compiled[0] / max(sources, 1), 0.99), f"Compiling: {compiled[0]} of ~{sources} files")
        elif line.startswith(("Ld ", "CodeSign ")):
            events.progress(None, line.split(" ")[0].replace("Ld", "Linking").replace("CodeSign", "Signing"))
        elif " error: " in line:
            events.emit("log", line=line)

    try:
        stream(["xcodebuild", "-project", proj, "-scheme", "Unity-iPhone", "-configuration", "Release",
                "-destination", "generic/platform=iOS", "-derivedDataPath", derived,
                "-allowProvisioningUpdates", f"DEVELOPMENT_TEAM={team}", "CODE_SIGN_STYLE=Automatic",
                "build"], on_line)
    except subprocess.CalledProcessError:
        sys.exit("xcodebuild failed. Last lines:\n" + "\n".join(tail))
    products = os.path.join(derived, "Build", "Products", "Release-iphoneos")
    apps = [n for n in os.listdir(products) if n.endswith(".app")]
    log(f"built: {', '.join(os.path.join(products, a) for a in apps)}")


def install(work, device):
    products = os.path.join(work, "DerivedData", "Build", "Products", "Release-iphoneos")
    apps = [n for n in os.listdir(products) if n.endswith(".app")]
    if not apps:
        sys.exit("no built .app - run the xcode stage first")
    def on_line(line):
        events.check_hints(line)
        print(line, flush=True)
    app = os.path.join(products, apps[0])
    storage.check_install(device, app)
    stream(["xcrun", "devicectl", "device", "install", "app", "--device", device, app], on_line)
