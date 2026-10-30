"""Mac side of the Steam license check (the iOS side is recomp/native/RecompLicense.m).

A port of a Steam game only plays for someone who owns it on Steam. The port
carries the game's Steam app id in Info.plist ("RecompSteamAppId"); at launch
the port asks the player to sign in to Steam and checks that the account owns
that app. This is a check made in good faith, not DRM: the source is public and
anyone can remove it, but a port built by the released tool, or shared with
someone else, does not play without the game's license.

The app id comes from, in order:
  - the game's profile, "steam_app_id";
  - the Steam library the game is installed in (steamapps/appmanifest_<id>.acf
    whose "installdir" is the game's folder under steamapps/common).

A game that ships the Steamworks library (steam_api) but whose app id cannot be
found is refused: it was copied out of its Steam library or is not a Steam copy.
A game with neither (a GOG or itch build, a DRM-free Mac app) gets no check.

The profile's "steam_concurrent_play" ("deny", the default, or "allow") goes to Info.plist as
"RecompSteamConcurrentPlay": whether Steam stays usable while the same account plays on another
device (Kettle's RecompSteam_SetConcurrentPlay, set by RecompSteamStart.m before any logon).
"""
import glob
import os
import plistlib
import re
import sys

STEAMWORKS = re.compile(r"^((lib)?steam_api(64)?|CSteamworks)\.(dylib|bundle|so)$", re.IGNORECASE)
CONCURRENT_PLAY = ("deny", "allow")


def ships_steamworks(app):
    for _root, dirs, files in os.walk(app):
        if any(STEAMWORKS.match(n) for n in dirs + files):
            return True
    return False


def manifest_app_id(app):
    """The app id of the Steam library install that holds app, or None."""
    path = os.path.abspath(app)
    while True:
        parent = os.path.dirname(path)
        if parent == path:
            return None
        if os.path.basename(parent) == "common" and os.path.basename(os.path.dirname(parent)) == "steamapps":
            break
        path = parent
    folder = os.path.basename(path)
    for acf in glob.glob(os.path.join(os.path.dirname(parent), "appmanifest_*.acf")):
        try:
            text = open(acf, errors="replace").read()
        except OSError:
            continue
        appid = re.search(r'"appid"\s+"(\d+)"', text)
        installdir = re.search(r'"installdir"\s+"([^"]+)"', text)
        if appid and installdir and installdir.group(1).lower() == folder.lower():
            return int(appid.group(1))
    return None


def app_id(app, profile, log=print):
    """The game's Steam app id, None for a game that is not from Steam; exits for a
    Steam build whose app id is not known."""
    appid = (profile or {}).get("steam_app_id") or manifest_app_id(app)
    if appid:
        return int(appid)
    if ships_steamworks(app):
        sys.exit(f"{app} uses Steamworks but is not in a Steam library, so its Steam license cannot be "
                 "checked. Port it from the Steam library it was installed in.")
    log("Steam license check: not a Steam game, no check")
    return None


def concurrent_play(profile):
    """The profile's "steam_concurrent_play"; exits on a value that is neither."""
    value = (profile or {}).get("steam_concurrent_play", "deny")
    if value not in CONCURRENT_PLAY:
        sys.exit(f'profile "steam_concurrent_play" is {value!r}: use "deny" (the default) or "allow"')
    return value


def plist_keys(app, profile, log=print):
    """The Info.plist keys RecompLicense.m and RecompSteamStart.m read."""
    appid = app_id(app, profile, log)
    if not appid:
        return {}
    log(f"Steam license check: app {appid} (the player signs in to Steam on first launch)")
    play = concurrent_play(profile)
    if play == "allow":
        log("Steam concurrent play: allow (Steam stays on while the account plays on another device)")
    return {"RecompSteamAppId": appid, "RecompSteamConcurrentPlay": play}


def write_plist(app, profile, path, log=print):
    """Sets (or clears) the keys in the Info.plist at path."""
    with open(path, "rb") as f:
        info = plistlib.load(f)
    info.pop("RecompSteamAppId", None)
    info.pop("RecompSteamConcurrentPlay", None)
    info.update(plist_keys(app, profile, log))
    with open(path, "wb") as f:
        plistlib.dump(info, f)
