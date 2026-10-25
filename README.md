# macToiOSRecomp

Port macOS games you own to your own iPad. Builds are for personal sideloading
with your developer account; never share the resulting app, since it contains the game.

## Tested games

| Game | Version tested | Engine | Route | Status |
|---|---|---|---|---|
| [Timberborn](https://store.steampowered.com/app/1062090/Timberborn/) | 1.1.2 (Steam) | Unity 6000.5.11f1, Mono | Unity / Mono | **Playable** |
| [Stray](https://store.steampowered.com/app/1332010/Stray/) | 1.5 (Steam) | Unreal Engine 4.27, arm64 | Unreal | **Playable** (early testing) |

Tested on an iPad Pro 11" (M1), iPadOS 26.2.

<table>
<tr>
<td width="25%" align="center"><img src="docs/images/timberborn-ipad.jpg" alt="Timberborn running on an iPad"><br>Timberborn</td>
<td width="25%" align="center"><img src="docs/images/stray-ipad.jpg" alt="Stray running on an iPad, with the on-screen gamepad"><br>Stray</td>
<td width="25%"></td>
<td width="25%"></td>
</tr>
</table>

### Timberborn

Works: intro video, menus, new games and saves, building, camera pan, zoom and rotation.

Known limits:

- the game is designed for a mouse: there is no hover (tooltips, highlight under the cursor),
  and some buttons are small for fingers (raising the in-game UI scale helps);
- the local HTTP API's web pages are disabled ([profile](recomp/profiles/timberborn.json)):
  they compile templates at runtime, which IL2CPP cannot do;
- mods are not supported yet.

### Stray

Works: intro, brightness setup, cutscene videos, sound, gameplay with the on-screen gamepad or a
Bluetooth controller; about 40-50 fps at the iPad's point resolution.

Known limits:

- early testing: only the opening area has been played;
- short freezes the first time a scene appears, while Metal compiles its shaders (they are cached for
  later runs);
- the texture streaming pool is capped to the iPad's memory ([profile](recomp/profiles/stray.json)),
  so distant textures can load later than on a Mac;
- no Steam: achievements and cloud saves are off, saves stay on the iPad.

## Recomp Helper (Mac app)

Download the notarized DMG from [Releases](../../releases), or build it yourself (below).
The app:

1. scans Steam libraries, `/Applications`, `~/Applications`, GOG, Epic, itch and Heroic folders,
   plus any folders you add; Windows installs (Steam libraries in CrossOver bottles, found on
   their own, and Windows game folders in the folders you add) are listed too, as *Not supported*
   with the reason: the routes start from a Mac build, and a Windows build has x86 code and
   DirectX shaders;
2. sorts what it finds, with the reason for each game, into:
   - *Tested*: a game profile records it as played on an iPad;
   - *Untested: may work out of the box*: a route handles it and none of the checks below found
     anything that route is known to trip over;
   - *Needs work*: a route handles it, but a check found something that stops the port or needs a
     profile first (listed under Compatibility);
   - *Not yet supported*, *Not supported* and *Not installed*;
3. for a game a route handles (Unity or Unreal), asks up front for everything it needs (iPad,
   signing team, bundle ID, where to keep the workspace: ~40 GB for Unity, a few GB for Unreal
   when it is on the game's disk; for Unity, permission to download the matching editor), then
   runs the whole port with progress bars, a live log and plain-language hints when something
   needs your attention (unlock the iPad, sign in to Xcode, …).

The checks (`recomp/compat.py`), which run on every scan:

- **Unity (Mono)**: Unity 6 (the line the libil2cpp patches were written against); no native plugin
  that game code calls without a stub (`stubs/`); no library that generates code at run time
  (Harmony, MonoMod, Handlebars.Net). The Mac build's CPU does not matter: the .NET code is
  recompiled. A game on Unity's legacy input still counts, with a note: taps act as left clicks,
  but the other touch gestures need the Input System package.
- **Unreal (arm64)**: Unreal Engine 4's bundle layout; every Mach-O thin arm64; and a dry run of
  the `prepare` stage's import binding: every import of the game's binaries must bind to iOS or to
  `RecompAppKit.dylib`. That needs Xcode; the result is cached until the game or the shim changes.

Passing the checks is a good sign, not a promise: what a game does at run time (memory, shaders,
input, code paths the checks cannot see) only shows on the iPad.

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
| **Unreal** (implemented) | Unreal Engine 4 games built for Apple Silicon | Re-mark the game's own arm64 binaries as iOS and bind what iOS lacks (AppKit, Mac display and audio APIs) to a shim library |
| Mach-O retarget (planned) | Other native arm64 games (custom engines) | Same retargeting, with shims for what each engine uses |
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

The game must be built with exactly the Unity version it shipped with; `toolchain` reads it from
the game's `Info.plist`. When a game updates its Unity version, delete `build/<Game>` (its shell
project and Xcode output belong to the old editor) and run every stage again.

Two kinds of fixes apply on top of the generic pipeline:

- **libil2cpp patches** (`recomp/il2cpp_patches.py`) fill reflection calls that IL2CPP leaves
  unimplemented and restore Mono's assembly order. Each checks the exact original source text
  and stops the build when a Unity version differs, rather than patching blindly.
- **Game profiles** (`recomp/profiles/<game>.json`) hold game-specific rules:

  ```json
  {
    "name": "Timberborn",
    "tested": "playable on iPad (1.1.2, Steam).",
    "when_assembly": "Timberborn.HttpApiSystem.dll",
    "guard": {"<Assembly>.dll": ["Namespace.Type::Method"]},
    "why": "shown in the build log"
  }
  ```

  A profile applies when the game ships `when_assembly`. `tested`, when present, says the game
  has been played on an iPad (the scan lists it as *Tested*). Each `guard` method (which must return
  `void`) is rewritten so an exception it throws is logged and swallowed: for optional systems
  that cannot work on iOS and would otherwise abort start-up. A guard that no longer matches
  a method fails the build.

Debugging on the device: launch with
`xcrun devicectl device process launch --console --terminate-existing --device <UDID> <bundle id>`
(iPad unlocked). The shims log lines starting with `[recomp]`. Games that write their own logs or
error reports put them under the app's `Documents`, visible in the Files app.

## Unreal route

```
python3 recomp.py unreal <Game.app> --team <TEAMID> --bundle-id <id> --device <iPad name or UDID>
```

Stages (run all, or name some): `prepare xcode install`. Recomp Helper runs the same stages.

1. **prepare**: every Mach-O in the bundle is rewritten for iOS (`recomp/macho.py`): the platform
   becomes iOS, framework paths take their iOS form, and the main executable's imports are rebound
   library by library. Symbols iOS does not export (or that the route intercepts, listed in
   `INTERCEPT` in `recomp/unreal_ios.py`) bind to `RecompAppKit.dylib`, built from
   `recomp/native/appkit`; `libsteam_api.dylib` is replaced by a stub that reports Steam as not running.
   The engine's two `Contents/UE4/` path strings are patched to the bundle's `MacFiles/` folder.
2. **xcode**: a small generated Xcode project builds a placeholder app; its script phase puts the
   game's executable, the shim and APFS clones of the game data (instant on the same disk) into the
   bundle before Xcode signs it with automatic provisioning.
3. **install**: through `devicectl`. The whole app (about 8 GB for Stray) is copied each time.

What the shim provides:

- **AppKit on UIKit**: application lifecycle, windows (shown full screen, scaled to fit), views
  hosting the game's `CAMetalLayer`, events from the keyboard, trackpad and mouse, screens, cursors,
  menus, pasteboard, alerts;
- **Mac system APIs**: Quartz display modes and CVDisplayLink, keyboard layouts, the IOKit GPU entries
  Unreal looks for (answered with the real Metal device), CoreAudio's device queries (one output at the
  session's sample rate) and macOS audio units mapped to their iOS counterparts;
- **Metal differences**: managed storage becomes shared, Mac GPU families are reported, and
  metallibs from older tools load once their macOS flag is cleared;
- **case-insensitive file lookups**, as on a Mac's default volume (games ask for
  `libAPEXFramework.dylib` and ship `libApexFramework.dylib`);
- an **on-screen gamepad** (below), and per-game engine settings from the profile.

Game profiles for this route match on the Unreal project folder:

```json
{
  "name": "Stray",
  "tested": "playable on iPad, early testing (1.5, Steam).",
  "unreal_project": "Hk_project",
  "engine_ini": {"SystemSettings": {"r.Streaming.PoolSize": "auto"}},
  "why": "shown in the build log"
}
```

`engine_ini` keys are written into the game's user config at each launch; `auto` for
`r.Streaming.PoolSize` sizes the texture pool from the device's RAM. `intercept` lists extra imports
to bind to the shim, and `patches` replaces byte strings in the executable (hex, same length).

Debugging: shipping builds log almost nothing, but Mac game binaries usually keep their symbol table.

- the shim logs lines starting with `[recomp]`: unimplemented AppKit methods (they return zero instead
  of crashing), a backtrace when the game calls `exit`/`abort` with an error, and every 10 s the frame
  rate and the memory left;
- copy an empty file named `recomp-screenshot` into the app's `Documents` (`devicectl device copy to
  --domain-type appDataContainer`) to get `recomp-screen.png` back from the same folder;
- `xcrun lldb` can attach to the game on the device (`device select <UDID>`, `device process attach
  -p <pid>` after a `devicectl ... launch --start-stopped`); give it ~20 s to load symbols;
- `tools/xref.py` finds the code that uses a string or address.

## On-screen gamepad (Unreal route)

Touches drive a software game controller that the game reads like a real one, so its prompts show
gamepad buttons. It hides while a physical controller is connected.

| Where | Control |
|---|---|
| left half of the screen | move stick (appears where the finger lands) |
| right half of the screen | camera stick |
| bottom right | A, B, X, Y |
| top corners | LB, LT (left), RB, RT (right) |
| top left | Menu, View |
| bottom left / near the face buttons | L3 / R3 |

## Touch controls (Recomp.TouchMouse)

| Gesture | Mouse |
|---|---|
| 1 finger tap / drag | left click / drag |
| 2 finger drag | middle drag |
| pinch | scroll wheel |
| 3 finger drag | right drag |
| 2 finger tap | right click |
| Esc button (bottom left) | Escape key |

The virtual devices are named `Mouse` and `Keyboard`, like desktop ones: games store their
bindings as control paths such as `/Mouse/leftButton`, which match a device by name. The Esc
button presses Escape on whichever keyboard those bindings resolve to.
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
- `recomp/discover.py`: game scanning and environment checks; `recomp/windows_games.py`: Windows installs; `recomp/compat.py`: tested / untested / needs-work checks; `recomp/events.py`: progress events and failure hints
- `recomp/unity_ios.py`, `recomp/toolchain.py`, `recomp/unity_editor/`: Unity route
- `recomp/unreal_ios.py`: Unreal route; `recomp/macho.py`: Mach-O retargeting; `recomp/iossdk.py`: what
  the iOS SDK exports; `recomp/xcodeproj.py`: minimal Xcode project
- `recomp/native/appkit/`: the shim for retargeted Mac binaries; `recomp/native/steam_api_stub.c`
- `recomp/il2cpp_patches.py`: libil2cpp patches; `recomp/profiles/`: per-game rules (both routes)
- `recomp/textures.py`: BCn → ASTC texture conversion; `recomp/native/`: native start-up fixes
- `recomp/shims/`: managed shims injected into games
- `docs/images/`: screenshots for this README (the gallery holds four per row; add a `<td>` per game)
- `stubs/`: hand-written native stub overrides
- `tools/inspect_app.py`: triage; `tools/xref.py`: find code using a string; `tools/asmtool`: assembly scan/rewrite (Mono.Cecil); `tools/ilspy.sh`: decompiler
- `toolchain/`, `build/`: downloaded editors and per-game work (not in git)
