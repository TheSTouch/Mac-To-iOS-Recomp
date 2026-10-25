"""Windows game installs (CrossOver bottles, Windows Steam libraries) and why they do not port.

The routes start from a Mac build: the Unity route recompiles a game's .NET
code and reuses its data, whose shaders are Metal; the Unreal route reuses a
Mac build's arm64 code. A Windows build has x86 code (iPadOS forbids the JIT a
translator needs) and DirectX shaders. Engines whose game data runs anywhere
(Godot, Ren'Py, RPG Maker MV/MZ) are the exception: the planned engine-runtime
route would take their data from any platform.

scan_root() returns reports in the same shape as tools/inspect_app.py, so the
app lists them with the Mac games.
"""
import glob
import os
import re
import struct

HOME = os.path.expanduser("~")
BOTTLES = os.path.join(HOME, "Library", "Application Support", "CrossOver", "Bottles")
# Steam folders that are tools and redistributables, not games.
NOT_GAME_FOLDERS = re.compile(r"^(Steamworks Shared|Steam Controller Configs|SteamVR|Proton.*|Steam Linux Runtime.*|_CommonRedist|DirectX)$",
                              re.IGNORECASE)
PE_MACHINES = {0x8664: "x86_64", 0x14C: "i386", 0xAA64: "arm64"}
# Executables that are not the game: launchers, crash reporters, redistributables.
NOT_GAMES = re.compile(r"(unins|crash|report|setup|redist|vc_|dxsetup|launcher|helper|uploader|easyanticheat|be(service|launcher))",
                       re.IGNORECASE)


def crossover_steam_libraries():
    """steamapps/common folders of Windows Steam installs in CrossOver bottles, as Mac paths."""
    libs = []
    for bottle in sorted(glob.glob(os.path.join(BOTTLES, "*"))):
        drive_c = os.path.join(bottle, "drive_c")
        for steam in (os.path.join(drive_c, "Program Files (x86)", "Steam"), os.path.join(drive_c, "Program Files", "Steam")):
            vdf = os.path.join(steam, "steamapps", "libraryfolders.vdf")
            paths = [steam]
            if os.path.exists(vdf):
                for p in re.findall(r'"path"\s+"([^"]+)"', open(vdf, errors="replace").read()):
                    mac = _windows_to_mac(bottle, p.replace("\\\\", "\\"))
                    if mac:
                        paths.append(mac)
            for p in paths:
                common = os.path.join(p, "steamapps", "common")
                if os.path.isdir(common) and common not in libs:
                    libs.append(common)
    return libs


def _windows_to_mac(bottle, path):
    """'D:\\SteamLibrary' -> the Mac folder the bottle's drive D: points to."""
    m = re.match(r"([A-Za-z]):\\?(.*)", path)
    if not m:
        return None
    drive = os.path.join(bottle, "dosdevices", m.group(1).lower() + ":")
    if not os.path.exists(drive):
        return None
    return os.path.join(os.path.realpath(drive), *[p for p in m.group(2).split("\\") if p])


def _exes(folder, depth=4):
    out = []
    for root, dirs, files in os.walk(folder):
        if root[len(folder):].count(os.sep) >= depth:
            dirs[:] = []
        dirs[:] = [d for d in dirs if not d.endswith(".app")]
        out += [os.path.join(root, f) for f in files if f.lower().endswith(".exe")]
    return out


def _machine(exe):
    try:
        with open(exe, "rb") as f:
            head = f.read(4096)
        if head[:2] != b"MZ":
            return None
        pe = struct.unpack_from("<I", head, 0x3C)[0]
        if head[pe:pe + 4] != b"PE\0\0":
            return None
        return PE_MACHINES.get(struct.unpack_from("<H", head, pe + 4)[0], "unknown")
    except (OSError, struct.error):
        return None


def _engine(folder, exes):
    """(engine, backend or None)."""
    def has(*rel):
        return any(glob.glob(os.path.join(folder, r)) for r in rel)
    if has("*_Data/Managed/Assembly-CSharp.dll"):
        return "Unity", "Mono"
    if has("GameAssembly.dll", "*_Data/il2cpp_data"):
        return "Unity", "IL2CPP"
    if has("UnityPlayer.dll"):
        return "Unity", None
    if has("Engine/Binaries/Win64", "*/Binaries/Win64", "*/Content/Paks/*.pak"):
        return "Unreal", None
    if has("*.pck") or any(os.path.getsize(e) > 20_000_000 and _is_godot(e) for e in exes[:3]):
        return "Godot", None
    if has("data.win"):
        return "GameMaker", None
    if has("renpy", "lib/*/renpy*"):
        return "RenPy", None
    if has("www/js/rpg_core.js", "js/rmmz_core.js", "www/js/rmmz_core.js"):
        return "RPGMaker MV/MZ", None
    if has("Game.rgss3a", "Game.rgss2a", "Game.rgssad"):
        return "RPGMaker (RGSS)", None
    return "Own engine", None


def _is_godot(exe):
    try:
        with open(exe, "rb") as f:
            f.seek(-12, os.SEEK_END)
            return f.read(4) == b"GDPC"
    except OSError:
        return False


def _status(engine, backend):
    if engine in ("Godot", "RenPy", "RPGMaker MV/MZ"):
        return "planned", f"{engine} (Windows install): the game data runs anywhere; planned engine-runtime route."
    if engine == "Unity" and backend == "Mono":
        return "unsupported", ("Windows build of a Unity (Mono) game: the Unity route needs the Mac build, whose data "
                               "has Metal shaders (Windows data has DirectX ones). Install the Mac version if there is one.")
    if engine == "Unity":
        return "unsupported", "Windows build, Unity IL2CPP: already compiled to x86 code, with no .NET code left to recompile."
    if engine == "Unreal":
        return "unsupported", ("Windows build of an Unreal game: x86 code and DirectX shaders. The Unreal route reuses "
                               "a Mac build for Apple Silicon.")
    return "unsupported", "Windows build: x86 code, and iPadOS forbids the JIT a translator would need."


def inspect(folder, source):
    exes = [e for e in _exes(folder) if not NOT_GAMES.search(os.path.basename(e))] or _exes(folder)
    engine, backend = _engine(folder, exes)
    archs = sorted({a for a in (_machine(e) for e in exes[:8]) if a})
    status, detail = _status(engine, backend)
    return {
        "app": folder,
        "name": os.path.basename(folder),
        "bundle_id": None,
        "engine": engine,
        "engine_backend": ", ".join(x for x in (backend, "Windows") if x),
        "archs": archs or ["x86_64"],
        "mac_only_frameworks": [],
        "flags": ["Windows install (CrossOver or a Windows Steam library), not a Mac build."],
        "routes": [],
        "source": source,
        "route": None,
        "status": status,
        "status_detail": detail,
        "checks": [],
    }


def scan_root(root, source, depth=2):
    """Windows game folders under root: folders holding a .exe and no Mac .app."""
    found = []
    if os.path.isdir(os.path.join(root, "steamapps", "common")):
        root = os.path.join(root, "steamapps", "common")  # a library root: its games are in here
    if not os.path.isdir(root):
        return found
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return found
    for name in names:
        path = os.path.join(root, name)
        if not os.path.isdir(path) or os.path.islink(path) or name.endswith(".app") or name.startswith(".") \
                or NOT_GAME_FOLDERS.match(name):
            continue
        if glob.glob(os.path.join(path, "*.app")):
            continue
        if _exes(path):
            found.append(inspect(path, source))
        elif depth > 1:
            found += scan_root(path, source, depth - 1)
    return found
