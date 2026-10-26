# Mac to iOS / iPadOS Recompilation

Play the Mac games you own on your iPad or iPhone. The tool takes a game installed on your Mac,
recompiles or retargets it for iOS, signs it with your own Apple developer account and installs it
on your device.

> **Your games, your devices.** A port contains the game, so it is for your own devices only: never
> share the app. Ports of Steam games play only after you sign in with a Steam account that owns the
> game.

[Download Recomp Helper](../../releases) · [Getting started](#getting-started) · [Roadmap](#roadmap) · [How it works](docs/TECHNICAL.md)

## Tested games

Tested on an iPad Pro 11" (M1, iPadOS 26.2) and an iPhone 17 (8 GB).

| Game | Engine | iPad | iPhone |
|---|---|---|---|
| [Timberborn](https://store.steampowered.com/app/1062090/Timberborn/) 1.1.2 | Unity 6, Mono | ✅ Playable | ⚠️ Runs; the HUD is being reworked for the phone |
| [Stray](https://store.steampowered.com/app/1332010/Stray/) 1.5 | Unreal Engine 4.27 | ✅ Playable, early testing | ⚠️ Plays until chapter 4, then runs out of memory |
| [Valheim](https://store.steampowered.com/app/892970/Valheim/) 1.0.20 | Unity 6, Mono | ✅ Playable, local worlds | ✅ Playable |

### Timberborn

<img src="docs/images/timberborn-ipad.jpg" width="480" alt="Timberborn on an iPad">

| | |
|---|---|
| **App size** | 2.3 GB |
| **Screen** | Landscape |
| **Touch** | Touch acts as the mouse; [placement mode](docs/TECHNICAL.md#touch-controls-recomptouchmouse) lets you aim a building before placing it. A **Dev** key above Esc toggles the game's developer mode |
| **Controller** | Not used: Timberborn is played with a mouse |
| **Keyboard, trackpad** | ✅ |
| **Saves on iCloud Drive** | ✅ [Shared](docs/TECHNICAL.md#saves-across-devices) with the Mac and your other devices |
| **Mods** | ✅ Data mods any time; [code mods](docs/TECHNICAL.md#mods-unity-ports) compiled in when porting |
| **Steam** | [License check](docs/TECHNICAL.md#steam-license-check) at first launch. No achievements, no Steam Cloud |
| **Frame rate** | Not measured yet |

Known limits: no hover, so no tooltips or highlight under the cursor; some buttons are small for
fingers (raise the in-game UI scale); a mod with code needs a new port; the local HTTP API's web
pages are off, since they compile templates at run time.

### Stray

<img src="docs/images/stray-ipad.jpg" width="480" alt="Stray on an iPad with the on-screen gamepad">

| | |
|---|---|
| **App size** | 8.4 GB |
| **Screen** | Landscape |
| **Touch** | [On-screen gamepad](docs/TECHNICAL.md#on-screen-gamepad) |
| **Controller** | ✅ Bluetooth controller tested; the on-screen pad hides when one connects |
| **Keyboard, trackpad** | ✅ |
| **Saves on iCloud Drive** | ✅ |
| **Steam** | License check at first launch. No achievements, no Steam Cloud |
| **Frame rate** | iPad M1: 40–50 fps, MetalFX upscaling from 75 %. iPhone 17: from 50 %, not measured |
| **Memory** | iPhone 17: from chapter 4 (The Slums) the game needs about 5.9 GB of the 6.1 GB iOS allows, and closes |

Known limits: only the first chapters have been played; short freezes the first time a scene
appears, while Metal compiles its shaders (cached afterwards); distant textures can load later than
on a Mac, since the texture pool is sized to the device's memory.

### Valheim

<img src="docs/images/valheim-ipad.jpg" width="480" alt="Valheim on an iPad with the on-screen gamepad">

| | |
|---|---|
| **App size** | 4.6 GB, and as much free space again to install an update |
| **Screen** | Landscape on iPad. iPhone: landscape, and portrait built but not yet tried on a device |
| **Touch** | On-screen gamepad in play; touch acts as the mouse in menus; the iOS keyboard opens for names |
| **Controller** | Not tried yet |
| **Keyboard, trackpad** | ✅ |
| **Saves on iCloud Drive** | ✅ Local worlds and characters |
| **Online** | ❌ Local worlds only: no online play, crossplay or Steam Cloud |
| **Steam** | License check at first launch |
| **Frame rate** | Not measured yet. iPhone renders at 75 % |

Known limits: the on-screen gamepad covers parts of the HUD (hotbar slot 1, the minimap corner,
food and health); worlds and characters kept in Steam Cloud must be moved to local storage in
Valheim's menus on the Mac first.

## Recomp Helper, the Mac app

<p align="center"><img src="docs/images/recomp-helper.png" width="720" alt="Recomp Helper with Timberborn selected and its saves synced through iCloud Drive"></p>

Recomp Helper finds the games on your Mac, says which ones can be ported and why, and ports them in
one go.

- **Finds your games** in Steam libraries, `/Applications`, GOG, Epic, itch and Heroic, and in
  folders you add. Windows games, CrossOver bottles included, are listed as not supported, with the
  reason.
- **Sorts them** into *Tested*, *May work out of the box*, *Needs work* and *Not supported*, with the
  reason for each game.
- **Ports in one go.** Pick the iPad or iPhone, your signing team and where to keep the build. It runs
  every step with progress bars, a live log and plain hints when something needs you (unlock the iPad,
  sign in to Xcode).
- **Installs on another device** after a port, and checks the device has room first.
- **Mods:** tick which of the Mac's mods go into the port.
- **Saves:** turn on iCloud Drive save sync for a game.

Download the notarized DMG from [Releases](../../releases), or build it yourself
([Building the app](docs/TECHNICAL.md#building-the-app)).

## Getting started

**You need:**

- a Mac with Apple silicon or Intel, on macOS 14 or later;
- Xcode with the iOS SDK, signed in to your Apple developer account;
- the .NET SDK (`brew install dotnet`);
- for Unity games, a free Unity Personal license (open Unity Hub once and sign in) and about 40 GB of
  free disk for the build;
- an iPad or iPhone paired with the Mac, unlocked while the app installs.

**With the app:** open Recomp Helper, select a game, press **Port**.

**From the command line:**

```sh
python3 recomp.py scan                          # your games and whether they can be ported
python3 recomp.py inspect /path/to/Game.app     # engine, CPU, route and blockers for one game
python3 recomp.py env                           # Xcode, signing teams, paired devices

# Unity game: fetch its exact Unity version once, then port
python3 recomp.py toolchain /path/to/Game.app
python3 recomp.py unity  /path/to/Game.app --team <TEAMID> --device "<iPad name>"

# Unreal game
python3 recomp.py unreal /path/to/Game.app --team <TEAMID> --device "<iPad name>"

python3 recomp.py mods  /path/to/Game.app           # which mods go into the next port
python3 recomp.py saves /path/to/Game.app --enable  # share saves through iCloud Drive
```

Set `RECOMP_HOME` to keep the large files (Unity editors, builds) on another disk.

| How long it takes | Measured |
|---|---|
| Valheim, first port | about 10 min just to convert 4 GB of asset bundles (13 GB of RAM at peak) |
| Timberborn, port again after changing mods | 15–20 min with Unity's cache warm |
| Stray, install on the iPad | about 4 min: the whole 8 GB app is copied each time |

## Which games can be ported

**May work out of the box.** Recomp Helper's checks found nothing the route is known to trip over:

- Unity 6 games built with Mono (a `Data/Managed` folder of .NET DLLs), on Apple silicon or Intel:
  the code is recompiled, so the Mac build's CPU does not matter;
- Unreal Engine 4 games built for Apple silicon, when every function the game imports exists on iOS
  or in the port's shim.

**Needs work first** (a game profile, a stub or a patch):

- Unity versions older than 6: the IL2CPP patches are written against Unity 6;
- native plug-ins without a stub (Steamworks, PlayFab Party and Apple's Mac plug-ins are already
  stubbed);
- libraries that generate code while the game runs (Harmony, MonoMod): iOS forbids it;
- Unity's old input system: taps act as clicks, but pinch and multi-finger gestures need the Input
  System package;
- large games on an iPhone: an 8 GB iPhone gives an app about 6 GB.

**Not supported:**

- Windows games, CrossOver included: x86 code and DirectX shaders;
- Intel-only native games: iOS forbids JIT, so there is no Rosetta-style translation;
- Unity games built with IL2CPP, Unreal Engine 5, Godot, Ren'Py, LÖVE, HTML5 and custom engines: no
  route yet ([Roadmap](#roadmap)).

Passing the checks is a good sign, not a promise: memory, shaders and input only show on the device.
What each check looks at: [Compatibility checks](docs/TECHNICAL.md#compatibility-checks).

## Roadmap

### Engines
- [x] Unity games built with Mono, recompiled to native code with IL2CPP
- [x] Unreal Engine 4 games for Apple silicon, retargeted to iOS
- [ ] Other native Apple silicon games (custom engines): the same retargeting, with shims per engine
- [ ] Godot, Ren'Py, LÖVE and HTML5 games, on each engine's iOS runtime
- [ ] Intel-only games, by static recompilation, one game at a time

### Devices
- [x] iPad
- [x] iPhone, for Unity and Unreal ports
- [x] Portrait play on iPhone, opted into per game (Valheim)
- [ ] Portrait confirmed on a device
- [ ] Stray past chapter 4 on iPhone (runs out of memory there)

### Controls
- [x] Touch as a mouse: tap, drag, pinch to scroll, two-finger right click, Apple Pencil
- [x] On-screen gamepad for action games, hidden when a controller connects
- [x] Bluetooth controllers, keyboards and trackpads
- [x] iOS keyboard for the game's text fields
- [x] Placement mode for building games (Timberborn)
- [ ] Timberborn's HUD laid out for iPhone (in progress)
- [ ] Tooltips and hover highlights in mouse games
- [ ] On-screen gamepad that keeps clear of the game's HUD (Valheim)

### Saves and accounts
- [x] Saves shared between Mac, iPad and iPhone through iCloud Drive
- [x] Steam license check: QR code, or password and Steam Guard
- [ ] Steam Cloud saves
- [ ] Steam achievements
- [ ] Online play (Valheim)

### Mods
- [x] Data mods, added any time through Files
- [x] Code mods, compiled into the port
- [x] Harmony patches, woven into the game at port time
- [ ] Harmony transpilers, reverse patches and patches made while the game runs
- [ ] Mods for Unity games other than Timberborn

### Recomp Helper
- [x] Finds games across Steam, GOG, Epic, itch, Heroic and your folders
- [x] Compatibility check with the reason for each game
- [x] One-click port of Unity and Unreal games, to an iPad or an iPhone
- [x] Install on another device, with a free-space check
- [x] Notarized DMG

### Performance
- [x] Texture memory sized from the device's RAM (Unreal)
- [x] Per-game render settings, such as Stray's MetalFX upscaling
- [ ] Frame rates measured for every tested game
- [ ] Fewer stutters the first time a scene appears, while Metal compiles shaders

## More

- **[How it works](docs/TECHNICAL.md):** the Unity and Unreal routes, game profiles, touch controls in
  detail, mods, save sync rules, the Steam license check, debugging on the device and building the app.
- **Contributing:** this repository is public. Never commit game files or personal details; see
  [Contributing](docs/TECHNICAL.md#contributing) for the commit guard.
- **License:** MIT, see [LICENSE](LICENSE). It covers this tool only, not the games you port.
