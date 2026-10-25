"""Mac side of the iCloud Drive save sync (the iOS side is recomp/native/RecompSaves.m).

A game whose profile has a "saves" block keeps its saves in
iCloud Drive/Recomp Saves/<Game>/, which the iOS port syncs with. On the Mac,
--enable moves each "include" entry of the save root there and leaves a symlink
at the original path: the Mac game reads and writes iCloud Drive directly, and
Steam Cloud still finds its files at the paths it knows. --disable puts real
copies back; the iCloud Drive copies stay, as nothing is ever deleted across
devices.

When iCloud Drive already holds saves for the game, --enable merges: per file
the newest version wins, and the older of two different versions is kept next
to it as "<name>.conflict-<device>-<yyyyMMdd-HHmm><ext>" (the iOS side uses the
same rule and names). The entries are backed up first, to
~/Library/Application Support/Recomp Helper/save-backups/<Game>-<date>.tar.gz.

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

from recomp import paths

PROFILES = os.path.join(paths.CODE, "recomp", "profiles")
ICLOUD = os.path.expanduser("~/Library/Mobile Documents/com~apple~CloudDocs")
FOLDER = "Recomp Saves"
BACKUPS = os.path.expanduser("~/Library/Application Support/Recomp Helper/save-backups")
SKIP = {".DS_Store"}
NOT_SAVES = SKIP | {"steam_autocloud.vdf"}  # Steam touches it at every launch


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

def mac_root(game, create=False):
    """The Mac save root, or None when it does not exist (yet)."""
    pattern = os.path.expanduser(game.saves["mac"])
    if not glob.has_magic(pattern):
        if create:
            os.makedirs(pattern, exist_ok=True)
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


def newest(path):
    """Latest modification time of a file or of anything under a folder (following a link at the top)."""
    best = 0.0
    if os.path.isfile(path):
        return os.path.getmtime(path)
    for root, _dirs, files in os.walk(path):
        for n in files:
            if n not in NOT_SAVES:
                try:
                    best = max(best, os.path.getmtime(os.path.join(root, n)))
                except OSError:
                    pass
    return best


def iso(t):
    return datetime.datetime.fromtimestamp(t).isoformat(timespec="seconds") if t else None


# --- merge -----------------------------------------------------------------------

def conflict_name(path, mtime, device):
    folder, name = os.path.split(path)
    stem, ext = os.path.splitext(name)
    base = f"{stem}.conflict-{device}-{datetime.datetime.fromtimestamp(mtime):%Y%m%d-%H%M}"
    for i in range(1, 1000):
        candidate = os.path.join(folder, (base if i == 1 else f"{base}-{i}") + ext)
        if not os.path.lexists(candidate):
            return candidate
    raise RuntimeError(f"no free conflict name for {path}")


def merge(src, dst, device, counts):
    """Copy src into dst. Per file the newest wins; two different versions both stay."""
    if os.path.isdir(src):
        os.makedirs(dst, exist_ok=True)
        for n in sorted(os.listdir(src)):
            if n not in SKIP:
                merge(os.path.join(src, n), os.path.join(dst, n), device, counts)
        return
    if not os.path.lexists(dst):
        shutil.copy2(src, dst)
        counts["copied"] += 1
        return
    if filecmp.cmp(src, dst, shallow=False):
        return
    if os.path.getmtime(src) > os.path.getmtime(dst):
        keep = conflict_name(dst, os.path.getmtime(dst), device)
        os.rename(dst, keep)
        shutil.copy2(src, dst)
    else:
        keep = conflict_name(dst, os.path.getmtime(src), device)
        shutil.copy2(src, keep)
    log(f"conflict: {os.path.relpath(dst, ICLOUD)} differs; kept {os.path.basename(keep)}")
    counts["conflicts"] += 1


def backup(game, root, names):
    os.makedirs(BACKUPS, exist_ok=True)
    out = os.path.join(BACKUPS, f"{game.name}-{datetime.datetime.now():%Y%m%d-%H%M%S}.tar.gz")
    with tarfile.open(out, "w:gz") as tar:
        for n in names:
            p = os.path.join(root, n)
            if os.path.exists(p) and not os.path.islink(p):
                tar.add(p, arcname=n)
    return out


# --- commands --------------------------------------------------------------------

def check(game, changing):
    if not game.saves:
        sys.exit(f"{game.name}: no saves block in its profile (recomp/profiles), so save sync is not available")
    if changing and running(game):
        sys.exit(f"Quit {game.name} first: its save files are about to move.")


def enable(game):
    check(game, True)
    cloud = icloud_game(game)
    names = include(game)
    root = mac_root(game, create=True)
    if not root:
        sys.exit(f"{game.name} has no save folder on this Mac yet ({game.saves['mac']}). Start the game once and "
                 "save, then try again.")
    todo = [n for n in names if not (os.path.islink(os.path.join(root, n)) and
                                     os.path.realpath(os.path.join(root, n)) == os.path.realpath(os.path.join(cloud, n)))]
    out = {"backup": None, "copied": 0, "conflicts": 0}
    if todo:
        out["backup"] = backup(game, root, todo)
        log(f"backup: {out['backup']}")
    os.makedirs(cloud, exist_ok=True)
    device = device_name()
    for n in todo:
        local, remote = os.path.join(root, n), os.path.join(cloud, n)
        if os.path.islink(local):
            sys.exit(f"{local} is a link to {os.readlink(local)}, not to iCloud Drive: move it back by hand first")
        if os.path.exists(local):
            if not os.path.lexists(remote) and os.stat(local).st_dev == os.stat(cloud).st_dev:
                os.rename(local, remote)
            else:
                merge(local, remote, device, out)
                shutil.rmtree(local) if os.path.isdir(local) else os.remove(local)
        elif not os.path.lexists(remote):
            os.makedirs(remote)  # entries missing on both sides are taken to be folders
        os.symlink(remote, local)
        log(f"{n}: {local} -> {remote}")
    return status(game, out)


def disable(game):
    check(game, True)
    root = mac_root(game)
    for n in include(game) if root else []:
        local = os.path.join(root, n)
        if not os.path.islink(local):
            continue
        target = os.path.realpath(local)
        tmp = local + ".recomp-tmp"
        if os.path.lexists(tmp):
            shutil.rmtree(tmp) if os.path.isdir(tmp) and not os.path.islink(tmp) else os.remove(tmp)
        if os.path.isdir(target):
            shutil.copytree(target, tmp, ignore=shutil.ignore_patterns(*SKIP))
        elif os.path.exists(target):
            shutil.copy2(target, tmp)
        os.remove(local)
        if os.path.lexists(tmp):
            os.rename(tmp, local)
        log(f"{n}: copied back from {target} (the iCloud Drive copy stays)")
    return status(game)


def status(game, extra=None):
    out = {"game": game.name, "supported": bool(game.saves), "icloud": os.path.isdir(ICLOUD), "enabled": False,
           "root": None, "cloud": None, "entries": [], "last_change": None}
    if not game.saves:
        return out
    root = mac_root(game)
    cloud = os.path.join(ICLOUD, FOLDER, game.name)
    out["root"], out["cloud"] = root, cloud
    linked = 0
    for n in game.saves.get("include", []):
        local = os.path.join(root, n) if root else None
        if local and os.path.islink(local):
            target = os.path.realpath(local)
            state = "linked" if target == os.path.realpath(os.path.join(cloud, n)) else "linked elsewhere"
            linked += state == "linked"
        elif local and os.path.exists(local):
            state = "on this Mac"
        else:
            state = "missing"
        t = newest(local) if local and os.path.exists(local) else 0
        out["entries"].append({"name": n, "state": state, "last_change": iso(t)})
    out["enabled"] = bool(root) and linked == len(out["entries"])
    times = [e["last_change"] for e in out["entries"] if e["last_change"]]
    out["last_change"] = max(times) if times else None
    out.update(extra or {})
    return out


def show(st):
    if not st["supported"]:
        print(f"{st['game']}: save sync is not available (no saves block in its profile)")
        return
    print(f"{st['game']}: save sync with iCloud Drive is {'on' if st['enabled'] else 'off'}")
    print(f"  saves:       {st['root'] or '(no save folder yet)'}")
    print(f"  iCloud Drive: {st['cloud']}" + ("" if st["icloud"] else " (iCloud Drive is off on this Mac)"))
    for e in st["entries"]:
        print(f"  {e['name']:<20} {e['state']:<16} last change {e['last_change'] or '-'}")
    if st.get("backup"):
        print(f"  backup:      {st['backup']}")
    if st.get("copied") or st.get("conflicts"):
        print(f"  merged:      {st['copied']} files copied to iCloud Drive, {st['conflicts']} conflicts kept as copies")
