# macToiOSRecomp

Port macOS games you own to your own iPad. Builds are for personal sideloading
with your developer account; never share the resulting app, since it contains the game.

## Recomp Helper (Mac app)

Download the notarized DMG from [Releases](../../releases), or build it yourself (below).
The app:

1. scans Steam libraries, `/Applications`, `~/Applications`, GOG, Epic, itch and Heroic folders,
   plus any folders you add;
2. sorts what it finds into *Supported*, *Not yet supported*, *Not supported* and *Not installed*,
   with the reason for each game;
3. for a supported game, asks up front for everything it needs (iPad, signing team, bundle ID,
   where to keep the ~40 GB workspace, permission to download the matching Unity editor),
   then runs the whole port with progress bars, a live log and plain-language hints when
   something needs your attention (unlock the iPad, sign in to Xcode, …).

Requirements: an Apple Silicon or Intel Mac on macOS 14+, Xcode with the iOS SDK, the
.NET SDK (`brew install dotnet`), an Apple Developer account signed in to Xcode, a free
Unity Personal license (open Unity Hub once and sign in), and an iPad paired with the Mac.

## Command line

```
python3 recomp.py scan                       # installed games and their support status
python3 recomp.py inspect /path/to/Game.app  # detailed triage of one bundle
python3 recomp.py env                        # build tools, signing teams, paired devices
```

Set `RECOMP_HOME` to put the large files (Unity editors, build output) on another disk.

`inspect` reports the engine, CPU architectures, Mac-only frameworks and which route applies:

| Route | Games | How |
|---|---|---|
| **Unity / Mono** (implemented) | Unity games whose `Data/Managed` holds .NET assemblies | Recompile the game's assemblies to native ARM64 code with the matching Unity version's IL2CPP, then run the game's own data on Unity's iOS player |
| Mach-O retarget (planned) | Native arm64 games (Unreal, custom engines) | Re-mark the binaries as iOS, redirect Mac-only imports to shim frameworks |
| Engine runtime swap (planned) | Godot, Ren'Py, LÖVE, HTML5 | Run the game's data on the engine's iOS runtime |
| Static recompilation | Intel-only games | Per-game project; iPadOS forbids JIT, so no Rosetta-style translation |

## Unity route

```
python3 recomp.py toolchain <Game.app>        # fetch that exact Unity version + iOS support into toolchain/
python3 recomp.py unity <Game.app> --team <TEAMID> --bundle-id <id> --device <iPad name or UDID>
```

Stages (run all, or name some): `prepare player inject xcode install`.

1. **prepare**: a shell Unity project in `build/<Game>/shell` gets every game-owned
   assembly as an iOS-only plugin (engine and class-library assemblies come from Unity's
   iOS player instead). P/Invokes into libraries iOS lacks (Steamworks) are redirected to
   `__Internal` and a generated C stub (`stubs/*.overrides.c` for functions where 0 is the
   wrong answer). Managed shims from `recomp/shims` are added (touch → virtual mouse).
2. **player**: the matching editor builds the shell for iOS in batchmode, which runs IL2CPP
   over all of it and writes an Xcode project.
3. **inject**: the shell's data is replaced with the game's (`StreamingAssets` → `Data/Raw`);
   IL2CPP metadata and the iOS default resources stay; serialized files are retargeted to iOS;
   shims are registered in `RuntimeInitializeOnLoads.json`.
4. **xcode** / **install**: sign with automatic provisioning and install through `devicectl`.

## Touch controls (Recomp.TouchMouse)

| Gesture | Mouse |
|---|---|
| 1 finger tap / drag | left click / drag |
| 2 finger drag | middle drag |
| pinch | scroll wheel |
| 3 finger drag | right drag |
| 2 finger tap | right click |

A real keyboard or trackpad, when connected, works alongside.

## Building the app

```
scripts/build-app.sh                                     # local, ad-hoc signed, in dist/
SIGN_ID="Developer ID Application: <name> (<TEAMID>)" NOTARY_PROFILE=<profile> scripts/build-app.sh
```

The second form signs with the hardened runtime, builds a DMG, notarizes and staples it.
Create the notary profile once with
`xcrun notarytool store-credentials <profile> --apple-id <apple-id> --team-id <TEAMID>`.
The app bundles the engine from `git archive HEAD`, so only committed files ship.
`swift scripts/make-icon.swift` regenerates the icon.

## Contributing

This repository is public. Never commit game files or personal details: enable the guard
once per clone with `git config core.hooksPath .githooks`, and list your own private
strings (name, email, team ID, device names) as regexes in `.git/private-patterns`, which
stays on your machine.

## Layout

- `recomp.py`: CLI
- `app/`: Recomp Helper, the SwiftUI front end (talks to `recomp.py` through `RECOMP_EVENTS=1` progress lines)
- `scripts/`: app build, signing, notarization and icon
- `recomp/discover.py`: game scanning and environment checks; `recomp/events.py`: progress events and failure hints
- `recomp/unity_ios.py`, `recomp/toolchain.py`, `recomp/unity_editor/`: Unity route
- `recomp/shims/`: managed shims injected into games
- `stubs/`: hand-written native stub overrides
- `tools/inspect_app.py`: triage; `tools/asmtool`: assembly scan/rewrite (Mono.Cecil); `tools/ilspy.sh`: decompiler
- `toolchain/`, `build/`: downloaded editors and per-game work (not in git)
