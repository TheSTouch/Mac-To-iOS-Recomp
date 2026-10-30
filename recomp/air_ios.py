"""Port an Adobe AIR Mac game (captive runtime: Brawlhalla) to iOS with the AIR SDK.

An AIR game is ActionScript bytecode in SWF files plus native extensions (ANEs);
only the extensions are machine code, and the Mac ones are Intel frameworks. So
the game's own files go into an iOS AIR app as they are, with iOS stand-ins for
its extensions:

  prepare   build each extension's stand-in (recomp/native/air/<id>.c) into an
            iOS .ane (ADT wants a universal armv7 + arm64 static library), and
            write the app descriptor for iOS from the game's own
  package   package the app with ADT: --interpreter for ipa-test-interpreter
            (about a minute and a half), else ipa-test, which compiles the
            ActionScript ahead of time (much faster in game, an hour or more to build)
  xcode     generate a small Xcode project and build it: the run-script phase
            puts ADT's app into it, then Xcode signs it with automatic provisioning,
            so the profile carries the memory entitlements a wildcard profile lacks
  install   install it on a connected device

ADT needs a provisioning profile to package even though the xcode stage signs
again: the bundle's own profile once the xcode stage has made one, else the
team's wildcard profile (which Xcode makes for any project with automatic signing).

SteamAir runs on the port's Steam runtime (recomp/native/RecompSteam), with the Steam sign-in
cover, as the other routes do; its keys go into the descriptor's InfoAdditions.

The AIR SDK (toolchain/air-sdk/AIRSDK_<version>) only downloads after accepting
its license, so it is not fetched here; a JDK (toolchain/jdk-17) runs ADT.
"""
import datetime
import glob
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile

from recomp import events, paths, steam_runtime, storage, xcodeproj

ROOT = paths.CODE
NATIVE_SRC = os.path.join(ROOT, "recomp", "native", "air")
AIR_NS = "http://ns.adobe.com/air/application/51.5"
ANE_NS = "http://ns.adobe.com/air/extension/51.5"
# What ADT builds the extensions' slices for: armv7 only to pass its universal-binary check.
ARCHS = [("armv7", "9.0"), ("arm64", "13.0")]
RECOMP_NATIVE = os.path.join(ROOT, "recomp", "native")
# Extensions whose stand-in runs on code shared with the other routes: built with it into one
# object of the arm64 slice (constructors included), with what it links. The armv7 slice stays
# empty: nothing runs it, ADT only wants the architecture there.
RUNTIMES = {
    "SteamAir": {
        "sources": lambda: steam_runtime.sources() +
                           [os.path.join(RECOMP_NATIVE, n) for n in ("RecompLicense.m", "RecompSaves.m", "RecompLog.m")],
        "include": steam_runtime.INCLUDE,
        "defines": steam_runtime.DEFINES,
        "link": ["-framework Foundation", "-framework UIKit", "-framework Security", "-framework CoreImage", "-lz"],
    },
}
# Files of the Mac bundle's Resources that are not the game's content.
NOT_CONTENT = {"META-INF", "mimetype", "Icon.icns"}
PROFILE_DIRS = [os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles"),
                os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles")]

SDK_HELP = ("The AIR SDK is not installed. Get it with HARMAN's AIR SDK Manager (airsdk.harman.com): accept "
            "the license, download AIR SDK 51.5 or newer, and put its AIRSDK_<version> folder in {dir} "
            "(so that {dir}/AIRSDK_<version>/bin/adt exists). It is not downloaded for you: only the SDK "
            "Manager can, after you accept its terms.")
JDK_HELP = ("No Java for the AIR SDK's packager (ADT). Download Eclipse Temurin 17 for macOS, aarch64, as a "
            ".tar.gz (adoptium.net/temurin/releases/?version=17&os=mac&arch=aarch64) and unpack it as {dir} "
            "(so that {dir}/Contents/Home/bin/java exists).")


def log(msg):
    print(f"[recomp] {msg}", flush=True)


def run(cmd, **kw):
    shown = cmd if len(cmd) < 24 else cmd[:8] + [f"... ({len(cmd) - 10} more)"] + cmd[-2:]
    log("$ " + " ".join(shown))
    return subprocess.run(cmd, check=True, **kw)


def stream(cmd, on_line, **kw):
    shown = cmd if len(cmd) < 24 else cmd[:8] + [f"... ({len(cmd) - 10} more)"] + cmd[-2:]
    log("$ " + " ".join(shown))
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1, **kw)
    for line in proc.stdout:
        on_line(line.rstrip("\n"))
    if proc.wait() != 0:
        raise subprocess.CalledProcessError(proc.returncode, cmd)


# --- toolchain --------------------------------------------------------------------------

def air_sdk():
    """The newest toolchain/air-sdk/AIRSDK_* with ADT in it; exits saying how to get one."""
    base = os.path.join(paths.TOOLCHAIN, "air-sdk")
    found = [d for d in glob.glob(os.path.join(base, "AIRSDK_*")) if os.path.exists(os.path.join(d, "bin", "adt"))]
    if not found:
        sys.exit(SDK_HELP.format(dir=base))
    return max(found, key=lambda d: [int(x) for x in re.findall(r"\d+", os.path.basename(d))])


def java_home():
    base = os.path.join(paths.TOOLCHAIN, "jdk-17")
    for home in (os.path.join(base, "Contents", "Home"), base):
        if os.path.exists(os.path.join(home, "bin", "java")):
            return home
    sys.exit(JDK_HELP.format(dir=base))


def adt_env(work):
    """ADT runs `java` by name; its temporary files go to the work folder, not the internal disk."""
    home = java_home()
    tmp = os.path.join(work, "tmp")
    os.makedirs(tmp, exist_ok=True)
    env = dict(os.environ, JAVA_HOME=home, PATH=os.path.join(home, "bin") + os.pathsep + os.environ.get("PATH", ""))
    env["_JAVA_OPTIONS"] = f"-Djava.io.tmpdir={tmp}"
    return env


def adt(sdk, args, work, on_line=None):
    tail = []

    def line(text):
        if text.startswith("Picked up _JAVA_OPTIONS"):
            return
        tail.append(text)
        del tail[:-40]
        (on_line or print)(text)

    try:
        stream([os.path.join(sdk, "bin", "adt"), *args], line, env=adt_env(work))
    except subprocess.CalledProcessError:
        sys.exit("ADT failed. Last lines:\n" + "\n".join(tail))


# --- the game ---------------------------------------------------------------------------

class Game:
    def __init__(self, app):
        self.app = os.path.abspath(app.rstrip("/"))
        self.contents = os.path.join(self.app, "Contents")
        self.resources = os.path.join(self.contents, "Resources")
        with open(os.path.join(self.contents, "Info.plist"), "rb") as f:
            self.info = plistlib.load(f)
        self.descriptor = os.path.join(self.resources, "META-INF", "AIR", "application.xml")
        if not os.path.exists(self.descriptor):
            sys.exit(f"{self.app}: no Contents/Resources/META-INF/AIR/application.xml; this route handles "
                     "Adobe AIR captive-runtime Mac apps")
        root = ET.parse(self.descriptor).getroot()
        ns = root.tag[1:].split("}")[0] if root.tag.startswith("{") else ""

        def text(path, default=""):
            el = root.find("/".join(f"{{{ns}}}{p}" for p in path.split("/")))
            return el.text.strip() if el is not None and el.text else default

        self.filename = text("filename") or self.info.get("CFBundleExecutable", "Game")
        self.name = text("name") or os.path.basename(self.app)[:-len(".app")]
        self.slug = re.sub(r"[^A-Za-z0-9]", "", os.path.basename(self.app)[:-len(".app")]) or "Game"
        self.version = text("versionNumber", "1.0")
        self.content = text("initialWindow/content")
        self.title = text("initialWindow/title", self.name)
        self.render_mode = text("initialWindow/renderMode", "direct")
        self.extensions = [e.text.strip() for e in root.iter(f"{{{ns}}}extensionID") if e.text]
        self.profile = {}

    def extension_dir(self, ext):
        folder = bundled_extensions(self.app).get(ext)
        if not folder:
            sys.exit(f"the descriptor names the extension {ext}, which is not in META-INF/AIR/extensions")
        return folder

    def content_items(self):
        """The top-level items of Resources that go into the iOS app."""
        return sorted(n for n in os.listdir(self.resources) if n not in NOT_CONTENT and not n.startswith("."))


def bundled_extensions(app):
    """{extension id: folder} for the extensions an AIR app ships (META-INF/AIR/extensions)."""
    base = os.path.join(app, "Contents", "Resources", "META-INF", "AIR", "extensions")
    out = {}
    for n in sorted(os.listdir(base)) if os.path.isdir(base) else []:
        xml = os.path.join(base, n, "META-INF", "ANE", "extension.xml")
        ext = n
        if os.path.exists(xml):
            el = next((e for e in ET.parse(xml).getroot().iter() if e.tag.split("}")[-1] == "id" and e.text), None)
            ext = el.text.strip() if el is not None else n
        out[ext] = os.path.join(base, n)
    return out


def stand_in(ext):
    """The iOS stand-in's source for an extension id, or None."""
    src = os.path.join(NATIVE_SRC, ext + ".c")
    return src if os.path.exists(src) else None


# --- prepare: extensions ---------------------------------------------------------------------

def entry_points(src):
    """(initializer, finalizer) the stand-in defines: the functions named ...ExtInitializer / ...ExtFinalizer."""
    text = open(src).read()
    init = re.search(r"^void\s+(\w*ExtInitializer)\s*\(", text, re.M)
    final = re.search(r"^void\s+(\w*ExtFinalizer)\s*\(", text, re.M)
    if not init or not final:
        sys.exit(f"{src}: defines no ...ExtInitializer and ...ExtFinalizer function")
    return init.group(1), final.group(1)


def compile_slice(sources, arch, min_ios, includes, out_dir, merge=False, defines=()):
    """A static library of sources for one architecture; merge: as one object (ld -r), so that
    every file is linked, also those only a constructor starts."""
    objs = []
    for src in sources:
        obj = os.path.join(out_dir, f"{os.path.splitext(os.path.basename(src))[0]}.{arch}.o")
        objc = ["-fobjc-arc", "-fmodules"] if src.endswith(".m") else []
        try:
            run(["xcrun", "--sdk", "iphoneos", "clang", "-arch", arch, f"-miphoneos-version-min={min_ios}", "-O2",
                 "-g", *defines, *[x for d in includes for x in ("-I", d)], *objc, "-c", src, "-o", obj])
        except subprocess.CalledProcessError:
            sys.exit(f"building {os.path.basename(src)} for {arch} failed (compiler errors above)")
        objs.append(obj)
    if merge and len(objs) > 1:
        merged = os.path.join(out_dir, f"merged.{arch}.o")
        run(["xcrun", "--sdk", "iphoneos", "ld", "-r", "-arch", arch, "-o", merged, *objs])
        objs = [merged]
    lib = os.path.join(out_dir, f"lib.{arch}.a")
    if os.path.exists(lib):
        os.remove(lib)
    run(["xcrun", "--sdk", "iphoneos", "libtool", "-static", "-o", lib, *objs])
    return lib


def build_ane(sdk, game, ext, work):
    src = stand_in(ext)
    folder = game.extension_dir(ext)
    out = os.path.join(work, "ane", ext)
    shutil.rmtree(out, ignore_errors=True)
    native = os.path.join(out, "ios")
    os.makedirs(native)
    includes = [os.path.join(sdk, "include")]
    runtime = RUNTIMES.get(ext)
    libs = []
    for arch, min_ios in ARCHS:
        if not runtime:
            libs.append(compile_slice([src], arch, min_ios, includes, out))
        elif arch == "arm64":
            libs.append(compile_slice([src] + runtime["sources"](), arch, min_ios, includes + runtime["include"],
                                      out, merge=True, defines=runtime["defines"]))
        else:
            empty = os.path.join(out, "empty.c")
            with open(empty, "w") as f:
                f.write("// The armv7 slice: ADT wants one, nothing runs it.\n")
            libs.append(compile_slice([empty], arch, min_ios, includes, out))
    lib = os.path.join(native, f"lib{ext}.a")
    run(["xcrun", "lipo", "-create", *libs, "-output", lib])
    shutil.copy2(os.path.join(folder, "library.swf"), native)
    init, final = entry_points(src)
    xml = os.path.join(out, "extension.xml")
    with open(xml, "w") as f:
        f.write(f'<extension xmlns="{ANE_NS}">\n  <id>{ext}</id>\n  <versionNumber>0.0.1</versionNumber>\n'
                '  <platforms>\n    <platform name="iPhone-ARM">\n      <applicationDeployment>\n'
                f'        <nativeLibrary>lib{ext}.a</nativeLibrary>\n        <initializer>{init}</initializer>\n'
                f'        <finalizer>{final}</finalizer>\n      </applicationDeployment>\n    </platform>\n'
                '  </platforms>\n</extension>\n')
    # The ActionScript side is the game's own: its catalog.xml and library.swf, as a .swc.
    swc = os.path.join(out, f"{ext}.swc")
    with zipfile.ZipFile(swc, "w", zipfile.ZIP_DEFLATED) as z:
        for n in ("catalog.xml", "library.swf"):
            z.write(os.path.join(folder, n), n)
    ane = os.path.join(work, "extensions", f"{ext}.ane")
    os.makedirs(os.path.dirname(ane), exist_ok=True)
    if os.path.exists(ane):
        os.remove(ane)
    options = []
    if runtime and runtime.get("link"):
        platform = os.path.join(out, "platform.xml")
        with open(platform, "w") as f:
            f.write(f'<platform xmlns="{ANE_NS}">\n  <linkerOptions>\n' +
                    "".join(f"    <option>{o}</option>\n" for o in runtime["link"]) +
                    "  </linkerOptions>\n</platform>\n")
        options = ["-platformoptions", platform]
    adt(sdk, ["-package", "-target", "ane", ane, xml, "-swc", swc, "-platform", "iPhone-ARM", *options,
              "-C", native, "."], work)
    log(f"{ext}.ane: {os.path.relpath(src, ROOT)} ({init})")
    return ane


# --- prepare: descriptor -----------------------------------------------------------------------

def plist_fragment(keys):
    """Info.plist keys as the <key>/<value> elements an AIR descriptor's InfoAdditions holds."""
    body = plistlib.dumps(keys, sort_keys=False).decode()
    body = body.split("<dict>", 1)[1].rsplit("</dict>", 1)[0]
    return "\n".join("      " + line.strip() for line in body.strip().splitlines())


# ADT rejects UIStatusBarHidden, UISupportedInterfaceOrientations and MinimumOSVersion here (error 105).
INFO_ADDITIONS = {
    "UIDeviceFamily": ["1", "2"],
    "UIRequiresFullScreen": True,
    "UIFileSharingEnabled": True,
    "LSSupportsOpeningDocumentsInPlace": True,
    "GCSupportsControllerUserInteraction": True,
    "GCSupportedGameControllers": [{"ProfileName": "ExtendedGamepad"}],
    "UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationLandscapeLeft",
                                              "UIInterfaceOrientationLandscapeRight"],
    "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True},
    "ITSAppUsesNonExemptEncryption": False,
}
ENTITLEMENTS = {
    "com.apple.developer.kernel.increased-memory-limit": True,
    "com.apple.developer.kernel.extended-virtual-addressing": True,
}


def ticket_files(binary):
    """The files whose SHA-256 SteamAir puts in its encrypted app ticket request, relative to the
    Mac bundle's Contents: a list in its library, each entry 1, a 16-bit big-endian length and the
    path XOR 0x1c, ending with 0."""
    with open(binary, "rb") as f:
        data = f.read()
    best = []
    for m in re.finditer(rb"\x01\x00", data):
        i, found = m.start(), []
        while data[i:i + 2] == b"\x01\x00" and i + 3 < len(data):
            n = data[i + 2]
            path = bytes(c ^ 0x1c for c in data[i + 3:i + 3 + n])
            if not n or not re.fullmatch(rb"[\x20-\x7e]+", path) or b"/" not in path:
                break
            found.append(path.decode())
            i += 3 + n
        if found and data[i:i + 1] == b"\x00" and len(found) > len(best):
            best = found
    return best


def ticket_data(game):
    """The data SteamAir's ticket request carries, computed from the Mac bundle (SteamAir.c), or None."""
    import hashlib
    folder = bundled_extensions(game.app).get("SteamAir")
    binaries = glob.glob(os.path.join(folder, "META-INF", "ANE", "*", "*.framework", "SteamAir")) if folder else []
    files = ticket_files(os.path.realpath(binaries[0])) if binaries else []
    if not files:
        log("SteamAir: no file list found in its Mac library; the ticket carries no game data")
        return None
    out = bytearray(b"em")
    for rel in files:
        path = os.path.join(game.contents, rel)
        digest = bytes(32)
        if os.path.isfile(path):
            with open(path, "rb") as f:
                digest = hashlib.sha256(f.read()).digest()
        else:
            log(f"SteamAir: {rel} is not in the Mac bundle (hashed as zeros, as on the Mac)")
        out += b"\x01" + digest
    out += b"\x00"
    log(f"SteamAir: the ticket carries the hashes of {len(files)} files of the Mac bundle")
    return bytes(out)


def info_additions(game):
    """INFO_ADDITIONS, plus what the Steam runtime reads (recomp/native/RecompSteam): the app id and
    game name for the license cover, the save sync, the SteamAir ticket's data."""
    from recomp import steam_cloud, steam_license
    keys = dict(INFO_ADDITIONS)
    if "SteamAir" in game.extensions:
        keys["RecompGame"] = game.name
        keys.update(steam_license.plist_keys(game.app, game.profile, log))
        keys.update(steam_cloud.plist_keys(game.app, game.profile, getattr(game, "saves_mode", None), "ios", log))
        data = ticket_data(game)
        if data:
            keys["RecompAirTicketData"] = data.hex()   # ADT's plist parser refuses <data>
    return keys


def make_icon(game, work):
    """The Mac icon in an asset catalog (Assets.car: AppIcon and the launch screen's air_splash)
    at the package's root, where ADT takes it instead of its own (the AIR logo); None without an icon."""
    icns = game_icon(game)
    base = os.path.join(work, "icon")
    shutil.rmtree(base, ignore_errors=True)
    if not icns:
        return None
    from recomp import pyenv
    catalog = os.path.join(base, "Assets.xcassets")
    os.makedirs(os.path.join(catalog, "AppIcon.appiconset"))
    with open(os.path.join(catalog, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f)
    run([pyenv.python(), os.path.join(ROOT, "recomp", "appicon.py"), icns, os.path.join(catalog, "AppIcon.appiconset")])
    # AIR's launch screen shows "air_splash" from the catalog, and without it AIR stops with
    # "application packaging error": the icon's art stands in for the AIR logo.
    splash = os.path.join(catalog, "air_splash.imageset")
    os.makedirs(splash)
    shutil.copy2(os.path.join(catalog, "AppIcon.appiconset", "AppIcon-1024.png"), os.path.join(splash, "air_splash.png"))
    with open(os.path.join(splash, "Contents.json"), "w") as f:
        json.dump({"images": [{"filename": "air_splash.png", "idiom": "universal"}],
                   "info": {"author": "xcode", "version": 1}}, f)
    out = os.path.join(base, "car")
    os.makedirs(out)
    run(["xcrun", "actool", "--compile", out, "--platform", "iphoneos", "--minimum-deployment-target", "13.0",
         "--app-icon", "AppIcon", "--target-device", "iphone", "--target-device", "ipad",
         "--output-partial-info-plist", os.path.join(base, "partial.plist"), catalog], stdout=subprocess.DEVNULL)
    return os.path.join(out, "Assets.car")


def descriptor(game, bundle_id, extensions):
    def esc(s):
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    exts = "".join(f"    <extensionID>{e}</extensionID>\n" for e in extensions)
    return f'''<?xml version="1.0" encoding="utf-8" ?>
<application xmlns="{AIR_NS}">
  <id>{bundle_id}</id>
  <versionNumber>{esc(game.version)}</versionNumber>
  <filename>{esc(game.filename)}</filename>
  <name>{esc(game.name)}</name>
  <supportedProfiles>mobileDevice</supportedProfiles>
  <extensions>
{exts}  </extensions>
  <initialWindow>
    <title>{esc(game.title)}</title>
    <content>{esc(game.content)}</content>
    <renderMode>{esc(game.render_mode)}</renderMode>
    <fullScreen>true</fullScreen>
    <aspectRatio>landscape</aspectRatio>
    <autoOrients>true</autoOrients>
    <visible>true</visible>
  </initialWindow>
  <iPhone>
    <requestedDisplayResolution>high</requestedDisplayResolution>
    <InfoAdditions><![CDATA[
{plist_fragment(info_additions(game))}
    ]]></InfoAdditions>
    <Entitlements><![CDATA[
{plist_fragment(ENTITLEMENTS)}
    ]]></Entitlements>
  </iPhone>
</application>
'''


def prepare(game, work, bundle_id):
    sdk = air_sdk()
    java_home()
    missing = [e for e in game.extensions if not stand_in(e)]
    if missing:
        sys.exit(f"no iOS stand-in for the native extension(s) {', '.join(missing)} (recomp/native/air/<id>.c)")
    shutil.rmtree(os.path.join(work, "extensions"), ignore_errors=True)
    for i, ext in enumerate(game.extensions):
        events.progress(i / (len(game.extensions) + 1), f"Building {ext}.ane")
        build_ane(sdk, game, ext, work)
    make_icon(game, work)
    with open(os.path.join(work, "app.xml"), "w") as f:
        f.write(descriptor(game, bundle_id, game.extensions))
    log(f"descriptor: {os.path.join(work, 'app.xml')} ({bundle_id})")


# --- package -------------------------------------------------------------------------------------

def profile_info(path):
    try:
        out = subprocess.run(["security", "cms", "-D", "-i", path], capture_output=True, check=True).stdout
        return plistlib.loads(out)
    except (subprocess.CalledProcessError, ValueError):
        return None


def provisioning_profile(team, bundle_id, cert_sha1):
    """The newest valid development profile of the team that covers bundle_id and holds the
    signing certificate: the bundle's own (made by the xcode stage) first, else a wildcard."""
    import hashlib
    now = datetime.datetime.now(datetime.timezone.utc)
    best = {}
    for d in PROFILE_DIRS:
        for path in glob.glob(os.path.join(d, "*.mobileprovision")):
            p = profile_info(path)
            if not p or team not in p.get("TeamIdentifier", []):
                continue
            expires = p.get("ExpirationDate")
            if expires and expires.replace(tzinfo=datetime.timezone.utc) < now:
                continue
            app_id = p.get("Entitlements", {}).get("application-identifier", "")
            kind = "exact" if app_id == f"{team}.{bundle_id}" else "wildcard" if app_id == f"{team}.*" else None
            if not kind or not p.get("Entitlements", {}).get("get-task-allow"):
                continue
            certs = {hashlib.sha1(c).hexdigest().upper() for c in p.get("DeveloperCertificates", [])}
            if cert_sha1 not in certs:
                continue
            created = p.get("CreationDate") or datetime.datetime.min
            if kind not in best or created > best[kind][0]:
                best[kind] = (created, path)
    for kind in ("exact", "wildcard"):
        if kind in best:
            return best[kind][1]
    sys.exit(f"no development provisioning profile of team {team} for {bundle_id} (or *) with your "
             "Apple Development certificate. Open Xcode once with any project signed automatically by that "
             "team (Xcode then makes the team's wildcard profile), or run this route's xcode stage, then retry.")


def team_identity(team):
    from recomp import discover
    for t in discover.signing_teams():
        if t["id"] == team:
            return t
    sys.exit(f"no Apple Development signing identity for team {team} in the keychain (see: recomp.py env)")


def adt_app(work):
    payload = os.path.join(work, "adt", "Payload")
    apps = [n for n in os.listdir(payload) if n.endswith(".app")] if os.path.isdir(payload) else []
    if not apps:
        sys.exit("no packaged app - run the package stage first")
    return os.path.join(payload, apps[0])


def package(game, work, team, bundle_id, interpreter):
    sdk = air_sdk()
    if not os.path.exists(os.path.join(work, "app.xml")):
        sys.exit("no descriptor - run the prepare stage first")
    ident = team_identity(team)
    profile = provisioning_profile(team, bundle_id, ident["sha1"])
    target = "ipa-test-interpreter" if interpreter else "ipa-test"
    ipa = os.path.join(work, f"{game.slug}.ipa")
    if os.path.exists(ipa):
        os.remove(ipa)
    log(f"packaging with ADT ({target}; {'about 2 minutes' if interpreter else 'ahead-of-time compilation, an hour or more'}), "
        f"profile {os.path.basename(profile)}")
    log("macOS may ask once to let java use your signing key: choose Always Allow")
    items = game.content_items()
    car = os.path.join(work, "icon", "car")
    icon = ["-C", car, "Assets.car"] if os.path.exists(os.path.join(car, "Assets.car")) else []
    if game.content not in items:
        sys.exit(f"{game.content} (the descriptor's initial content) is not in {game.resources}")

    def on_line(text):
        events.check_hints(text)
        print(text, flush=True)
        if text.strip():
            events.progress(None, text.strip()[:80])

    adt(sdk, ["-package", "-target", target, "-storetype", "KeychainStore", "-providerName", "Apple",
              "-alias", ident["identity"], "-storepass", "x", "-provisioning-profile", profile, ipa,
              os.path.join(work, "app.xml"), "-extdir", os.path.join(work, "extensions"), "-C", game.resources,
              *items, *icon], work, on_line)
    out = os.path.join(work, "adt")
    shutil.rmtree(out, ignore_errors=True)
    run(["ditto", "-x", "-k", ipa, out])
    os.remove(ipa)
    with open(os.path.join(work, "manifest.json"), "w") as f:
        json.dump({"app": game.app, "target": target, "built": adt_app(work)}, f, indent=2)
    log(f"packaged {adt_app(work)} ({target})")


# --- Xcode project ------------------------------------------------------------------------------

BUNDLE_SCRIPT = r'''set -e
APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
SRC="{src}"
# ADT's executable (the AIR runtime with the extensions linked in) replaces the placeholder
# Xcode linked (copied aside first so nothing ever sees a half-written file).
cp "$SRC/{exe}" "$APP/$EXECUTABLE_NAME.tmp"
mv -f "$APP/$EXECUTABLE_NAME.tmp" "$APP/$EXECUTABLE_NAME"
# The rest of ADT's app, as APFS clones (instant on the same disk), its Info.plist and asset
# catalog included: the AIR runtime checks at launch that the package is ADT's ("application
# packaging error" otherwise). Only the signature and profile are Xcode's.
cd "$SRC"
for item in *; do
  case "$item" in _CodeSignature|embedded.mobileprovision|{exe}) continue ;; esac
  rm -rf "$APP/$item"
  cp -Rc "$item" "$APP/"
done
if [ -d "$APP/Frameworks" ]; then
  find "$APP/Frameworks" -type f | while read -r f; do
    if file -b "$f" | grep -q Mach-O; then
      /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$f"
    fi
  done
fi
'''

PLACEHOLDER_MAIN = "// Replaced by ADT's executable before signing (see the Bundle game phase).\nint main(void) { return 0; }\n"
# ADT's keys that Xcode writes itself, or that name ADT's build.
XCODE_OWNS = {"CFBundleExecutable", "CFBundleIdentifier", "MinimumOSVersion", "CFBundleSupportedPlatforms",
              "DTCompiler", "DTPlatformBuild", "DTPlatformName", "DTPlatformVersion", "DTSDKBuild", "DTSDKName",
              "DTXcode", "DTXcodeBuild"}


def info_plist(game, adt_info):
    """For Xcode's build (its signing reads the bundle id); the Bundle game phase puts ADT's back."""
    plist = {k: v for k, v in adt_info.items() if k not in XCODE_OWNS}
    plist.update({"CFBundleExecutable": "$(EXECUTABLE_NAME)", "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)"})
    return plist


def game_icon(game):
    name = game.info.get("CFBundleIconFile")
    if not name:
        return None
    path = os.path.join(game.resources, name if name.endswith(".icns") else name + ".icns")
    return path if os.path.exists(path) else None


def xcode(game, work, team, bundle_id):
    src = adt_app(work)
    with open(os.path.join(src, "Info.plist"), "rb") as f:
        adt_info = plistlib.load(f)
    exe = adt_info["CFBundleExecutable"]
    proj = os.path.join(work, "xcode")
    os.makedirs(proj, exist_ok=True)
    with open(os.path.join(proj, "main.c"), "w") as f:
        f.write(PLACEHOLDER_MAIN)
    with open(os.path.join(proj, "Info.plist"), "wb") as f:
        plistlib.dump(info_plist(game, adt_info), f)
    with open(os.path.join(proj, "App.entitlements"), "wb") as f:
        plistlib.dump(ENTITLEMENTS, f)
    script = BUNDLE_SCRIPT.format(src=src, exe=exe)
    settings = {
        "INFOPLIST_FILE": "Info.plist", "CODE_SIGN_ENTITLEMENTS": "App.entitlements",
        "PRODUCT_BUNDLE_IDENTIFIER": bundle_id, "DEVELOPMENT_TEAM": team, "PRODUCT_NAME": exe,
        "IPHONEOS_DEPLOYMENT_TARGET": adt_info.get("MinimumOSVersion", "13.0"), "TARGETED_DEVICE_FAMILY": "1,2",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        "ENABLE_BITCODE": "NO", "DEAD_CODE_STRIPPING": "NO", "STRIP_INSTALLED_PRODUCT": "NO", "COPY_PHASE_STRIP": "NO",
        # No dSYM: dsymutil would read the placeholder while the script replaces it.
        "DEBUG_INFORMATION_FORMAT": "dwarf",
    }
    xcodeproj.write(proj, game.slug, ["main.c"], settings, script=script)
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
