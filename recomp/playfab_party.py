"""PlayFab Party (crossplay networking) for Unity ports: Microsoft's PlayFabParty.framework
for iOS, fetched when porting and never committed, in place of the stub that fails
PartyInitialize and keeps a game offline.

A game's PlayFabParty.dll calls the C API of the Party build it shipped with (the Mac game's
PlayFabPartyMacOS.bundle). The iOS release used is the one whose headers are identical to that
bundle's and which exports every Party function the bundle does, so each P/Invoke and every
structure it passes match. A game whose bundle differs from the pinned release keeps the stub.

asmtool still internalizes the Party P/Invokes (to __Internal); the framework, embedded in the
app as a Unity iOS plug-in, defines them at link time. The Xbox Live half (PartyXbl*, module
PartyXboxLiveWin32) is not in the iOS framework and stays in stubs/playfab-party.overrides.c.
"""
import hashlib
import os
import shutil
import subprocess
import zipfile

from recomp import paths, toolchain

# Headers identical to the PlayFabPartyMacOS.bundle in Valheim's Mac build of 2026-10; later
# releases add an option (PARTY_OPTION_DEVELOPMENT_CONNECTIVITY_PRESERVATION_MODE).
VERSION = "v1.10.5"
ASSET = "PlayFabParty.framework-for-iOS-arm64-no-bitcode-Release.zip"
SHA256 = "72214ac3c69ac2e98089f7f4cfb2224840ddcee06d2316900e32ce67d9b51a62"
URL = f"https://github.com/PlayFab/PlayFabParty/releases/download/{VERSION}/{ASSET}"
HEADERS = ("Party.h", "Party_c.h", "PartyTypes.h")
# Defined first in the overrides when the framework is linked: the hand-written Party stubs step aside.
FLAG = "RECOMP_PLAYFAB_PARTY_FRAMEWORK"


def fetch(log):
    """The pinned PlayFabParty.framework under toolchain/, downloaded and checked once."""
    root = os.path.join(paths.TOOLCHAIN, "playfab-party", VERSION)
    framework = os.path.join(root, "PlayFabParty.framework")
    if os.path.isfile(os.path.join(framework, "PlayFabParty")):
        return framework
    os.makedirs(root, exist_ok=True)
    zpath = os.path.join(root, ASSET)
    toolchain.fetch(URL, zpath, f"PlayFab Party {VERSION}")
    h = hashlib.sha256()
    with open(zpath, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    if h.hexdigest() != SHA256:
        os.remove(zpath)
        raise RuntimeError(f"{ASSET}: sha256 {h.hexdigest()}, expected {SHA256}")
    with zipfile.ZipFile(zpath) as z:
        # Only the framework: the archive also holds its dSYM and the PlayFab C++ SDK (150 MB).
        for member in z.namelist():
            if member.startswith("PlayFabParty.framework/"):
                z.extract(member, root)
    os.remove(zpath)
    log(f"PlayFab Party {VERSION}: {framework}")
    return framework


def _exports(binary, arch=None):
    cmd = ["nm", "-gU"] + (["-arch", arch] if arch else []) + [binary]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    return {f[2][1:] for f in (l.split() for l in out.splitlines())
            if len(f) == 3 and f[1] == "T" and f[2].startswith("_Party")}


def _same_text(a, b):
    with open(a, "rb") as fa, open(b, "rb") as fb:
        return fa.read().replace(b"\r", b"") == fb.read().replace(b"\r", b"")


def matches(game_app, framework, log):
    """True when the game's Mac Party bundle has the framework's API: same headers, and every
    function the bundle exports is in the framework."""
    bundle = os.path.join(game_app, "Contents", "PlugIns", "PlayFabPartyMacOS.bundle", "Contents")
    if not os.path.isdir(bundle):
        log("PlayFab Party: the game has no PlayFabPartyMacOS.bundle to compare with")
        return False
    for h in HEADERS:
        mine, theirs = os.path.join(bundle, "Headers", h), os.path.join(framework, "Headers", h)
        if os.path.exists(mine) and not _same_text(mine, theirs):
            log(f"PlayFab Party: the game's {h} differs from {VERSION}'s")
            return False
    missing = _exports(os.path.join(bundle, "MacOS", "PlayFabPartyMacOS"), "arm64") - \
        _exports(os.path.join(framework, "PlayFabParty"))
    if missing:
        log(f"PlayFab Party: {VERSION} lacks {', '.join(sorted(missing))}")
        return False
    return True


def framework_meta(name):
    """A Unity plug-in .meta for an iOS framework: linked to the game and embedded in the app."""
    guid = hashlib.md5(("recomp-framework:" + name).encode()).hexdigest()
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
      settings:
        AddToEmbeddedBinaries: true
        CPU: ARM64
        CompileFlags:
        FrameworkDependencies:
  userData:
  assetBundleName:
  assetBundleVariant:
"""


def install(game, native, work, log):
    """Put PlayFabParty.framework among the shell's iOS plug-ins and return an overrides file
    for asmtool that names its functions (so no stub is generated for them), or None to keep
    the stub (no download, or a game built against another Party)."""
    try:
        framework = fetch(log)
    except Exception as e:  # offline, GitHub down: the port still builds, without crossplay
        log(f"PlayFab Party: {e}; crossplay stays off")
        return None
    if not matches(game.app, framework, log):
        log("PlayFab Party: keeping the stub; crossplay stays off")
        return None
    dest = os.path.join(native, "PlayFabParty.framework")
    shutil.rmtree(dest, ignore_errors=True)
    shutil.copytree(framework, dest, symlinks=True)
    with open(dest + ".meta", "w") as f:
        f.write(framework_meta("PlayFabParty.framework"))
    names = sorted(_exports(os.path.join(framework, "PlayFabParty")))
    path = os.path.join(work, "recomp_playfab_party_exports.c")
    with open(path, "w") as f:
        f.write(f"// PlayFab Party {VERSION} is linked (PlayFabParty.framework); it defines:\n")
        f.write(f"#define {FLAG} 1\n")
        for n in names:
            f.write(f"//   {n}()\n")
    log(f"PlayFab Party {VERSION}: linked, {len(names)} functions")
    return path
