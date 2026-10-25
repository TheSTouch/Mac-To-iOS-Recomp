#!/usr/bin/env python3
"""macToiOSRecomp - port macOS games to iPadOS.

  recomp.py inspect <Game.app>...                 triage: engine, archs, porting route
  recomp.py unity <Game.app> [stages] [options]   Unity/Mono route (IL2CPP recompilation)
  recomp.py toolchain <Game.app>                  fetch the Unity editor + iOS support that game needs

Unity stages, in order (default: all): prepare player inject xcode install
Options: --team TEAMID  --bundle-id ID  --device NAME|UDID  --work DIR  --unity DIR
"""
import argparse
import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, ROOT)

STAGES = ["prepare", "player", "inject", "xcode", "install"]


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    cmd, rest = sys.argv[1], sys.argv[2:]
    if cmd == "inspect":
        import inspect_app
        return inspect_app.main(rest)
    if cmd == "toolchain" and len(rest) == 1:
        from recomp import toolchain, unity_ios
        game = unity_ios.Game(rest[0])
        toolchain.install(game.unity_version, game.changeset)
        return 0
    if cmd == "unity":
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
        work = os.path.abspath(a.work or os.path.join(ROOT, "build", game.slug))
        os.makedirs(work, exist_ok=True)
        bundle_id = a.bundle_id or f"local.recomp.{game.slug.lower()}"
        stages = a.stages or STAGES
        unity, ios = u.editor_paths(game.unity_version, a.unity)
        u.log(f"{game.name}: Unity {game.unity_version} -> {work}")
        for s in STAGES:
            if s not in stages:
                continue
            if s == "prepare":
                u.prepare(game, work, unity, ios)
            elif s == "player":
                u.player(game, work, unity, bundle_id, a.team)
            elif s == "inject":
                u.inject(game, work)
            elif s == "xcode":
                u.xcode(work, a.team)
            elif s == "install":
                if not a.device:
                    sys.exit("install needs --device (see: xcrun devicectl list devices)")
                u.install(work, a.device)
        return 0
    print(__doc__.strip())
    return 2


if __name__ == "__main__":
    sys.exit(main())
