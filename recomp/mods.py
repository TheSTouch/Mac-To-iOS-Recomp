"""Mods for Unity ports: the code of the mods installed on the Mac, compiled into the app.

iOS has no JIT, so a mod's DLL only runs on the iPad when IL2CPP compiled it at
port time. A game profile's "mods" block says where the game keeps its mods:

  "mods": {
    "mac": ["~/Documents/Game/Mods", "steam-workshop:<appid>"],
    "ios": "Documents/Game/Mods",            # on the iPad, relative to the app container
    "manifest": "manifest.json",             # a folder holding one is a mod
    "version_dirs": "version-",              # optional: per-game-version subfolders
    "exclude": [".git", "src", "*.zip"],     # not copied to the iPad by `recomp.py mods`
    "builtin": ["timberborn/TheSTouchscreen"],   # optional: mods of the port itself (recomp/builtin_mods)
    "enabled_pref": "ModEnabled.Local.{folder}.{id}"  # optional: the PlayerPrefs key that says whether a
                                             # mod is on ({folder}: its folder on the iPad, {id}: its Id)
  }

Built-in mods are part of every port of the game: built at port time against the game and
the port's shims, laid out in work/builtin-mods like a mod on the Mac (source "Built in"),
then checked, compiled in and copied to the iPad like the others. The player can still
leave one out of a port, but not turn it off in the game: given "enabled_pref", the port sets
each built-in mod's key to on at every launch (recomp.json "builtinModPrefs", Recomp.BuiltinMods).

prepare() picks the DLLs the game would load, checks each one against the iOS class
library and the game (asmtool check), and returns the assemblies to compile in. The
player chooses which mods go into a port (`recomp.py mods --exclude/--include`, or the
Mods box in Recomp Helper): the choice is kept in the game's work folder as
mods-selection.json, {"excluded": [mod ids]}, so mods installed later are included. At
run time the libil2cpp patch (il2cpp_patches.py) maps the game's Assembly.Load(bytes)
of each DLL, by SHA-256, to its compiled assembly, and hides a mod's assemblies from
AppDomain.GetAssemblies until then, so a disabled or absent mod stays inactive.
A mod added or changed on the iPad without porting again cannot run its code.
"""
import fnmatch
import json
import os
import re
import shutil
import subprocess

# Libraries that patch code at run time: never compiled in (IL2CPP cannot run them,
# and their bundled internals do not resolve). A mod using one is reported as such,
# unless the port has a stand-in for it: Harmony ("0Harmony") is replaced by
# recomp/shims/RecompHarmony, and the mods' [HarmonyPatch] classes are woven into the
# game at port time (asmtool harmony).
RUNTIME_PATCHERS = {"0Harmony", "MonoMod.Core", "MonoMod.Utils", "MonoMod.RuntimeDetour"}

BUILTIN = "Built in"  # the source of the port's own mods


def config(profile):
    return (profile or {}).get("mods")


def mac_roots(cfg):
    """The folders on this Mac that hold the game's mods, one per mod inside."""
    from recomp import discover
    roots = []
    for entry in cfg.get("mac", []):
        if entry.startswith("steam-workshop:"):
            appid = entry.split(":", 1)[1]
            for common in discover.steam_libraries():
                roots.append(("Steam Workshop", os.path.join(os.path.dirname(common), "workshop", "content", appid)))
        else:
            roots.append(("Local", os.path.expanduser(entry)))
    if cfg.get("builtin_dir"):
        roots.append((BUILTIN, cfg["builtin_dir"]))
    return [(source, r) for source, r in roots if os.path.isdir(r)]


def version_key(text):
    return tuple(int(n) for n in re.findall(r"\d+", text)[:4]) or (0,)


def pick_version_dir(folder, prefix, game_version):
    """The subfolder the game loads: the highest "<prefix><v>" not newer than the game."""
    if not prefix:
        return folder
    subs = [n for n in os.listdir(folder) if n.startswith(prefix) and os.path.isdir(os.path.join(folder, n))]
    if not subs:
        return folder
    current = version_key(game_version)
    fits = [n for n in subs if not n[len(prefix):] or version_key(n[len(prefix):]) <= current]
    if not fits:
        return None
    return os.path.join(folder, max(fits, key=lambda n: version_key(n[len(prefix):]) if n[len(prefix):] else current))


def read_manifest(path):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def find(cfg, game_version):
    """Every mod on the Mac: {name, id, source, folder, dir (the version folder the game loads), dlls}."""
    manifest = cfg.get("manifest", "manifest.json")
    found = []
    for source, root in mac_roots(cfg):
        for n in sorted(os.listdir(root)):
            folder = os.path.join(root, n)
            if not os.path.isdir(folder) or n.startswith("."):
                continue
            chosen = pick_version_dir(folder, cfg.get("version_dirs"), game_version)
            mod = {"folder": folder, "source": source, "dir": chosen, "dlls": []}
            info = read_manifest(os.path.join(chosen, manifest)) if chosen else None
            if not chosen:
                mod.update(name=n, id=n, status="skipped", reason=f"no version folder fits game {game_version}")
            elif not info or not info.get("Id"):
                continue  # not a mod
            else:
                mod.update(name=info.get("Name") or n, id=info["Id"], version=info.get("Version", ""),
                           description=info.get("Description", ""))
                for dirpath, dirnames, files in os.walk(chosen):
                    dirnames[:] = [d for d in dirnames if not d.startswith(".")]
                    mod["dlls"] += sorted(os.path.join(dirpath, f) for f in files if f.lower().endswith(".dll"))
            found.append(mod)
    return found


SELECTION = "mods-selection.json"


def excluded(work):
    try:
        with open(os.path.join(work, SELECTION)) as f:
            return set(json.load(f).get("excluded", []))
    except (OSError, ValueError):
        return set()


def select(work, include=(), exclude=()):
    """Turn mods on or off for the next port; returns the excluded ids."""
    out = (excluded(work) | set(exclude)) - set(include)
    os.makedirs(work, exist_ok=True)
    with open(os.path.join(work, SELECTION), "w") as f:
        json.dump({"excluded": sorted(out)}, f, indent=2)
    return out


def check(asmtool, dlls, search):
    """asmtool check of each DLL: path -> {name, version, sha256, references, unresolved}."""
    if not dlls:
        return {}
    cmd = [asmtool, "check"]
    for d in search:
        cmd += ["--search", d]
    out = subprocess.run(cmd + dlls, capture_output=True, text=True, check=True).stdout
    return {r["path"]: r for r in map(json.loads, out.splitlines())}


def prepare(cfg, game_version, asmtool, search, existing, stand_ins=None, skip=()):
    """Decide which mod assemblies to compile in.

    search: folders resolving references, AOT class library first, then the game.
    existing: assembly names (no .dll) the port already compiles (game and engine).
    stand_ins: {assembly name: path} compiled instead of a mod's copy (and resolved
    against, so a mod calling an API the stand-in lacks is reported).
    skip: ids of mods the player left out of this port (status "excluded").
    Returns (mods, assemblies): mods for prepare.json, with "status" ("compiled",
    "data only" or "skipped") and "reason"; assemblies maps a name to
    {"path", "hashes"}, every SHA-256 the game may present for that name.
    """
    stand_ins = stand_ins or {}
    mods = find(cfg, game_version)
    for m in mods:
        if m["id"] in skip and not m.get("status"):
            m.update(status="excluded", reason="left out of this port")
            m["dlls"] = []
    dlls = [d for m in mods for d in m["dlls"]]
    # A mod may use another mod's assemblies: let them resolve against each other.
    search = search + sorted({os.path.dirname(p) for p in stand_ins.values()}) + sorted({os.path.dirname(d) for d in dlls})
    results = check(asmtool, dlls, search)
    names = {}
    for m in mods:
        if m.get("status"):
            continue
        m["assemblies"] = []
        for d in m["dlls"]:
            r = results.get(d, {})
            if r.get("error"):
                m.update(status="skipped", reason=f"{os.path.basename(d)}: {r['error']}")
                break
            m["assemblies"].append(r)
            names.setdefault(r["name"], []).append((m, r))
        if not m.get("status"):
            m["status"] = "compiled" if m["dlls"] else "data only"

    # Drop mods that cannot compile until the rest stands on its own.
    def fail(m, reason):
        m.update(status="skipped", reason=reason)
    while True:
        provided = {r["name"] for m in mods if m["status"] == "compiled" for r in m["assemblies"]} | set(stand_ins)
        changed = False
        for m in mods:
            if m["status"] != "compiled":
                continue
            for r in m["assemblies"]:
                patcher = sorted((RUNTIME_PATCHERS - set(stand_ins)) & set(r["references"]))
                missing = [ref for ref in r["references"] if ref in names and ref not in provided]
                if r["name"] in stand_ins:
                    continue
                if r["name"] in RUNTIME_PATCHERS:
                    fail(m, f"{os.path.basename(r['path'])} patches code at run time, which iOS does not allow")
                elif patcher:
                    fail(m, f"{os.path.basename(r['path'])} uses {', '.join(patcher)}, which patches code at run time "
                            "(not possible on iOS)")
                elif missing:
                    fail(m, f"needs {', '.join(missing)} from a mod that was skipped")
                elif r["unresolved"] and r["name"] not in existing:
                    shown = "; ".join(r["unresolved"][:3]) + (" ..." if len(r["unresolved"]) > 3 else "")
                    fail(m, f"{os.path.basename(r['path'])} uses {len(r['unresolved'])} types or members this game "
                            f"version does not have (outdated mod?): {shown}")
                else:
                    continue
                changed = True
                break
        if not changed:
            break

    assemblies = {}
    for m in mods:
        if m["status"] != "compiled":
            continue
        for r in m["assemblies"]:
            a = assemblies.setdefault(r["name"], {"path": None, "version": None, "hashes": [], "mods": []})
            a["hashes"].append(r["sha256"])
            a["mods"].append(m["id"])
            # A stand-in or the game's own copy wins; between mods, the highest version.
            if r["name"] in stand_ins:
                a.update(path=stand_ins[r["name"]], version="stand-in")
            elif r["name"] not in existing and (a["version"] is None or version_key(r["version"]) > version_key(a["version"])):
                a.update(path=r["path"], version=r["version"])
        if any(set(stand_ins) & set(r["references"]) for r in m["assemblies"]):
            m["patcher"] = [r["name"] for r in m["assemblies"] if set(stand_ins) & set(r["references"])]
    for m in mods:
        m.pop("assemblies", None)
    return mods, assemblies


def report(mods, log):
    for m in mods:
        line = f"mod {m['name']} ({m['source']}): {m['status']}"
        log(line + (f" - {m['reason']}" if m.get("reason") else ""))
        for p in m.get("patches", []):
            if p["status"] != "woven":
                log(f"    Harmony {p['kind']} {p['patch']}: skipped - {p.get('reason')}")
        woven = sum(1 for p in m.get("patches", []) if p["status"] == "woven")
        if m.get("patches"):
            log(f"    {woven} of {len(m['patches'])} Harmony patches woven into the game")


def weave(asmtool, plugins, search, mods, assemblies):
    """Weave the Harmony patches of the compiled mods that use the stand-in into plugins/."""
    users = sorted({n for m in mods if m["status"] == "compiled" for n in m.get("patcher", [])})
    if not users:
        return
    cmd = [asmtool, "harmony", "--targets", plugins]
    for d in search:
        cmd += ["--search", d]
    out = subprocess.run(cmd + [os.path.join(plugins, n + ".dll") for n in users],
                         capture_output=True, text=True, check=True).stdout
    by_assembly = {}
    for line in out.splitlines():
        if line.startswith("{"):
            p = json.loads(line)
            by_assembly.setdefault(p["mod"], []).append(p)
    for m in mods:
        m["patches"] = [p for n in m.get("patcher", []) for p in by_assembly.get(n, [])]


def copy_filter(cfg):
    patterns = cfg.get("exclude", [])
    return lambda _dir, names: [n for n in names if any(fnmatch.fnmatch(n, p) for p in patterns)]


def ios_folder(name, mod_id):
    """The folder a mod gets on the iPad: its name, made safe for a file name."""
    return re.sub(r'[/:\\"*?<>|]', "_", name).strip() or mod_id


def builtin_enabled_prefs(cfg, builtin_root):
    """The PlayerPrefs key of each built-in mod (cfg "builtin", under builtin_root) that says whether
    the game loads it: cfg "enabled_pref" filled with the mod's folder on the iPad and its Id."""
    pattern = (cfg or {}).get("enabled_pref")
    keys = []
    for rel in (cfg or {}).get("builtin", []) if pattern else []:
        info = read_manifest(os.path.join(builtin_root, rel, cfg.get("manifest", "manifest.json")))
        if info and info.get("Id"):
            keys.append(pattern.format(folder=ios_folder(info.get("Name") or os.path.basename(rel), info["Id"]),
                                       id=info["Id"]))
    return keys


def stage(mods, cfg, out):
    """Copy each mod folder as the iPad should see it (minus "exclude") under out/<name>."""
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    used = set()
    for m in mods:
        name = ios_folder(m["name"], m["id"])
        if name in used:
            name = f"{name} ({m['id']})"
        used.add(name)
        shutil.copytree(m["folder"], os.path.join(out, name), ignore=copy_filter(cfg))
        m["ios_name"] = name
    return mods


def push(mods, cfg, stage_dir, device, bundle_id, log):
    """Copy the mods to the iPad's mod folder (cfg "ios") with devicectl, in one transfer of the
    staged folder. Mods already there that are not in it are kept (added through Files). Not
    --remove-existing-content: devicectl applies it to the whole destination folder."""
    stage(mods, cfg, stage_dir)
    dest = cfg["ios"].rstrip("/")
    log(f"copying {', '.join(m['name'] for m in mods)} to {dest}")
    subprocess.run(["xcrun", "devicectl", "device", "copy", "to", "--device", device,
                    "--domain-type", "appDataContainer", "--domain-identifier", bundle_id,
                    "--source", stage_dir, "--destination", dest], check=True)
