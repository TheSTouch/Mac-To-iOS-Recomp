#!/usr/bin/env python3
"""macToiOSRecomp - port macOS games to iPadOS.

  recomp.py inspect <Game.app>... [--json]           triage: engine, archs, porting route
  recomp.py scan [--extra DIR]... [--json]           find installed games and their support status
  recomp.py env [--json]                             build tools, signing teams, connected devices
  recomp.py toolchain <Game.app> [--check]           fetch (or check for) the Unity editor + iOS support that game needs
  recomp.py unity <Game.app> [stages] [options]      Unity/Mono route (IL2CPP recompilation)
  recomp.py unreal <Game.app> [stages] [options]     Unreal Engine 4 route (arm64 binary retarget)
  recomp.py saves <Game.app> --enable|--disable|--status [--json]
                                                     sync the Mac game's saves with its iOS port via iCloud Drive

Unity stages, in order (default: all): prepare player inject xcode install
Unreal stages, in order (default: all): prepare xcode install
Options: --team TEAMID  --bundle-id ID  --device NAME|UDID  --work DIR  --unity DIR

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

from recomp import events, paths  # noqa: E402

STAGES = ["prepare", "player", "inject", "xcode", "install"]
UNREAL_STAGES = ["prepare", "xcode", "install"]


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
    if a.json:
        print(json.dumps(games))
    else:
        for g in sorted(games, key=lambda g: (g["status"], g["name"].lower())):
            print(f"{g['status']:<12} {g['name']:<32} {g['engine']:<28} {g['source']}")
    return 0


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
    a = p.parse_args(rest)
    bad = [s for s in a.stages if s not in STAGES]
    if bad:
        p.error(f"unknown stage(s) {bad}; choose from {STAGES}")
    game = u.Game(a.app)
    work = os.path.abspath(a.work or os.path.join(paths.BUILD, game.slug))
    os.makedirs(work, exist_ok=True)
    bundle_id = a.bundle_id or f"local.recomp.{game.slug.lower()}"
    stages = a.stages or STAGES
    if "install" in stages and not a.device:
        sys.exit("install needs --device (see: recomp.py env)")
    unity, ios = u.editor_paths(game.unity_version, a.unity)
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
    a = p.parse_args(rest)
    bad = [s for s in a.stages if s not in UNREAL_STAGES]
    if bad:
        p.error(f"unknown stage(s) {bad}; choose from {UNREAL_STAGES}")
    game = u.Game(a.app)
    work = os.path.abspath(a.work or os.path.join(paths.BUILD, game.slug))
    os.makedirs(work, exist_ok=True)
    bundle_id = a.bundle_id or f"local.recomp.{game.slug.lower()}"
    stages = a.stages or UNREAL_STAGES
    if "xcode" in stages and not a.team:
        sys.exit("xcode needs --team (see: recomp.py env)")
    if "install" in stages and not a.device:
        sys.exit("install needs --device (see: recomp.py env)")
    u.log(f"{game.name}: Unreal ({', '.join(game.projects)}) -> {work}")
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
    p.add_argument("app")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--enable", action="store_true")
    g.add_argument("--disable", action="store_true")
    g.add_argument("--status", action="store_true")
    p.add_argument("--json", action="store_true")
    a = p.parse_args(rest)
    game = saves.Game(a.app)
    st = saves.enable(game) if a.enable else saves.disable(game) if a.disable else saves.status(game)
    if a.json:
        print(json.dumps(st))
    else:
        saves.show(st)
    return 0


COMMANDS = {"scan": cmd_scan, "saves": cmd_saves, "env": cmd_env, "toolchain": cmd_toolchain, "unity": cmd_unity, "unreal": cmd_unreal}


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
