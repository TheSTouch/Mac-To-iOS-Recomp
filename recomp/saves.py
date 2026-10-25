"""Mac side of the iCloud Drive save sync (the iOS side is recomp/native/RecompSaves.m).

A game whose profile has a "saves" block shares its saves with its iOS ports
through iCloud Drive/Recomp Saves/<Game>/. The Mac game is left as it is: it
keeps saving to its own folder, and Steam Cloud keeps syncing that folder. This
module copies the "include" entries both ways between the two folders, with the
rules the iOS side uses:

  - per file, the newest modification date wins;
  - a version changed since the last sync is never overwritten: it is kept next
    to the winner as "<name>.conflict-<device>-<yyyyMMdd-HHmm><ext>";
  - nothing is deleted, on either side.

A sync skips a game while it runs, so the game never sees its files change
under it: saves made on the Mac go to iCloud Drive after it quits, and saves
made on iOS are in place before it starts again (Steam Cloud then uploads them
too). Recomp Helper's background item runs `recomp.py saves --sync-all` every
few minutes; it runs as the app, which macOS lets read Documents and iCloud
Drive once the player allows it.

  --enable   backs up the entries to ~/Library/Application Support/Recomp Helper/
             save-backups/<Game>-<date>.tar.gz, adds the game to the synced
             games and syncs it once
  --disable  removes it from the synced games; no file moves
  --status   per entry: last change here and in iCloud Drive, last sync
  --sync     one sync now (refused while the game runs)

Profile schema: "saves": {"mac": "<save root, ~ and glob characters allowed>",
"ios": "<root relative to the app container>", "include": ["<top-level names>"]}.
A glob matching several folders (one per Steam account, say) uses the most
recently changed one.
"""
import datetime
import filecmp
import glob
import json
import os
import plistlib
import re
import shutil
import socket
import subprocess
import sys
import tarfile
import time

from recomp import paths

PROFILES = os.path.join(paths.CODE, "recomp", "profiles")
ICLOUD = os.path.expanduser("~/Library/Mobile Documents/com~apple~CloudDocs")
FOLDER = "Recomp Saves"
SUPPORT = os.path.expanduser("~/Library/Application Support/Recomp Helper")
BACKUPS = os.path.join(SUPPORT, "save-backups")
STATE = os.path.join(SUPPORT, "save-sync")  # games.json and one <Game>.json per synced game
# Steam's per-folder marker holds the account and means nothing elsewhere.
SKIP = {".DS_Store", "steam_autocloud.vdf"}
SAME_TIME = 1.0


def log(msg):
    print(f"[recomp] {msg}", file=sys.stderr, flush=True)


class Game:
    def __init__(self, app):
        self.app = os.path.abspath(app.rstrip("/"))
        self.contents = os.path.join(self.app, "Contents")
        try:
            with open(os.path.join(self.contents, "Info.plist"), "rb") as f:
                self.info = plistlib.load(f)
        except OSError:
            sys.exit(f"{self.app}: not a Mac app (no Contents/Info.plist)")
        base = os.path.splitext(os.path.basename(self.app))[0]
        # The same name each route writes as RecompGame: the iOS port's folder in iCloud Drive.
        self.unity = os.path.isdir(os.path.join(self.contents, "Resources", "Data", "Managed"))
        self.name = (self.info.get("CFBundleName") or base) if self.unity else base
        self.profile = profile_for(self)
        self.saves = self.profile.get("saves") if self.profile else None


def profile_for(game):
    """The profile that names this game: its Unity assembly, its UE4 project or its name."""
    for n in sorted(os.listdir(PROFILES)):
        if not n.endswith(".json"):
            continue
        with open(os.path.join(PROFILES, n)) as f:
            p = json.load(f)
        if p.get("when_assembly"):
            hit = os.path.exists(os.path.join(game.contents, "Resources", "Data", "Managed", p["when_assembly"]))
        elif p.get("unreal_project"):
            hit = os.path.isdir(os.path.join(game.contents, "UE4", p["unreal_project"]))
        else:
            hit = p.get("name") == game.name
        if hit:
            return p
    return None


def has_saves(app):
    """For the scan: whether the game's profile has a saves block."""
    try:
        return bool(Game(app).saves)
    except (SystemExit, Exception):
        return False


# --- where things are ------------------------------------------------------------

def mac_root(game):
    """The Mac save root, or None when it does not exist (yet)."""
    pattern = os.path.expanduser(game.saves["mac"])
    if not glob.has_magic(pattern):
        return pattern if os.path.isdir(pattern) else None
    found = sorted((p for p in glob.glob(pattern) if os.path.isdir(p)), key=os.path.getmtime, reverse=True)
    if len(found) > 1:
        log(f"{len(found)} save folders match {game.saves['mac']}; using the most recently changed: {found[0]}")
    return found[0] if found else None


def icloud_game(game):
    if not os.path.isdir(ICLOUD):
        sys.exit("iCloud Drive is off on this Mac. Turn it on in System Settings > your name > iCloud > "
                 "iCloud Drive, then try again.")
    return os.path.join(ICLOUD, FOLDER, game.name)


def include(game):
    names = [n for n in game.saves.get("include", []) if n and "/" not in n and not n.startswith(".")]
    if not names:
        sys.exit(f"{game.name}: the profile's saves block has no include entries")
    return names


def device_name():
    try:
        name = subprocess.run(["scutil", "--get", "ComputerName"], capture_output=True, text=True,
                              check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        name = socket.gethostname().split(".")[0]
    return re.sub(r"[/:\\.]", "-", name) or "Mac"


def running(game):
    exe = os.path.join(game.contents, "MacOS", game.info.get("CFBundleExecutable", ""))
    out = subprocess.run(["ps", "-axo", "command="], capture_output=True, text=True).stdout
    return any(line.startswith(exe) for line in out.splitlines())


def iso(t):
    return datetime.datetime.fromtimestamp(t).isoformat(timespec="seconds") if t else None


def load(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".tmp", "w") as f:
        json.dump(data, f, indent=1)
    os.replace(path + ".tmp", path)


def games_file():
    return os.path.join(STATE, "games.json")


def state_file(game):
    return os.path.join(STATE, f"{game.name}.json")


# --- sync ------------------------------------------------------------------------

def files(top, names):
    """{relative path: mtime} of every file under the include entries."""
    out = {}
    for n in names:
        p = os.path.join(top, n)
        if os.path.isfile(p):
            out[n] = os.path.getmtime(p)
            continue
        for root, dirs, fs in os.walk(p):
            dirs[:] = [d for d in dirs if not d.startswith(".")]
            for f in fs:
                if f in SKIP or f.endswith(".recomp-tmp") or (f.startswith(".") and f.endswith(".icloud")):
                    continue
                full = os.path.join(root, f)
                try:
                    out[os.path.relpath(full, top)] = os.path.getmtime(full)
                except OSError:
                    pass
    return out


def place(src, dst, fresh=False):
    """Copy src over dst through a temporary file, keeping src's dates. With fresh, an existing dst is left alone."""
    if fresh and os.path.lexists(dst):
        return False
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    tmp = os.path.join(os.path.dirname(dst), f".{os.path.basename(dst)}.recomp-tmp")
    shutil.copy2(src, tmp)
    os.replace(tmp, dst)
    return True


def conflict_name(rel, mtime, device, *tops):
    folder, name = os.path.split(rel)
    stem, ext = os.path.splitext(name)
    base = f"{stem}.conflict-{device}-{datetime.datetime.fromtimestamp(mtime):%Y%m%d-%H%M}"
    for i in range(1, 1000):
        candidate = os.path.join(folder, (base if i == 1 else f"{base}-{i}") + ext)
        if not any(os.path.lexists(os.path.join(t, candidate)) for t in tops):
            return candidate
    raise RuntimeError(f"no free conflict name for {rel}")


def sync(game, why):
    """One two-way sync of the game's include entries. Returns the counts."""
    root, cloud = mac_root(game), icloud_game(game)
    out = {"to_cloud": 0, "to_mac": 0, "conflicts": 0, "errors": []}
    if not root:
        return out  # the game has not saved on this Mac yet; iCloud saves wait for its folder
    names = include(game)
    unlink(root, cloud, names)
    os.makedirs(cloud, exist_ok=True)
    st = load(state_file(game), {})
    known = st.get("files", {})
    local, remote = files(root, names), files(cloud, names)
    device = device_name()
    for rel in sorted(set(local) | set(remote)):
        l, c, s = local.get(rel), remote.get(rel), known.get(rel)
        mine, theirs = os.path.join(root, rel), os.path.join(cloud, rel)
        try:
            if c is None:
                if place(mine, theirs, fresh=True):
                    out["to_cloud"] += 1
            elif l is None:
                if place(theirs, mine, fresh=True):
                    out["to_mac"] += 1
            else:
                l_changed = not s or abs(l - s["l"]) > SAME_TIME
                c_changed = not s or abs(c - s["c"]) > SAME_TIME
                if not l_changed and not c_changed:
                    continue
                if not filecmp.cmp(mine, theirs, shallow=False):
                    mac_wins = l >= c
                    loser, loser_changed = (theirs, c_changed) if mac_wins else (mine, l_changed)
                    if loser_changed:
                        keep = conflict_name(rel, os.path.getmtime(loser), device, root, cloud)
                        place(loser, os.path.join(root, keep), fresh=True)
                        place(loser, os.path.join(cloud, keep), fresh=True)
                        log(f"{game.name}: {rel} changed on both sides; kept {keep}")
                        out["conflicts"] += 1
                    if mac_wins:
                        place(mine, theirs)
                        out["to_cloud"] += 1
                    else:
                        place(theirs, mine)
                        out["to_mac"] += 1
            known[rel] = {"l": os.path.getmtime(mine), "c": os.path.getmtime(theirs)}
        except OSError as e:
            out["errors"].append(f"{rel}: {e.strerror or e}")
    st.update(files=known, last=time.time(), why=why, result={k: v for k, v in out.items()})
    save(state_file(game), st)
    log(f"{game.name} ({why}): {out['to_mac']} from iCloud Drive, {out['to_cloud']} to iCloud Drive, "
        f"{out['conflicts']} conflicts" + (f", {len(out['errors'])} errors" if out["errors"] else ""))
    for e in out["errors"]:
        log(f"  {e}")
    return out


def unlink(root, cloud, names):
    """Undo the first version of this module, which linked the entries into iCloud Drive."""
    for n in names:
        p = os.path.join(root, n)
        if os.path.islink(p) and os.path.realpath(p) == os.path.realpath(os.path.join(cloud, n)):
            tmp = p + ".recomp-tmp"
            if os.path.isdir(p):
                shutil.copytree(p, tmp)
            else:
                shutil.copy2(p, tmp)
            os.remove(p)
            os.rename(tmp, p)
            log(f"{n}: link to iCloud Drive replaced by a real copy")


def backup(game, root, names):
    os.makedirs(BACKUPS, exist_ok=True)
    out = os.path.join(BACKUPS, f"{game.name}-{datetime.datetime.now():%Y%m%d-%H%M%S}.tar.gz")
    with tarfile.open(out, "w:gz") as tar:
        for n in names:
            p = os.path.join(root, n)
            if os.path.exists(p):
                tar.add(p, arcname=n)
    return out


# --- commands --------------------------------------------------------------------

def check(game):
    if not game.saves:
        sys.exit(f"{game.name}: no saves block in its profile (recomp/profiles), so save sync is not available")


def synced_games():
    return load(games_file(), {})


def enable(game):
    check(game)
    icloud_game(game)
    games = synced_games()
    extra = {"backup": None}
    root = mac_root(game)
    if root and game.name not in games:
        extra["backup"] = backup(game, root, include(game))
        log(f"backup: {extra['backup']}")
    games[game.name] = game.app
    save(games_file(), games)
    if running(game):
        log(f"{game.name} is running: its saves sync after it quits")
    else:
        extra.update(sync(game, "enabled"))
    return status(game, extra)


def disable(game):
    check(game)
    games = synced_games()
    games.pop(game.name, None)
    save(games_file(), games)
    log(f"{game.name}: no longer synced; its saves stay where they are, here and in iCloud Drive")
    return status(game)


def sync_now(game):
    check(game)
    if running(game):
        sys.exit(f"Quit {game.name} first: its saves sync while it is not running.")
    return status(game, sync(game, "by hand"))


def sync_all():
    """Every synced game that is not running (Recomp Helper's background item)."""
    for name, app in sorted(synced_games().items()):
        try:
            game = Game(app)
            if game.saves and not running(game):
                sync(game, "background")
        except (SystemExit, Exception) as e:
            log(f"{name}: {e}")
    return 0


def newest(top, names):
    times = files(top, names).values() if top else []
    return max(times, default=0)


def status(game, extra=None):
    out = {"game": game.name, "supported": bool(game.saves), "icloud": os.path.isdir(ICLOUD), "enabled": False,
           "root": None, "cloud": None, "entries": [], "last_change": None, "last_sync": None, "running": False,
           "synced_games": len(synced_games())}
    if not game.saves:
        return out
    root = mac_root(game)
    cloud = os.path.join(ICLOUD, FOLDER, game.name)
    names = game.saves.get("include", [])
    st = load(state_file(game), {})
    out.update(root=root, cloud=cloud, enabled=game.name in synced_games(), running=running(game),
               last_sync=iso(st.get("last", 0)), last_result=st.get("result"))
    for n in names:
        here = newest(root, [n]) if root else 0
        there = newest(cloud, [n]) if os.path.isdir(cloud) else 0
        out["entries"].append({"name": n, "mac": iso(here), "icloud": iso(there)})
    out["last_change"] = iso(max([newest(root, names) if root else 0, newest(cloud, names) if os.path.isdir(cloud) else 0]))
    out.update(extra or {})
    return out


def show(st):
    if not st["supported"]:
        print(f"{st['game']}: save sync is not available (no saves block in its profile)")
        return
    print(f"{st['game']}: save sync with iCloud Drive is {'on' if st['enabled'] else 'off'}"
          + (" (the game is running: it syncs after it quits)" if st["running"] and st["enabled"] else ""))
    print(f"  saves:        {st['root'] or '(no save folder on this Mac yet)'}")
    print(f"  iCloud Drive: {st['cloud']}" + ("" if st["icloud"] else " (iCloud Drive is off on this Mac)"))
    print(f"  last sync:    {st['last_sync'] or '-'}")
    for e in st["entries"]:
        print(f"  {e['name']:<20} last change on this Mac {e['mac'] or '-':<20} in iCloud Drive {e['icloud'] or '-'}")
    if st.get("backup"):
        print(f"  backup:       {st['backup']}")
    if "to_mac" in st:
        print(f"  this sync:    {st['to_mac']} from iCloud Drive, {st['to_cloud']} to iCloud Drive, "
              f"{st['conflicts']} conflicts kept as copies")
        for e in st["errors"]:
            print(f"  error: {e}")
