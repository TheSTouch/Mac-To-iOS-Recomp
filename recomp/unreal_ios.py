"""Port a native arm64 Unreal Engine 4 Mac game to iOS (iPhone and iPad) by retargeting its binaries.

The game's machine code already runs on an Apple Silicon iPhone or iPad; what
changes is around it:

  prepare   retarget every Mach-O in the bundle to iOS (macho.py), binding
            imports iOS lacks to shims built from recomp/native: AppKit on
            UIKit (RecompAppKit.dylib) and a Steam stand-in
  xcode     generate a small Xcode project and build it: the run-script phase
            puts the retargeted game into the app, then Xcode signs it with
            automatic provisioning; the profile's "saves" block goes into
            Info.plist for the iCloud Drive save sync (recomp/native/RecompSaves.m,
            built into the AppKit shim)
  install   install it on a connected device

The Mac bundle's Contents/ folder goes into the app as MacFiles/ (codesign
would read a Contents/ folder as a Mac bundle layout); the engine's two
"Contents/UE4/" path strings are patched to match, same length.
"""
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys

from recomp import events, iossdk, macho, paths, steam_license, storage, xcodeproj

ROOT = paths.CODE
NATIVE_SRC = os.path.join(ROOT, "recomp", "native")
PROFILES = os.path.join(ROOT, "recomp", "profiles")
DATA = "MacFiles"  # must stay 8 letters: it replaces "Contents" inside the binary
MIN_IOS = "17.0"

# AppKit classes the shim implements as RNS<name>, exported under the AppKit name.
SHIM_CLASSES = ["NSResponder", "NSApplication", "NSWindow", "NSView", "NSEvent", "NSScreen", "NSCursor", "NSImage",
                "NSBitmapImageRep", "NSColor", "NSFont", "NSMenu", "NSMenuItem", "NSPasteboard", "NSPasteboardItem",
                "NSAlert", "NSWorkspace", "NSScrollView", "NSTextView", "NSAccessibilityElement", "NSAppleEventManager"]
# AppKit constants whose values UIKit also defines; the shim exports them as Recomp<name>.
SHIM_ALIASED_CONSTANTS = ["NSFontAttributeName", "NSForegroundColorAttributeName", "NSBackgroundColorAttributeName",
                          "NSParagraphStyleAttributeName", "NSStrokeColorAttributeName", "NSStrokeWidthAttributeName",
                          "NSUnderlineStyleAttributeName", "NSGlyphInfoAttributeName",
                          "NSMarkedClauseSegmentAttributeName", "NSDocumentTypeDocumentAttribute",
                          "NSPlainTextDocumentType"]
SHIM_FRAMEWORKS = ["UIKit", "Foundation", "QuartzCore", "CoreGraphics", "Metal", "GameController", "AVFAudio",
                   "AudioToolbox", "Security"]
# Imports bound to the shim even though iOS exports them, for every UE4 game.
INTERCEPT = {
    # The engine refuses to start on a case-sensitive volume; iOS volumes are. The
    # shim's value is a key NSURL does not know, so the check reads "no".
    "_NSURLVolumeSupportsCaseSensitiveNamesKey",
    # GPU and machine identity from the IOKit registry, which the iOS sandbox
    # hides: the shim answers for the GPU entries and passes the rest through.
    "_IOServiceGetMatchingServices", "_IOServiceGetMatchingService", "_IOIteratorNext", "_IOObjectRelease",
    "_IORegistryEntryCreateCFProperties", "_IORegistryEntryCreateCFProperty", "_IORegistryEntrySearchCFProperty",
    "_IORegistryEntryGetChildIterator", "_IORegistryEntryGetRegistryEntryID",
    # Log a backtrace when the game exits with an error (shipping builds keep no log).
    "_exit", "__Exit", "_abort",
    # ... and who asked for a clean quit: FMacPlatformMisc::RequestExit calls it (RecompDebug.m).
    "_notify_cancel",
    # Case-insensitive path lookups, as on a Mac's default volume (RecompFiles.c).
    "_open", "_fopen", "_stat", "_statfs", "_access", "_opendir", "_chdir", "_readlink", "_chmod", "_utime",
    "_unlink", "_rmdir", "_mkdir", "_rename", "_dlopen",
    # Audio: one output device instead of the HAL, iOS units for macOS ones (RecompAudio.m).
    "_AudioObjectGetPropertyData", "_AudioObjectGetPropertyDataSize", "_AudioObjectHasProperty",
    "_AudioObjectSetPropertyData", "_AudioObjectAddPropertyListener", "_AudioObjectRemovePropertyListener",
    "_AudioComponentFindNext", "_AUGraphAddNode", "_AudioUnitSetProperty", "_AUGraphInitialize", "_AUGraphStart",
}
# Settings every Unreal game gets on an iPhone, under the profile's "iphone"
# block (same shape as its engine_ini / game_user_settings_ini): a phone has a
# smaller power and heat budget than an M-series iPad, and on its small screen
# medium quality (1; 0 is low, 3 epic) looks close to epic. ApplicationScale
# "auto" keeps menus whole on a short screen (see RecompConfig.m).
PHONE_DEFAULTS = {
    "engine_ini": {
        "/Script/Engine.UserInterfaceSettings": {"ApplicationScale": "auto"},
    },
    "game_user_settings_ini": {
        "ScalabilityGroups": {
            "sg.ResolutionQuality": "70", "sg.ViewDistanceQuality": "1", "sg.EffectsQuality": "1",
            "sg.TextureQuality": "1", "sg.ShadowQuality": "1", "sg.PostProcessQuality": "1",
            "sg.FoliageQuality": "1", "sg.ShadingQuality": "1",
        },
    },
}
SHIM_NAME = "RecompAppKit.dylib"
SHIM_INSTALL = "@executable_path/Frameworks/" + SHIM_NAME


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


class Game:
    def __init__(self, app):
        self.app = os.path.abspath(app.rstrip("/"))
        self.contents = os.path.join(self.app, "Contents")
        with open(os.path.join(self.contents, "Info.plist"), "rb") as f:
            self.info = plistlib.load(f)
        self.executable = self.info["CFBundleExecutable"]
        self.name = os.path.basename(self.app)[:-len(".app")]
        self.slug = re.sub(r"[^A-Za-z0-9]", "", self.name) or "Game"
        ue = os.path.join(self.contents, "UE4")
        if not os.path.isdir(ue):
            sys.exit(f"{self.app}: no Contents/UE4 folder; this route handles Unreal Engine 4 Mac builds")
        self.projects = [d for d in os.listdir(ue) if d != "Engine" and os.path.isdir(os.path.join(ue, d))]
        self.profile = load_profile(self)

    def binaries(self):
        """Relative paths (under Contents) of every Mach-O, main executable first."""
        main = os.path.join("MacOS", self.executable)
        out = [main]
        for root, _dirs, files in os.walk(self.contents):
            for n in files:
                rel = os.path.relpath(os.path.join(root, n), self.contents)
                if rel != main and not rel.startswith("_CodeSignature") and is_macho(os.path.join(root, n)):
                    out.append(rel)
        return out


def load_profile(game):
    """The first recomp/profiles/*.json whose "unreal_project" matches one of the game's UE4 projects."""
    for n in sorted(os.listdir(PROFILES)):
        if n.endswith(".json"):
            with open(os.path.join(PROFILES, n)) as f:
                p = json.load(f)
            if p.get("unreal_project") in game.projects:
                log(f"profile {n}: {p.get('why', '')}")
                return p
    return {}


# --- shims ---------------------------------------------------------------------------

def clang(args, out):
    sdk = iossdk.sdk_path()
    try:
        run(["xcrun", "-sdk", "iphoneos", "clang", "-arch", "arm64", f"-mios-version-min={MIN_IOS}", "-isysroot", sdk,
             "-O2", "-g", *args, "-o", out])
    except subprocess.CalledProcessError:
        sys.exit(f"building {os.path.basename(out)} failed (compiler errors above)")


def build_shims(work):
    out = os.path.join(work, "shims")
    os.makedirs(out, exist_ok=True)
    src = os.path.join(NATIVE_SRC, "appkit")
    sources = sorted(os.path.join(src, n) for n in os.listdir(src) if n.endswith((".m", ".c")))
    sources.append(os.path.join(NATIVE_SRC, "RecompSaves.m"))  # shared with the Unity route
    sources.append(os.path.join(NATIVE_SRC, "RecompLicense.m"))  # likewise
    # The Steam runtime the license check signs in with (recomp/native/RecompSteam).
    runtime = os.path.join(NATIVE_SRC, "RecompSteam")
    sources += sorted(os.path.join(runtime, n) for n in os.listdir(runtime) if n.endswith((".c", ".m", ".mm")))
    aliases = []
    for c in SHIM_CLASSES:
        for kind in ("CLASS", "METACLASS"):
            aliases += ["-Wl,-alias", f"-Wl,_OBJC_{kind}_$_R{c}", f"-Wl,_OBJC_{kind}_$_{c}"]
    for k in SHIM_ALIASED_CONSTANTS:
        aliases += ["-Wl,-alias", f"-Wl,_Recomp{k}", f"-Wl,_{k}"]
    fw = [x for f in SHIM_FRAMEWORKS for x in ("-framework", f)]
    shim = os.path.join(out, SHIM_NAME)
    clang(["-dynamiclib", "-fobjc-arc", "-fmodules", "-Wno-unused-parameter", "-I", runtime, "-lc++", "-install_name", SHIM_INSTALL,
           "-current_version", "1.0", "-compatibility_version", "1.0", *aliases, *fw, *sources], shim)
    steam = os.path.join(out, "libsteam_api.dylib")
    clang(["-dynamiclib", "-install_name", "@rpath/libsteam_api.dylib", "-current_version", "1.0",
           "-compatibility_version", "1.0", os.path.join(NATIVE_SRC, "steam_api_stub.c")], steam)
    return shim, steam


def exported(path):
    r = subprocess.run(["nm", "-gUj", path], capture_output=True, text=True, check=True)
    return set(r.stdout.split())


# --- retargeting ---------------------------------------------------------------------

def _is_system(path):
    return path.startswith(("/System/", "/usr/lib/"))


def relink_main(m, idx, shim_syms, intercept):
    """Rebuild the main executable's library list for iOS and rebind every import.

    Mac-only libraries (AppKit, Carbon, ...) are dropped; their symbols, and
    symbols an iOS library lacks or the profile intercepts, bind to the shim
    or, failing that, to whichever iOS library exports them.
    """
    old = m.dylibs()
    new, ordinal = [], {}

    def add(cmd, path):
        if path not in ordinal:
            new.append((cmd, path))
            ordinal[path] = len(new)
        return ordinal[path]

    old_target = {}
    for i, (cmd, path) in enumerate(old, 1):
        if _is_system(path):
            ios = iossdk.framework_path(idx, path)
            old_target[i] = add(cmd, ios) if ios else None
        else:
            path = re.sub(r"^@(loader|executable)_path/", f"@executable_path/{DATA}/MacOS/", path)
            old_target[i] = add(cmd, path)
    shim = add(macho.LC_LOAD_DYLIB, SHIM_INSTALL)
    unresolved, moved = [], {}

    def rebind(name, lib, weak):
        cmd, path = old[lib - 1]
        target = old_target.get(lib)
        if not _is_system(path):
            return target
        ios = new[target - 1][1] if target else None
        if target and name not in intercept and name in idx.get(ios, ()):
            return target
        if name in shim_syms:
            moved[name] = SHIM_NAME
            return shim
        for lib_path, syms in idx.items():
            if name in syms:
                moved[name] = lib_path
                return add(macho.LC_LOAD_DYLIB, lib_path)
        if not weak:
            unresolved.append(f"{name} (from {path})")
        return target or shim

    m.remap_imports(rebind)
    return new, moved, sorted(unresolved)


def retarget_binary(src, dst, rel, game, idx, shim_syms, sdk):
    m = macho.MachO(src)
    if m.platform() != macho.PLATFORM_MACOS:
        log(f"{rel}: not a macOS binary, copied as is")
        shutil.copy2(src, dst)
        return
    main = rel == os.path.join("MacOS", game.executable)
    if main:
        dylibs, moved, unresolved = relink_main(m, idx, shim_syms, INTERCEPT | set(game.profile.get("intercept", [])))
        if unresolved:
            sys.exit("symbols with no iOS equivalent and no shim:\n  " + "\n  ".join(unresolved))
        rpaths = ["@executable_path/Frameworks"]
        for p in m.rpaths():
            p = re.sub(r"^@(loader|executable)_path/", f"@executable_path/{DATA}/MacOS/", p)
            if p not in rpaths:  # dyld refuses duplicates
                rpaths.append(p)
        m.retarget(MIN_IOS, sdk, dylibs=dylibs, rpaths=rpaths)
        found = m.data.count(b"Contents/UE4/")
        if found:
            m.patch_bytes(b"Contents/UE4/", (DATA + "/UE4/").encode(), count=found)
        for p in game.profile.get("patches", []):
            m.patch_bytes(bytes.fromhex(p["find"]), bytes.fromhex(p["replace"]), count=p.get("count", 1))
        by_lib = {}
        for name, lib in moved.items():
            by_lib.setdefault(os.path.basename(lib), []).append(name)
        log(f"{rel}: {len(dylibs)} libraries; rebound " +
            ", ".join(f"{len(v)} to {k}" for k, v in sorted(by_lib.items())))
    else:
        # Older-format dylibs (dyld info, not chained fixups): same libraries, same order.
        dylibs = []
        for cmd, path in m.dylibs():
            if _is_system(path):
                ios = iossdk.framework_path(idx, path)
                if not ios:
                    sys.exit(f"{rel}: links {path}, which iOS does not have")
                path = ios
            dylibs.append((cmd, path))
        missing = undefined_missing(src, idx)
        if missing:
            sys.exit(f"{rel}: imports iOS lacks: {', '.join(missing[:20])}")
        m.retarget(MIN_IOS, sdk, dylibs=dylibs)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    m.save(dst)
    os.chmod(dst, 0o755)


def undefined_missing(path, idx):
    """Non-weak imports from the system libraries (any fixup format) that iOS does not export."""
    r = subprocess.run(["nm", "-um", path], capture_output=True, text=True, check=True)
    every = set().union(*idx.values())
    out = []
    for line in r.stdout.splitlines():
        mm = re.match(r"\s*\(undefined\)\s*(weak )?external (\S+) \(from ([^)]+)\)", line)
        if mm and mm.group(3) in ("libSystem", "libc++", "libobjc") and not mm.group(1) and mm.group(2) not in every:
            out.append(mm.group(2))
    return out


def blockers(game, idx, shim_syms):
    """What would stop prepare, found without writing anything: one line per problem."""
    out = []
    main = os.path.join("MacOS", game.executable)
    for rel in game.binaries():
        if os.path.basename(rel) == "libsteam_api.dylib":
            continue
        src = os.path.join(game.contents, rel)
        try:
            m = macho.MachO(src)
        except ValueError as e:
            out.append(f"{rel}: {str(e).replace(src + ': ', '')}.")
            continue
        if m.platform() != macho.PLATFORM_MACOS:
            continue
        if rel == main:
            unresolved = relink_main(m, idx, shim_syms, INTERCEPT | set(game.profile.get("intercept", [])))[2]
            unresolved = [re.sub(r" \(from .*/([^/]+)\)$", r" (\1)", x) for x in unresolved]
            if unresolved:
                shown = ", ".join(unresolved[:12]) + (f" and {len(unresolved) - 12} more" if len(unresolved) > 12 else "")
                out.append(f"{rel}: {len(unresolved)} imports with no iOS equivalent and no shim (recomp/native/appkit): "
                           f"{shown}.")
            continue
        for _cmd, path in m.dylibs():
            if _is_system(path) and not iossdk.framework_path(idx, path):
                out.append(f"{rel}: links {path}, which iOS does not have.")
        missing = undefined_missing(src, idx)
        if missing:
            out.append(f"{rel}: imports iOS lacks: {', '.join(missing[:12])}.")
    return out


def prepare(game, work):
    shim, steam = build_shims(work)
    shim_syms = exported(shim)
    idx = iossdk.index(os.path.join(paths.HOME, "cache"))
    sdk = iossdk.sdk_version()
    bin_dir = os.path.join(work, "bin")
    shutil.rmtree(bin_dir, ignore_errors=True)
    replaced = []
    bins = game.binaries()
    for i, rel in enumerate(bins):
        events.progress(i / len(bins), f"Retargeting {os.path.basename(rel)}")
        src = os.path.join(game.contents, rel)
        dst = os.path.join(bin_dir, rel)
        if os.path.basename(rel) == "libsteam_api.dylib":
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(steam, dst)
            log(f"{rel}: replaced by the Steam stand-in")
        else:
            retarget_binary(src, dst, rel, game, idx, shim_syms, sdk)
        replaced.append(rel)
    with open(os.path.join(work, "manifest.json"), "w") as f:
        json.dump({"app": game.app, "executable": game.executable, "binaries": replaced, "shim": shim}, f, indent=2)
    log(f"retargeted {len(replaced)} binaries into {bin_dir}")


# --- Xcode project ---------------------------------------------------------------------

BUNDLE_SCRIPT = r'''set -e
APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
WORK="{work}"
GAME="{contents}"
# The game's own executable replaces the placeholder Xcode linked (copied
# aside first so nothing ever sees a half-written file).
cp "$WORK/bin/MacOS/{exe}" "$APP/$EXECUTABLE_NAME.tmp"
mv -f "$APP/$EXECUTABLE_NAME.tmp" "$APP/$EXECUTABLE_NAME"
mkdir -p "$APP/Frameworks"
cp "$WORK/shims/{shim}" "$APP/Frameworks/"
# Game data: APFS clones of the Mac bundle's Contents (instant on the same disk).
rm -rf "$APP/{data}"
mkdir -p "$APP/{data}"
for item in "$GAME"/*; do
  case "$(basename "$item")" in _CodeSignature|CodeResources|Info.plist|PkgInfo) continue ;; esac
  cp -Rc "$item" "$APP/{data}/"
done
rm -f "$APP/{data}/MacOS/{exe}"
cd "$WORK/bin"
find . -type f ! -path "./MacOS/{exe}" | while read -r f; do
  cp "$f" "$APP/{data}/$f"
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$APP/{data}/$f"
done
/usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$APP/Frameworks/{shim}"
'''

PLACEHOLDER_MAIN = "// Replaced by the game's executable before signing (see the Bundle game phase).\nint main(void) { return 0; }\n"


def overlay(base, over):
    """{file: {section: {key: value}}} with over's keys laid on base's, section by section."""
    out = {f: {sec: dict(keys) for sec, keys in sections.items()} for f, sections in base.items()}
    for f, sections in over.items():
        for sec, keys in sections.items():
            out.setdefault(f, {}).setdefault(sec, {}).update(keys)
    return out


def ini_overrides(block):
    """A profile block's settings as the shim reads them (RecompConfig.m): by user config file name."""
    return {"Engine": block.get("engine_ini", {}), "GameUserSettings": block.get("game_user_settings_ini", {})}


def info_plist(game):
    info = game.info
    plist = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": game.name,
        "CFBundleDisplayName": game.name,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": str(info.get("CFBundleShortVersionString", "1.0")),
        "CFBundleVersion": str(info.get("CFBundleVersion", "1")),
        "LSRequiresIPhoneOS": True,
        "UIRequiresFullScreen": True,
        "UIStatusBarHidden": True,
        "UIViewControllerBasedStatusBarAppearance": True,
        "UILaunchScreen": {"UIColorName": "", "UIImageRespectsSafeAreaInsets": False},
        "UISupportedInterfaceOrientations": ["UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
        "UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
        "UIDeviceFamily": [1, 2],
        "UIApplicationSupportsIndirectInputEvents": True,
        "UIFileSharingEnabled": True,
        "LSSupportsOpeningDocumentsInPlace": True,
        "GCSupportsControllerUserInteraction": True,
        "GCSupportedGameControllers": [{"ProfileName": "ExtendedGamepad"}],
        "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True},
        "ITSAppUsesNonExemptEncryption": False,
        # Read by the shim (RecompConfig.m): settings merged into the engine's user
        # config files at each launch, from the game's profile; on an iPhone, the
        # phone set is laid over them.
        "RecompConfigDir": f"Library/Preferences/{game.name}/MacNoEditor",
        "RecompIniOverrides": ini_overrides(game.profile),
        "RecompIniOverridesPhone": overlay(ini_overrides(PHONE_DEFAULTS), ini_overrides(game.profile.get("iphone", {}))),
        # Read by RecompSaves.m: the game's name names its folder in iCloud Drive.
        "RecompGame": game.name,
    }
    # The port's save sync, from --saves (recomp.py sets game.saves_mode) or the game's default.
    from recomp import steam_cloud
    plist.update(steam_cloud.plist_keys(game.app, game.profile, getattr(game, "saves_mode", None), "ios", log))
    # Read by RecompLicense.m: the Steam app the player's account must own.
    plist.update(steam_license.plist_keys(game.app, game.profile, log))
    return plist


ENTITLEMENTS = {
    "com.apple.developer.kernel.increased-memory-limit": True,
    "com.apple.developer.kernel.extended-virtual-addressing": True,
}


def game_icon(game):
    name = game.info.get("CFBundleIconFile")
    if not name:
        return None
    path = os.path.join(game.contents, "Resources", name if name.endswith(".icns") else name + ".icns")
    return path if os.path.exists(path) else None


def xcode(game, work, team, bundle_id):
    with open(os.path.join(work, "manifest.json")) as f:
        manifest = json.load(f)
    proj = os.path.join(work, "xcode")
    os.makedirs(proj, exist_ok=True)
    with open(os.path.join(proj, "main.c"), "w") as f:
        f.write(PLACEHOLDER_MAIN)
    with open(os.path.join(proj, "Info.plist"), "wb") as f:
        plistlib.dump(info_plist(game), f)
    with open(os.path.join(proj, "App.entitlements"), "wb") as f:
        plistlib.dump(ENTITLEMENTS, f)
    resources = []
    icns = game_icon(game)
    if icns:
        from recomp import pyenv
        iconset = os.path.join(proj, "Assets.xcassets", "AppIcon.appiconset")
        os.makedirs(iconset, exist_ok=True)
        with open(os.path.join(proj, "Assets.xcassets", "Contents.json"), "w") as f:
            json.dump({"info": {"author": "xcode", "version": 1}}, f)
        run([pyenv.python(), os.path.join(ROOT, "recomp", "appicon.py"), icns, iconset])
        resources.append("Assets.xcassets")
    script = BUNDLE_SCRIPT.format(work=work, contents=game.contents, exe=manifest["executable"], data=DATA,
                                  shim=SHIM_NAME)
    settings = {
        "INFOPLIST_FILE": "Info.plist", "CODE_SIGN_ENTITLEMENTS": "App.entitlements",
        "PRODUCT_BUNDLE_IDENTIFIER": bundle_id, "DEVELOPMENT_TEAM": team, "PRODUCT_NAME": game.slug,
        "IPHONEOS_DEPLOYMENT_TARGET": MIN_IOS, "TARGETED_DEVICE_FAMILY": "1,2", "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon" if icns else "", "ENABLE_BITCODE": "NO",
        "DEAD_CODE_STRIPPING": "NO", "STRIP_INSTALLED_PRODUCT": "NO", "COPY_PHASE_STRIP": "NO",
        # No dSYM: dsymutil would read the placeholder while the script replaces it.
        "DEBUG_INFORMATION_FORMAT": "dwarf",
    }
    xcodeproj.write(proj, game.slug, ["main.c"], settings, script=script, resources=resources)
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

    try:
        stream(["xcodebuild", "-project", os.path.join(proj, game.slug + ".xcodeproj"), "-scheme", game.slug,
                "-configuration", "Release", "-destination", "generic/platform=iOS", "-derivedDataPath", derived,
                "-allowProvisioningUpdates", "build"], on_line)
    except subprocess.CalledProcessError:
        sys.exit("xcodebuild failed. Last lines:\n" + "\n".join(tail))
    log(f"built {built_app(work)}")


def built_app(work):
    products = os.path.join(work, "DerivedData", "Build", "Products", "Release-iphoneos")
    apps = [n for n in os.listdir(products) if n.endswith(".app")] if os.path.isdir(products) else []
    if not apps:
        sys.exit("no built .app - run the xcode stage first")
    return os.path.join(products, apps[0])


def install(work, device):
    def on_line(line):
        events.check_hints(line)
        print(line, flush=True)
    app = built_app(work)
    storage.check_install(device, app)
    stream(["xcrun", "devicectl", "device", "install", "app", "--device", device, app], on_line)
