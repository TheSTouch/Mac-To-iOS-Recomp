#!/usr/bin/env python3
"""macToiOSRecomp - port macOS games to iOS (iPhone and iPad).

  recomp.py inspect <Game.app>... [--json]           triage: engine, archs, porting route
  recomp.py scan [--extra DIR]... [--json]           find installed games and their support status
  recomp.py env [--json]                             build tools, signing teams, connected devices
  recomp.py toolchain <Game.app> [--check]           fetch (or check for) the Unity editor + iOS support that game needs
  recomp.py unity <Game.app> [stages] [options]      Unity/Mono route (IL2CPP recompilation)
  recomp.py unreal <Game.app> [stages] [options]     Unreal Engine 4 route (arm64 binary retarget)
  recomp.py saves <Game.app> --enable|--disable|--status|--sync [--json]
  recomp.py saves --sync-all                         share a Mac game's saves with its iOS ports via iCloud Drive
  recomp.py mods <Game.app> [--include ID]... [--exclude ID]... [--json]
                                                     the Mac's mods and what the next port does with each;
                                                     --include/--exclude choose which ones it compiles in
  recomp.py mods <Game.app> --device NAME|UDID [--bundle-id ID] [--all]
                                                     copy the last port's mods to the device's mod folder
                                                     (the unity route's install stage does this too)

Unity stages, in order (default: all): prepare player inject xcode install
Unreal stages, in order (default: all): prepare xcode install
Options: --team TEAMID  --bundle-id ID  --device NAME|UDID  --work DIR  --unity DIR
         --saves icloud|off         for a game without Steam: its saves sync through iCloud Drive
                                    (recomp.py saves; the default when its profile has a saves
                                    block) or stay on the device. A Steam game's port syncs with
                                    Steam Cloud through its Steam client, with no choice.
The bundle ID defaults to Recomp Helper's, recomp.<team>.<game>, so a port installs over the last one.

Large files (Unity editors, build output) go under $RECOMP_HOME, default this folder.
Set RECOMP_EVENTS=1 for machine-readable progress lines (used by the Mac app).
"""
import argparse
import json
import os
import sys
import traceback

ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, ROOT)

from recomp import events, paths, storage  # noqa: E402

STAGES = ["prepare", "player", "inject", "xcode", "install"]
UNREAL_STAGES = ["prepare", "xcode", "install"]


def default_bundle_id(game, team):
    """The bundle ID Recomp Helper uses too, so every port of a game installs over the last one."""
    if team:
        return f"recomp.{team.lower()}.{game.slug.lower()}"
    return f"local.recomp.{game.slug.lower()}"


def last_bundle_id(game, work):
    """The bundle ID of the last port built in work (the installed app's), else the default."""
    import glob
    import plistlib
    for info in glob.glob(os.path.join(work, "DerivedData", "Build", "Products", "*-iphoneos", "*.app", "Info.plist")):
        with open(info, "rb") as f:
            return plistlib.load(f)["CFBundleIdentifier"]
    return default_bundle_id(game, None)


def cmd_scan(rest):
    from recomp import discover
    p = argparse.ArgumentParser(prog="recomp.py scan")
    p.add_argument("--extra", action="append", default=[])
    p.add_argument("--json", action="store_true")
    a = p.parse_args(rest)
    games = discover.scan(a.extra)
    from recomp import saves
    for g in games:
        g["saves"] = g.get("status") != "missing" and saves.has_saves(g["app"])
        g["steamCloud"] = g.get("status") != "missing" and g.get("route") in ("unity", "unreal") and steam_cloud(g["app"])
        g["steam"] = g.get("status") != "missing" and g.get("route") in ("unity", "unreal") and steam_game(g["app"])
        g["mods"] = g.get("status") != "missing" and g.get("route") == "unity" and has_mods(g["app"])
    if a.json:
        print(json.dumps(games))
    else:
        for g in sorted(games, key=lambda g: (g["status"], g["name"].lower())):
            print(f"{g['status']:<12} {g['name']:<32} {g['engine']:<28} {g['source']}")
    return 0


def steam_cloud(app):
    """Whether the game's port syncs with Steam Cloud (recomp/steam_cloud.py)."""
    from recomp import saves
    try:
        return saves.default_mode(saves.Game(app)) == "steam"
    except (SystemExit, Exception):
        return False


def steam_game(app):
    """Whether the game is a Steam game: its port runs the Steam runtime, and its saves have no choice."""
    from recomp import saves
    try:
        return saves.steam_game(saves.Game(app))
    except (SystemExit, Exception):
        return False


def saves_mode(game, profile, chosen, log):
    """The port's save sync (a Steam game's is fixed; --saves, else the default, for others), kept
    on the game for the Info.plist writers and recorded for `recomp.py saves --status` and Recomp Helper."""
    from recomp import saves, steam_cloud
    game.saves_mode = steam_cloud.port_mode(game.app, profile, chosen, log)
    saves.record_mode(game.name, game.saves_mode)
    log(f"saves: {saves.MODE_NAMES[game.saves_mode]}" + ("" if chosen else " (the default for this game)"))


def has_mods(app):
    """Whether the game's profile says where its mods live (recomp/mods.py)."""
    from recomp import unity_ios as u
    try:
        return bool((u.game_profile(u.Game(app)) or {}).get("mods"))
    except (SystemExit, OSError, KeyError, ValueError):
        return False


def cmd_env(rest):
    from recomp import discover
    env = discover.environment()
    env["home"] = paths.HOME
    print(json.dumps(env) if "--json" in rest else json.dumps(env, indent=2))
    return 0


def cmd_toolchain(rest):
    from recomp import toolchain, unity_ios
    p = argparse.ArgumentParser(prog="recomp.py toolchain")
    p.add_argument("app")
    p.add_argument("--check", action="store_true")
    a = p.parse_args(rest)
    game = unity_ios.Game(a.app)
    if a.check:
        print(json.dumps({"version": game.unity_version, "installed": toolchain.installed(game.unity_version),
                          "path": os.path.join(paths.TOOLCHAIN, f"Unity-{game.unity_version}")}))
        return 0
    events.stage("toolchain", "start")
    toolchain.install(game.unity_version, game.changeset)
    events.stage("toolchain", "done")
    return 0


def cmd_unity(rest):
    from recomp import unity_ios as u
    p = argparse.ArgumentParser(prog="recomp.py unity")
    p.add_argument("app")
    p.add_argument("stages", nargs="*")
    p.add_argument("--team", required=True)
    p.add_argument("--bundle-id")
    p.add_argument("--device")
    p.add_argument("--work")
    p.add_argument("--unity")
    p.add_argument("--saves", choices=["steam", "icloud", "off"])
    a = p.parse_args(rest)
    bad = [s for s in a.stages if s not in STAGES]
    if bad:
        p.error(f"unknown stage(s) {bad}; choose from {STAGES}")
    game = u.Game(a.app)
    work = os.path.abspath(a.work or os.path.join(paths.BUILD, game.slug))
    os.makedirs(work, exist_ok=True)
    bundle_id = a.bundle_id or default_bundle_id(game, a.team)
    stages = a.stages or STAGES
    if "install" in stages and not a.device:
        sys.exit("install needs --device (see: recomp.py env)")
    if "install" in stages and stages != ["install"]:
        storage.check_port(a.device, game.app)
    unity, ios = u.editor_paths(game.unity_version, a.unity)
    if "player" in stages:
        saves_mode(game, u.game_profile(game), a.saves, u.log)
    u.log(f"{game.name}: Unity {game.unity_version} -> {work}")
    for s in STAGES:
        if s not in stages:
            continue
        events.stage(s, "start")
        try:
            if s == "prepare":
                u.prepare(game, work, unity, ios)
            elif s == "player":
                u.player(game, work, unity, bundle_id, a.team)
            elif s == "inject":
                u.inject(game, work)
            elif s == "xcode":
                u.xcode(work, a.team)
            elif s == "install":
                u.install(work, a.device)
                u.push_mods(game, work, a.device, bundle_id)
        except BaseException as e:
            events.stage(s, "failed")
            if not isinstance(e, SystemExit):
                traceback.print_exc()
            raise
        events.stage(s, "done")
    return 0


def cmd_unreal(rest):
    from recomp import unreal_ios as u
    p = argparse.ArgumentParser(prog="recomp.py unreal")
    p.add_argument("app")
    p.add_argument("stages", nargs="*")
    p.add_argument("--team")
    p.add_argument("--bundle-id")
    p.add_argument("--device")
    p.add_argument("--work")
    p.add_argument("--saves", choices=["steam", "icloud", "off"])
    a = p.parse_args(rest)
    bad = [s for s in a.stages if s not in UNREAL_STAGES]
    if bad:
        p.error(f"unknown stage(s) {bad}; choose from {UNREAL_STAGES}")
    game = u.Game(a.app)
    work = os.path.abspath(a.work or os.path.join(paths.BUILD, game.slug))
    os.makedirs(work, exist_ok=True)
    bundle_id = a.bundle_id or default_bundle_id(game, a.team)
    stages = a.stages or UNREAL_STAGES
    if "xcode" in stages and not a.team:
        sys.exit("xcode needs --team (see: recomp.py env)")
    if "install" in stages and not a.device:
        sys.exit("install needs --device (see: recomp.py env)")
    if "install" in stages and stages != ["install"]:
        storage.check_port(a.device, game.app)
    u.log(f"{game.name}: Unreal ({', '.join(game.projects)}) -> {work}")
    if "xcode" in stages:
        saves_mode(game, game.profile, a.saves, u.log)
    for s in UNREAL_STAGES:
        if s not in stages:
            continue
        events.stage(s, "start")
        try:
            if s == "prepare":
                u.prepare(game, work)
            elif s == "xcode":
                u.xcode(game, work, a.team, bundle_id)
            elif s == "install":
                u.install(work, a.device)
        except BaseException as e:
            events.stage(s, "failed")
            if not isinstance(e, SystemExit):
                traceback.print_exc()
            raise
        events.stage(s, "done")
    return 0


def cmd_saves(rest):
    from recomp import saves
    p = argparse.ArgumentParser(prog="recomp.py saves")
    p.add_argument("app", nargs="?")
    g = p.add_mutually_exclusive_group(required=True)
    for flag in ("--enable", "--disable", "--status", "--sync", "--sync-all"):
        g.add_argument(flag, action="store_true")
    p.add_argument("--json", action="store_true")
    a = p.parse_args(rest)
    if a.sync_all:
        return saves.sync_all()
    if not a.app:
        p.error("which game? (the path of its .app)")
    game = saves.Game(a.app)
    action = saves.enable if a.enable else saves.disable if a.disable else saves.sync_now if a.sync else saves.status
    st = action(game)
    if a.json:
        print(json.dumps(st))
    else:
        saves.show(st)
    return 0


def cmd_mods(rest):
    from recomp import mods, unity_ios as u
    p = argparse.ArgumentParser(prog="recomp.py mods")
    p.add_argument("app")
    p.add_argument("--include", action="append", default=[], metavar="ID", help="put this mod in the next port")
    p.add_argument("--exclude", action="append", default=[], metavar="ID", help="leave this mod out of the next port")
    p.add_argument("--device", help="copy the last port's mods to this iPhone or iPad")
    p.add_argument("--bundle-id")
    p.add_argument("--work")
    p.add_argument("--unity")
    p.add_argument("--all", action="store_true", help="with --device: also copy mods whose code was not compiled in")
    p.add_argument("--json", action="store_true")
    a = p.parse_args(rest)
    game = u.Game(a.app)
    work = os.path.abspath(a.work or os.path.join(paths.BUILD, game.slug))
    if a.include or a.exclude:
        mods.select(work, a.include, a.exclude)
    try:
        with open(os.path.join(work, "prepare.json")) as f:
            last = {m["folder"]: m for m in json.load(f).get("mods", [])}
    except (OSError, ValueError):
        last = {}
    if a.device:
        # What the installed app holds is what the last port compiled, not what is planned.
        if not os.path.exists(os.path.join(work, "prepare.json")):
            sys.exit(f"no port of {game.name} in {work} yet: port the game first")
        u.push_mods(game, work, a.device, a.bundle_id or last_bundle_id(game, work), a.all)
        return 0
    cfg, found = u.plan_mods(game, work, a.unity)
    if a.json:
        print(json.dumps({
            "supported": cfg is not None,
            "folders": [r for s, r in mods.mac_roots(cfg) if s != mods.BUILTIN] if cfg else [],
            "ios": cfg.get("ios") if cfg else None,
            "mods": [{"id": m["id"], "name": m["name"], "version": m.get("version", ""), "source": m["source"],
                      "folder": m["folder"], "status": m["status"], "reason": m.get("reason"),
                      "description": m.get("description"),
                      "selected": m["status"] != "excluded", "harmony": bool(m.get("patcher")),
                      "lastPort": last.get(m["folder"], {}).get("status")} for m in found],
        }))
        return 0
    if cfg is None:
        sys.exit(f"{game.name}: its profile declares no mod folders")
    mods.report(found, u.log)
    return 0


COMMANDS = {"mods": cmd_mods, "scan": cmd_scan, "saves": cmd_saves, "env": cmd_env, "toolchain": cmd_toolchain, "unity": cmd_unity, "unreal": cmd_unreal}


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    cmd, rest = sys.argv[1], sys.argv[2:]
    if cmd == "inspect":
        import inspect_app
        return inspect_app.main(rest)
    if cmd in COMMANDS:
        return COMMANDS[cmd](rest)
    print(__doc__.strip())
    return 2


if __name__ == "__main__":
    sys.exit(main())
