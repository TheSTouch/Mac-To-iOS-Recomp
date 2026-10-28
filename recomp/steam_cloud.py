"""Port-time side of Steam Cloud saves (the device side is recomp/native/RecompSteam/cloud*.m).

A port's saves follow the player in one of three ways:

  steam   the port syncs with the player's Steam Cloud like the Steam client:
          the game's Auto-Cloud folders (its app info's "ufs" rules) and the
          files it writes through ISteamRemoteStorage
  icloud  the iCloud Drive sync of recomp/native/RecompSaves.m and recomp/saves.py
  off     no sync

A Steam game (it ships Steamworks and its app id is known) has no choice: its
port runs the Steam runtime, so it syncs with Steam Cloud when the game has it (a
"ufs" section in its Steam app info) and keeps its saves on the device when it
has none. iCloud Drive is for games without Steam: icloud when the profile has a
saves block, else off; `--saves icloud|off` (or Recomp Helper's port panel)
picks between those two.

The ufs rules come from the Steam app's own cache on this Mac
(~/Library/Application Support/Steam/appcache/appinfo.vdf), so no sign-in is
needed when porting. Each "savefiles" rule names a root (WinMyDocuments,
WinAppDataLocalLow, ...), a path, a file pattern and whether it is recursive; a
"rootoverrides" entry for MacOS swaps the root (useinstead), prefixes the path
(addpath) and rewrites it (pathtransforms). Steam Cloud names a file by the
rule's own root and path, "%WinMyDocuments%Timberborn/Saves/a.timber"; the Mac
client keeps it where the override says, ~/Documents/Timberborn/Saves/a.timber.
On iOS the profile's saves block maps the Mac folder into the app container
(its "mac" root becomes its "ios" root); a game without one gets the iOS
folder of the same kind (MacAppSupport -> Library/Application Support).

Files a game writes through ISteamRemoteStorage are Steam Cloud names with no
root ("characters/x.fch" for Valheim); the port keeps them in
Library/Application Support/RecompSteam/remote/ (on a Mac test clone,
~/Library/Application Support/RecompSteam/<appid>/remote/, never Steam's own
userdata folder).

Info.plist keys:
  RecompSavesMode   "steam", "icloud" or "off"
  RecompSteamCloud  {"appid": N, "quota": <bytes>, "rules": [{"cloud": "<name prefix>", "local": "<folder>",
                    "pattern": "<glob>", "recursive": bool}]}, in steam mode only; "local"
                    is relative to the app container on iOS and starts with ~/ on a Mac;
                    "{64BitSteamID}" in either is the signed-in account's.
"""
import fnmatch
import glob
import os
import struct

APPINFO = os.path.expanduser("~/Library/Application Support/Steam/appcache/appinfo.vdf")
MODES = ("steam", "icloud", "off")
STEAMID = "{64BitSteamID}"

# Steam's Mac roots; and where the same kind of folder is in an iOS app container.
MAC_ROOTS = {"MacAppSupport": "~/Library/Application Support", "MacDocuments": "~/Documents",
             "MacHome": "~", "MacCaches": "~/Library/Caches"}
IOS_ROOTS = {"MacAppSupport": "Library/Application Support", "MacDocuments": "Documents",
             "MacHome": "", "MacCaches": "Library/Caches"}
IOS_REMOTE = "Library/Application Support/RecompSteam/remote/"


def mac_remote(appid):
    return f"~/Library/Application Support/RecompSteam/{appid}/remote/"


# --- appinfo.vdf ------------------------------------------------------------------

def _kv(buf, pos, keys):
    """One binary KeyValues section; keys come from the string table (v29) or inline (v28)."""
    out = {}
    while True:
        t = buf[pos]
        pos += 1
        if t == 8:
            return out, pos
        if keys is not None:
            key = keys[struct.unpack_from("<i", buf, pos)[0]]
            pos += 4
        else:
            end = buf.index(b"\0", pos)
            key, pos = buf[pos:end].decode("utf-8", "replace"), end + 1
        if t == 0:
            out[key], pos = _kv(buf, pos, keys)
        elif t == 1:
            end = buf.index(b"\0", pos)
            out[key], pos = buf[pos:end].decode("utf-8", "replace"), end + 1
        elif t in (2, 3, 4, 6):
            out[key] = struct.unpack_from("<f" if t == 3 else "<i", buf, pos)[0]
            pos += 4
        elif t in (7, 10):
            out[key] = struct.unpack_from("<Q" if t == 7 else "<q", buf, pos)[0]
            pos += 8
        else:
            raise ValueError(f"appinfo.vdf: value type {t} not known")


_cache = {}


def app_info(appid, path=APPINFO):
    """The "appinfo" section of one app in Steam's cache, or None."""
    if (path, appid) in _cache:
        return _cache[path, appid]
    try:
        with open(path, "rb") as f:
            buf = f.read()
    except OSError:
        return None
    _cache[path, appid] = info = _find(buf, appid)
    return info


def _find(buf, appid):
    magic, _universe = struct.unpack_from("<II", buf, 0)
    if magic == 0x07564429:      # v29: keys are indices into a string table at the end
        table = struct.unpack_from("<q", buf, 8)[0]
        count = struct.unpack_from("<I", buf, table)[0]
        keys, p = [], table + 4
        for _ in range(count):
            end = buf.index(b"\0", p)
            keys.append(buf[p:end].decode("utf-8", "replace"))
            p = end + 1
        pos = 16
    elif magic == 0x07564428:
        keys, pos = None, 8
    else:
        return None
    while pos + 8 <= len(buf):
        app, size = struct.unpack_from("<II", buf, pos)
        if app == 0:
            return None
        if app == appid:
            # appid, size, state, last updated, PICS token, text sha1, change number, binary sha1
            info, _ = _kv(buf, pos + 8 + 4 + 4 + 8 + 20 + 4 + 20, keys)
            return info.get("appinfo", info)
        pos += 8 + size
    return None


def ufs(appid):
    info = app_info(appid) if appid else None
    return (info or {}).get("ufs")


def has_cloud(u):
    return bool(u and (u.get("savefiles") or int(u.get("quota") or 0) > 0))


# --- ufs rules -> local folders ---------------------------------------------------

def _entries(section):
    return [section[k] for k in sorted((section or {}), key=lambda k: int(k) if str(k).isdigit() else 0)]


def _slashes(p):
    return p.replace("\\", "/").strip("/")


def _for_mac(rule):
    plats = rule.get("platforms")
    return not plats or any(str(v).lower() in ("macos", "all") for v in plats.values())


def mac_folder(rule, u, log=print):
    """(Mac root name, path under it) of one savefiles rule after the MacOS root override."""
    root, path = rule.get("root", ""), _slashes(rule.get("path", ""))
    for o in _entries(u.get("rootoverrides")):
        if o.get("root") != root or o.get("os") != "MacOS" or o.get("oscompare", "=") != "=":
            continue
        root = o.get("useinstead", root)
        path = _slashes(_slashes(o.get("addpath", "")) + "/" + path)
        for t in _entries(o.get("pathtransforms")):
            find = _slashes(t.get("find", ""))
            if find and path.startswith(find):
                path = _slashes(_slashes(t.get("replace", "")) + path[len(find):])
        break
    if root not in MAC_ROOTS:
        log(f"Steam Cloud: rule {rule.get('root')}/{rule.get('path')} has no Mac folder ({root}); skipped")
        return None
    return root, path


def _profile_map(mac_path, saves):
    """The iOS folder of a Mac folder through the profile's saves block (its mac root -> its ios root)."""
    if not saves or not saves.get("mac") or "ios" not in saves:
        return None
    pat = [c for c in os.path.expanduser(saves["mac"]).split("/") if c]
    have = [c for c in os.path.expanduser(mac_path).split("/") if c]
    if len(have) < len(pat):
        return None
    for p, h in zip(pat, have):
        if not (fnmatch.fnmatchcase(h, p) or (h == STEAMID and glob.has_magic(p))):
            return None
    return "/".join([saves["ios"].strip("/")] + have[len(pat):])


def rules(appid, u, saves, platform="ios", log=print):
    """The RecompSteamCloud rules: each Auto-Cloud rule's cloud name prefix and local folder, then the
    ISteamRemoteStorage folder (cloud names with no root)."""
    out = []
    for r in _entries(u.get("savefiles")):
        if not _for_mac(r):
            continue
        mac = mac_folder(r, u, log)
        if not mac:
            continue
        root, path = mac
        cloud = f"%{r.get('root', '')}%" + (_slashes(r.get("path", "")) + "/" if r.get("path") else "")
        mac_path = "/".join(p for p in (MAC_ROOTS[root], path) if p)
        if platform == "mac":
            local = mac_path
        else:
            local = _profile_map(mac_path, saves)
            if local is None:
                local = "/".join(p for p in (IOS_ROOTS[root], path) if p)
        out.append({"cloud": cloud, "local": local.rstrip("/") + "/" if local else "",
                    "pattern": r.get("pattern") or "*", "recursive": str(r.get("recursive", "0")) == "1"})
    out.append({"cloud": "", "local": mac_remote(appid) if platform == "mac" else IOS_REMOTE,
                "pattern": "*", "recursive": True})
    return out


# --- the mode and the plist keys ------------------------------------------------

def steam_game(app, profile):
    """The app id of a Steam game (it ships Steamworks and its app id is known), else None."""
    from recomp import steam_license
    appid = (profile or {}).get("steam_app_id") or steam_license.manifest_app_id(app)
    return int(appid) if appid and steam_license.ships_steamworks(app) else None


def default_mode(app, profile, log=print):
    appid = steam_game(app, profile)
    if appid:
        return "steam" if has_cloud(ufs(appid)) else "off"
    return "icloud" if (profile or {}).get("saves") else "off"


def port_mode(app, profile, chosen=None, log=print):
    """The port's save sync: a Steam game's is fixed (default_mode), --saves picks only for
    other games."""
    mode = default_mode(app, profile, log)
    appid = steam_game(app, profile)
    if appid and mode == "off":
        log(f"saves: no Steam Cloud settings for app {appid} in Steam's app cache on this Mac ({APPINFO}); "
            "the game has no Steam Cloud, or Steam has not run here since it was installed: the port keeps "
            "its saves on the device")
    if chosen and chosen != mode:
        if appid:
            raise SystemExit(f"--saves {chosen}: a Steam game's port syncs through its Steam client "
                             f"({'Steam Cloud' if mode == 'steam' else 'no Steam Cloud for this game'}); "
                             "iCloud Drive sync is only for games without Steam")
        if chosen == "steam":
            raise SystemExit("--saves steam: not a Steam game (no Steamworks, or its Steam app id is not known)")
        return chosen
    return mode


def plist_keys(app, profile, mode=None, platform="ios", log=print):
    """RecompSavesMode, plus RecompSteamCloud in steam mode, plus RecompSaves in icloud mode."""
    from recomp import steam_license
    profile = profile or {}
    mode = mode or default_mode(app, profile, log)
    if mode not in MODES:
        raise SystemExit(f"--saves {mode}: choose from {', '.join(MODES)}")
    keys = {"RecompSavesMode": mode}
    if mode == "icloud":
        if not profile.get("saves"):
            raise SystemExit("--saves icloud: the game's profile has no saves block (recomp/profiles), so the "
                             "iCloud Drive sync does not know where its saves are")
        keys["RecompSaves"] = profile["saves"]
    elif mode == "steam":
        appid = profile.get("steam_app_id") or steam_license.manifest_app_id(app)
        if not appid:
            raise SystemExit("--saves steam: the game's Steam app id is not known (not in a Steam library)")
        u = ufs(int(appid))
        if not has_cloud(u):
            raise SystemExit(f"--saves steam: no Steam Cloud settings for app {appid} in Steam's app cache on this "
                             f"Mac ({APPINFO}); the game has no Steam Cloud, or Steam has not run here since it "
                             "was installed")
        keys["RecompSteamCloud"] = {"appid": int(appid), "quota": int(u.get("quota") or 0),
                                    "rules": rules(int(appid), u, profile.get("saves"), platform, log)}
    log(f"saves: {mode}" + (f", {len(keys['RecompSteamCloud']['rules'])} Steam Cloud rules"
                            if mode == "steam" else ""))
    return keys


def steam_cloud_plist(app, profile, platform="mac", mode="steam", log=print):
    """For a Mac test clone of the game (scripts/steam-mac-clone.py): the same keys, with Mac folders."""
    return plist_keys(app, profile, mode, platform, log)
