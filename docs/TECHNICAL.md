# How it works

The [README](../README.md) says what the ports do and how to run them. This file covers how each route turns a
Mac game (or a Qt app) into an iOS app, and the details behind controls, mods, saves and the Steam runtime.

## Routes

`inspect` reports the engine, CPU architectures, Mac-only frameworks and which route applies:

| Route | Games | How |
|---|---|---|
| **Unity / Mono** (implemented) | Unity games whose `Data/Managed` holds .NET assemblies | Recompile the game's assemblies to native ARM64 code with the matching Unity version's IL2CPP, then run the game's own data on Unity's iOS player |
| **Unreal** (implemented) | Unreal Engine 4 games built for Apple Silicon | Re-mark the game's own arm64 binaries as iOS and bind what iOS lacks (AppKit, Mac display and audio APIs) to a shim library |
| **Qt** (implemented) | Mac apps built with Qt 6.5.5 for Apple Silicon | Retarget the app's own arm64 binaries, run them on an iOS build of the same Qt, desktop OpenGL on gl4es |
| **AIR** (implemented) | Adobe AIR captive-runtime games (Brawlhalla) | Package the game's own SWFs for AIR's iOS runtime with the AIR SDK, with iOS stand-ins for its native extensions |
| Mach-O retarget (planned) | Other native arm64 games (custom engines) | Same retargeting, with shims for what each engine uses |
| Engine runtime swap (planned) | Godot, Ren'Py, LÖVE, HTML5 | Run the game's data on the engine's iOS runtime |
| Static recompilation | Intel-only games | Per-game project; iPadOS forbids JIT, so no Rosetta-style translation |

## Compatibility checks

Recomp Helper and `recomp.py scan` sort every game they find into *Tested*, *Untested: may work out of the box*,
*Needs work*, *Not yet supported*, *Not supported* and *Not installed*.

The checks (`recomp/compat.py`), which run on every scan:

- **Unity (Mono)**: Unity 6 (the line the libil2cpp patches were written against); no native plugin
  that game code calls without a stub (`stubs/`); no library that generates code at run time
  (Harmony, MonoMod, Handlebars.Net). The Mac build's CPU does not matter: the .NET code is
  recompiled. A game on Unity's legacy input still counts, with a note: taps act as left clicks,
  but the other touch gestures need the Input System package.
- **Unreal (arm64)**: Unreal Engine 4's bundle layout; every Mach-O thin arm64; and a dry run of
  the `prepare` stage's import binding: every import of the game's binaries must bind to iOS or to
  `RecompAppKit.dylib`. That needs Xcode; the result is cached until the game or the shim changes.
- **Adobe AIR**: every native extension in `Contents/Resources/META-INF/AIR/extensions` (its id from
  the extension's `extension.xml`) has a stand-in, `recomp/native/air/<id>.c`; otherwise the check
  names the missing ids. A note says when the AIR SDK is not installed.

Passing the checks is a good sign, not a promise: what a game does at run time (memory, shaders,
input, code paths the checks cannot see) only shows on the iPad.

## Unity route

```
python3 recomp.py toolchain <Game.app>        # fetch that exact Unity version + iOS support into toolchain/
python3 recomp.py unity <Game.app> --team <TEAMID> --device <iPad name or UDID>
```

The bundle ID defaults to Recomp Helper's, `recomp.<team>.<game>`, so a port from either installs
over the last one (keeping its saves and Steam sign-in); `--bundle-id` picks another.

Stages (run all, or name some): `prepare player inject xcode install`.

1. **prepare**: a shell Unity project in `build/<Game>/shell` gets every game-owned
   assembly as an iOS-only plugin (engine and class-library assemblies come from Unity's
   iOS player instead). P/Invokes into libraries iOS lacks (Steamworks, PlayFab Party, Apple's
   Mac plug-ins, a game's own Mac helpers: `STUB_PROFILES` in `recomp/unity_ios.py`) are
   redirected to `__Internal`: Steamworks to the [Steam runtime](#steam-runtime), built into the
   port, and the rest to a generated C stub (`stubs/*.overrides.c` for functions where 0 is the
   wrong answer). Managed shims from `recomp/shims` are added (touch controls), and the
   selected mods' DLLs, with their Harmony patches woven in ([Mods](#mods-unity-ports)).
2. **player**: the matching editor builds the shell for iOS in batchmode, which runs IL2CPP
   over all of it and writes an Xcode project.
3. **inject**: the shell's data is replaced with the game's (`StreamingAssets` → `Data/Raw`);
   IL2CPP metadata and the iOS default resources stay; serialized files are retargeted to iOS;
   BC textures become ASTC (iOS cannot sample BC); asset bundles get both, repacked, and are
   cached in `cache/bundles/<Game>`; shims are registered in `RuntimeInitializeOnLoads.json`.
4. **xcode** / **install**: sign with automatic provisioning and install through `devicectl`;
   install then copies the ported mods to the iPad's mod folder.

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
  a method fails the build. Other keys:

  | Key | Effect |
  |---|---|
  | `returns` | `{"<Assembly>.dll": {"Type::Method": value}}`: the method only returns that string, bool or int (e.g. a platform check with no iOS answer) |
  | `responders` | `{"<Assembly>.dll": ["Namespace.Type"]}`: Steamworks.NET matchmaking responders whose native vtable of instance delegates IL2CPP cannot marshal get static `[MonoPInvokeCallback]` trampolines that find the instance by its native address (`asmtool responders`) |
  | `stub_overrides` | swaps a stub profile's override files (`stubs/`) for this game |
  | `steam_networking` | `true` for online play: links GameNetworkingSockets and PlayFab Party's iOS framework ([Online play](#online-play-valheim)) |
  | `touch_gamepad` | `true` for action games: on-screen gamepad in play (see below) |
  | `saves` | where the game keeps its saves on the Mac and on iOS, for syncing them between devices |
  | `steam_app_id` | the game's Steam app id, for the [Steam runtime](#steam-runtime) (found from the Steam library otherwise) |
  | `mods` | where the game keeps its mods on the Mac and on iOS, for compiling them in ([Mods](#mods-unity-ports)) |
  | `touch_keys` | extra on-screen keys above Esc: `[{"label": "Dev", "keys": ["leftAlt", "leftShift", "z"]}]` (Input System key names, held together) |
  | `iphone` | settings applied only on an iPhone, over the generic phone defaults: `render_scale`, `target_frame_rate`, `quality_level`, `player_prefs`, `static_fields`, `portrait`, `portrait_horizontal_fov` (listed in `PHONE_DEFAULTS`, `recomp/unity_ios.py`) |

  Ports play in landscape. A game can opt into portrait on the iPhone with
  `"iphone": {"portrait": true}`: the phone then also plays upright (home indicator down, never
  upside down) and rotates with it, mid-game included. The iPad always stays landscape, through
  its own Info.plist key and again at runtime. Upright, the render size follows the orientation,
  and each perspective camera that draws to the screen shows as many degrees across as the game
  shows tall in landscape. `"portrait_horizontal_fov": <degrees>` picks another width. Valheim
  opts in; its UI fits the narrow screen through `static_fields` (GuiScaler's minimum width).

Debugging on the device: launch with
`xcrun devicectl device process launch --console --terminate-existing --device <UDID> <bundle id>`
(iPad unlocked). The shims log lines starting with `[recomp]`. Unity ports also keep everything
they print in `Library/Logs/recomp.log` ([Debugging the runtime](#debugging-the-runtime)). Games
that write their own logs or error reports put them under the app's `Documents`, visible in the
Files app.

## Unreal route

```
python3 recomp.py unreal <Game.app> --team <TEAMID> --device <iPad name or UDID>
```

Stages (run all, or name some): `prepare xcode install`. Recomp Helper runs the same stages.

1. **prepare**: every Mach-O in the bundle is rewritten for iOS (`recomp/macho.py`): the platform
   becomes iOS, framework paths take their iOS form, and the main executable's imports are rebound
   library by library. Symbols iOS does not export (or that the route intercepts, listed in
   `INTERCEPT` in `recomp/unreal_ios.py`) bind to `RecompAppKit.dylib`, built from
   `recomp/native/appkit`; `libsteam_api.dylib` is replaced by the [Steam runtime](#steam-runtime).
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

`engine_ini` keys are written into the game's user config (`Engine.ini`) at each launch, and
`game_user_settings_ini` keys into `GameUserSettings.ini` (the game's own options, such as its
upscaler and screen percentage); `auto` for `r.Streaming.PoolSize` sizes the texture pool from the
device's RAM. `intercept` lists extra imports
to bind to the shim, and `patches` replaces byte strings in the executable (hex, same length).

Debugging: shipping builds log almost nothing, but Mac game binaries usually keep their symbol table.

- the shim logs lines starting with `[recomp]`: unimplemented AppKit methods (they return zero instead
  of crashing), a backtrace when the game calls `exit`/`abort` with an error, and every 10 s a heartbeat: frame
  rate, GPU time per frame, CPU for the busiest threads, the longest wait between frames, memory left
  and the thermal state;
- copy an empty file named `recomp-screenshot` into the app's `Documents` (`devicectl device copy to
  --domain-type appDataContainer`) to get `recomp-screen.png` back from the same folder;
- `xcrun lldb` can attach to the game on the device (`device select <UDID>`, `device process attach
  -p <pid>` after a `devicectl ... launch --start-stopped`); give it ~20 s to load symbols;
- `tools/xref.py` finds the code that uses a string or address.

## Qt route

```
python3 recomp.py qt <App.app> --team <TEAMID> --device <iPad name or UDID>
python3 recomp.py qt <App.app> --sim          # iOS simulator on this Mac, for lldb
```

Stages (run all, or name some): `toolchain prepare xcode install`. Not in Recomp Helper yet.

A Qt app's own code and libraries are arm64 already. What ties them to macOS is Qt's Cocoa platform
plugin, desktop OpenGL and a handful of system calls, so the route swaps Qt and OpenGL underneath and
retargets the rest (`recomp/qt_ios.py`):

1. **toolchain**: Qt `<version>` (read from the app's `QtCore` link) built for iOS from Qt's source,
   once per version and SDK, under `toolchain/qt-<version>/`: a macOS build first (moc, rcc, qsb),
   then qtbase, qtshadertools, qtsvg, qt5compat and qtmultimedia for `iphoneos` or `iphonesimulator`.
   Configured like a Mac build so the app's imports match: **shared frameworks** (Qt builds iOS
   statically by default), **desktop OpenGL**, D-Bus, QProcess and QPrinter on. Every Qt symbol a Mac
   app imports then exists. `recomp/patches/qt-<version>-ios.patch` makes that build work and run:
   - shared frameworks on iOS; no AGL (gone from the macOS 26 SDK);
   - **start-up**: Qt for iOS expects to own `main()` (`qt_main_wrapper` starts UIKit, then calls the
     app's `main`). A Mac app's `main` runs first and creates `QApplication` itself, so when the iOS
     plugin is created with UIKit not running, it calls `UIApplicationMain` there and `longjmp`s back
     into its constructor once UIKit has launched; `exec()` then runs nested in UIKit's run loop;
   - the iOS context makes each EAGL context's GL calls go through gl4es (below), with one gl4es state
     per context, and resolves functions through it;
   - **windows**: iOS has no window management, so main windows (`Qt::Window`) stay maximized
     whatever size the app restores, other windows are kept on screen, and the screen is the app's
     own `UIWindow` when that is smaller than the display (iPadOS 26 runs apps in resizable windows
     and ignores `UIRequiresFullScreen`);
   - **keyboard**: it follows focus only, so a tap on the focused text input brings it back once
     the user has hidden it; on iPad a hide-keyboard button is added at the right of its shortcuts bar.
2. **prepare**: every Mach-O of the bundle except Qt's own is thinned to arm64 and marked as iOS. Mac
   Qt apps' binaries bind their imports with dyld-info opcodes, by **library slot**, so each keeps its
   library list slot for slot (`macho.py` `bound_imports()` reads which symbols come through which
   slot): a Qt framework becomes `@rpath/QtX.framework/QtX`, a bundled library `@rpath/<name>`, a
   system library its iOS path when that exports everything the slot imports. A slot whose symbols
   iOS lacks goes to **`RecompQt.dylib`**, built per app from `recomp/native/qt/`: it re-exports the
   iOS libraries it stands in for and adds what is missing (a `dlopen` that loads the app's
   `OpenGL.framework` for any path to the Mac one, `syslog$DARWIN_EXTSN`, Apple-event and collation
   stubs), then a generated "return 0" stub for anything else. dyld refuses a library listed twice,
   so slots sharing one are spelled `@rpath/./X`, `@rpath/././X`, same file. The iOS Qt frameworks
   the app and its plugins need, Qt's iOS plugins and a `qt.conf` go next to them.
3. **xcode** and **install**: as for the Unreal route; the Mac bundle's `Contents/Resources` goes in
   as `MacResources/`. A profile can patch the executable (`patches`) and resource files
   (`resource_patches`: text find/replace), matched on `bundle_id`, and pin the app's light or
   dark mode (`appearance`, see **Light and dark mode** below).

**OpenGL** (`recomp/ios_opengl.py`): iOS has no desktop OpenGL. The port's `OpenGL.framework` is
[gl4es](https://github.com/ptitSeb/gl4es) v1.1.6 (desktop OpenGL 2.1 on OpenGL ES 2) and GLU, with
every name gl4es serves exported under its desktop name (an ld64 alias list made from gl4es's own
lookup table), plus CGL and `NSOpenGLContext` stubs that fail cleanly. Qt's QOpenGLWidget, the app's
GL loader (GLAD and the like `dlopen` the framework) and GLU all use the same instance.
`recomp/patches/gl4es-ios.patch`: no symbol aliases in Mach-O, and the bound GLSL and ARB programs
are kept per context (gl4es shared them between shared contexts, so Qt's compositing shader drew the
app's meshes). Old ARB assembly programs are hidden (`LIBGL_NOARBPROGRAM`), so apps take their GLSL
or fixed-pipeline paths. GLSL 1.20 shaders the app ships must also be valid GLSL ES: no implicit
int-to-float conversion, no `smoothstep(e, e, x)`; fix those with `resource_patches`.

**Window sizes**: a QWidget main window's minimum size is the sum of its contents (a few docks open
is wider than an 11-inch iPad), and it grows the window back to it. `RecompQtWindows.mm` in the shim
stops top-level layouts enforcing their minimum, so the contents squeeze into the screen.

**Touch sizes**: a QWidget app keeps the Mac's mouse-sized controls. `RecompQtTouch.mm` puts a proxy
style over the app's own style (installed when the first widget is polished, and again if the app
replaces its style): hit targets of 44 pt for menu items, tabs, buttons, combo boxes and line edits,
32 pt spin-box arrows and dock title-bar buttons, 24 pt check boxes, 12 pt splitter and dock
separators, 44 pt shortest scroll-bar slider. Drawing stays the app style's. Text is raised to at
least 15 pt, except in text editors (`QPlainTextEdit`, `QTextEdit`, QScintilla), which keep the app's
or the user's size, and a press must move 12 pt before it starts a drag.

**Touch scrolling**: a finger reaches a QWidget app as the mouse events Qt makes of a touch, so a
drag in a list or a text view would select. `RecompQtScroll.mm` makes a one-finger drag inside any
`QAbstractScrollArea` viewport with something to scroll (item views, text views, `QScrollArea`,
QScintilla) move the content, with momentum and a small bounce at the ends (a `QScroller` per
viewport fed from an event filter on qApp; mouse and trackpad are left alone). The press is held
back until it is clear what it is: released without moving, it is a tap and reaches the widget;
past the drag distance it scrolls and the widget never sees it; a drag the area cannot follow goes
to the widget. A press held still for 500 ms goes to the widget, so hold-then-drag selects text or
drags items, and a double tap still selects a word. Sliders and splitter handles keep their drag;
scroll bars (outside the viewport) stay 18 pt and draggable. Menus are left out (under Fusion a
menu taller than the screen wraps into columns).

**Light and dark mode**: the app follows the device's mode, and switches
live. A profile's `"appearance": "light"` or `"dark"` (default `"system"`) puts
`UIUserInterfaceStyle` in that app's Info.plist, for an app whose own colours only work in one
mode. Qt's iOS theme palette is only half dark: it starts from Fusion's palette for the scheme Qt
saw at start-up, before UIKit has a window (light), and gives the Active group's text roles iOS's
colours only, so inactive text (item views without focus draw as inactive) stayed black on black.
`RecompQtAppearance.mm` builds the application palette whole from iOS's system colours resolved for
the current scheme, every role in every group, at start-up and on each change. Widgets under a
style sheet keep a copy of the palette they were polished with, and Qt does not pass a parent's
palette on to them, so after each change every window is walked parents first: those the sheet
gave colours are polished again, the others resolve again. An app that sets its own application
palette keeps it. Colours the app draws itself (an editor's colour scheme, a 3D view) are its own.

**Text input**: keys reach a text input through Qt's text responder (`QIOSTextInputResponder`),
which has to be UIKit's first responder: with a hardware keyboard (or the Mac's, through Universal
Control) the window's view takes only the arrow keys while the focus widget accepts text, and
drops the rest. Whether a tap lands on the input, which brings the responder (and the keyboard)
back, the iOS plugin decides from the input's `Qt::ImInputItemClipRectangle`. QWidget answers that with its visible rectangle, but a
widget overriding `inputMethodQuery()` may answer nothing (QScintilla answers only `ImHints`
that way), so no tap landed on it and a hardware keyboard typed nothing there. `RecompQtInput.mm`
gives such a widget QWidget's answer.

**Dock drawers**: around a main window's central widget, docks leave little of it on an 11-inch
iPad. `RecompQtDrawers.mm`, for any `QMainWindow`, puts handles on the central widget, kept clear
of toolbars that run along its edges:
- left, right and bottom edges: the dock areas there are drawers, each with a handle. While the
  area's docks are open it is a grip: dragging resizes them, dragging 48 pt past their minimum
  size closes them all, and a tap switches between an even split with the central widget and the
  size set last. While they are closed it points out: a tap brings back the ones that were open,
  at the size they had, and dragging out opens them at the size dragged to (also back within the
  same drag that closed them). A dock the app opens itself opens its drawer. Open or closed is
  saved per area in the app's `QSettings` (`recomp/drawers/<area>`, the hidden docks under
  `recomp/drawerDocks/<area>`) and applied once the app has restored its own layout. First
  launch: right and bottom closed, left as the app lays it out, and the docks the app's own layout
  had open are saved as what each drawer's first tap brings back. Settings survive an install over
  the app; only deleting it starts again. Tabbed docks count as one, the size of the current tab;
- top-right corner: the central widget alone. Every open drawer closes and the window's own
  toolbars hide; the handles stay. The next tap brings back what was open, and opening a drawer
  meanwhile (by its handle or the app) ends it. Drawers it closed are not saved as closed.

**Debugging**: in the simulator, `xcrun simctl launch --wait-for-debugger` then lldb. On a device and
in the simulator, files dropped into the app's `Documents` (`devicectl device copy to --domain-type
appDataContainer`, or the simulator's data container) drive `RecompQtHooks.mm`:

| File | Content | Result |
|---|---|---|
| `recomp-actions` | empty | `recomp-actions.txt`: every QAction, object name and text |
| `recomp-action` | an action's object name or text | triggers it |
| `recomp-text` | empty | `recomp-text.txt`: the text of every visible text view |
| `recomp-type` | the text | types it into the focused widget, as the keyboard commits text |
| `recomp-click` | `x y`, screen points | a left click (not a touch) on the widget there |
| `recomp-swipe` | `x1 y1 x2 y2 ms [hold]` per line, screen points | a one-finger touch through Qt's touch input, as the iOS plugin sends it: held `hold` ms, then moved to the end over `ms`; each line starts as the one before ends (a double tap is two 0 ms lines) |
| `recomp-grab` | empty | `recomp-gl-<n>.png`, each QOpenGLWidget read back; `recomp-window.png`, the active window; window and screen sizes, and each GL view's depth and stencil bits, in the log |
| `recomp-drawers` | empty | in the log: each dock drawer, open or closed, its handle's screen rectangle (for `recomp-click`) and its docks; the left grip, the central-widget button and the left docks' width (`RecompQtDrawers.mm`) |
| `recomp-appearance` | empty | in the log: the colour scheme, the application palette per group, and each visible label, button and item view's text and background colours, with whether it has its own palette or a style sheet (`RecompQtAppearance.mm`) |
| `recomp-input` | empty | in the log: the focus object, whether it takes text, its input rectangle (and whether the widget answers it itself), its cursor rectangle, and UIKit's first responder (`QIOSTextInputResponder` while keys go to the input) (`RecompQtInput.mm`) |

`LIBGL_LOGSHADERERROR=1` and `LIBGL_DBGSHADERCONV=1` (prefix them `SIMCTL_CHILD_` for the simulator)
show gl4es's shader conversions and errors.

## AIR route

```
python3 recomp.py air <Game.app> --team <TEAMID> --device <iPad name or UDID> [--interpreter]
```

Stages (run all, or name some): `prepare package xcode install`. Not in Recomp Helper yet.

An Adobe AIR game is ActionScript bytecode in SWF files, plus native extensions (ANEs). The Mac app
carries its own AIR runtime (the captive runtime, `Contents/Frameworks/Adobe AIR.framework`) and the
extensions as Intel frameworks; the SWFs and data run anywhere AIR does. So the route packages the
game's `Contents/Resources` for AIR's iOS runtime with the AIR SDK's packager, ADT, and swaps each
extension for an iOS stand-in (`recomp/air_ios.py`):

1. **prepare**: each stand-in, `recomp/native/air/<id>.c`, is built as a static library for armv7
   and arm64 and lipo'd into one (ADT refuses an `.a` with one architecture, "not a universal
   binary"; nothing runs the armv7 slice). Packed with the game's own `catalog.xml` and
   `library.swf` (the extension's ActionScript side) into `<id>.ane`. The descriptor comes from the
   game's `META-INF/AIR/application.xml`: AIR 51.5, `mobileDevice`, full screen, landscape, the
   game's render mode, the iPad, file-sharing and controller keys, and the two memory
   entitlements. ADT refuses `UIStatusBarHidden`, `UISupportedInterfaceOrientations` and
   `MinimumOSVersion` in `InfoAdditions` (error 105) and `<data>` values in it. The Mac icon
   becomes an `Assets.car` (actool) at the package's root, which ADT takes instead of its own. It
   also holds `air_splash`, the image AIR's launch screen shows (the icon's art here): without it
   AIR stops with "application packaging error".
2. **package**: ADT `ipa-test`, which compiles the ActionScript ahead of time (about 25 minutes for
   Brawlhalla), or `ipa-test-interpreter` with `--interpreter` (about 2 minutes). It signs from
   the keychain (`-storetype KeychainStore`) with the team's Apple Development identity and needs
   a development profile holding that certificate: the bundle's own once the xcode stage has made
   one, else the team's wildcard. ADT runs `java` by name, so the route puts
   `toolchain/jdk-17/Contents/Home/bin` first on `PATH`.
3. **xcode**: the wildcard profile lacks the memory entitlements, so a generated Xcode project
   with automatic provisioning signs again, as the Unreal route does: its run-script phase copies
   ADT's app in over a placeholder. ADT's `Info.plist` and `Assets.car` stay as they are: AIR checks
   at launch that the package is the one ADT made, and shows "application packaging error" when
   they differ.
4. **install**: `devicectl`.

The AIR SDK only downloads through HARMAN's AIR SDK Manager after its license is accepted, so the
route never fetches it: it looks for `toolchain/air-sdk/AIRSDK_*` and says how to get one
([README](../README.md#getting-started)).

### Brawlhalla's extensions

Each logs its calls to stderr as `[air] ...` (`devicectl device process launch --console`; the
app stops when devicectl does), except those called every frame.

- **RawData** reads the `.swz` data archives (text entries, WELL512-keyed XOR, a checksum each,
  zlib), rewritten from the Mac library. The key comes from the game's ActionScript at run time
  and is never stored or logged.
- **SoundEngineExtension** stands in for the Wwise 2017.2 wrapper, silently: on iOS the game asks
  for its banks under `audio/pc` and the Mac build ships `audio/mac`. Sound is a later step.
- **SteamAir** runs on the [Steam runtime](#steam-runtime): its arm64 slice is `SteamAir.c` with
  `RecompSteam/`, `RecompLicense.m` (the sign-in cover), `RecompSaves.m` and `RecompLog.m`, merged
  into one object (`ld -r`) so their constructors are linked; the extension's platform options link
  UIKit, Security, CoreImage and libz. Its 23 functions do what the Mac library's do, through the
  flat API. The game learns results through status events (`FREDispatchStatusEventAsync`, code
  and level as decimal strings): `1` the encrypted app ticket arrived (level: its EResult), then
  `SteamAir_GetEncryptedAppTicket` hands over a `Vector.<int>` of the 1024-byte buffer and the
  length; `2`–`7` purchases, licenses, stats and achievements. `SteamAir_Init` answers false, and
  the game calls it again, until the session knows the player.

  The ticket carries data the game's server checks: `em`, then for each of 7 files of the Mac
  bundle (its executable, the main SWF, the four archives, the Mac RawData framework) `1` and the
  file's SHA-256, then `0`. The port computes it from the Mac game when porting, reading the file
  list from the game's own SteamAir library, and passes it in `Info.plist` as
  `RecompAirTicketData` (hex). The descriptor's `InfoAdditions` also get `RecompSteamAppId`,
  `RecompGame` and the save mode keys.

### Not yet

- **Ahead of time**: the game reads its art SWFs with `FileStream` and loads them with
  `Loader.loadBytes` (`allowCodeImport`). AIR on iOS cannot run bytecode loaded that way when
  the app is compiled ahead of time, so that build stops on its loading screen after the data
  archives; the interpreter build runs. Making it load the packaged SWFs with `Loader.load` instead
  would mean patching the game's ActionScript.
- **Version**: after the Steam login, Blue Mammoth's server answers that the version is not the
  latest (the Mac install is current); most likely the game reports itself as the iOS client when
  AIR says iOS. With **Stay offline** the game plays: training and local matches against bots.
- **Input**: no touch controls. Keyboard and mouse play as on the Mac; a controller is not tried yet.

## On-screen gamepad

Action games get an on-screen gamepad: every Unreal port, and Unity ports whose profile sets
`touch_gamepad` (Valheim; not Timberborn, which is played with the mouse). Touches drive a game
controller that the game reads like a real one, so its prompts show gamepad buttons. It hides while
a physical controller is connected. In Unity ports it shows only while the game has locked the
cursor (in play); in menus touches act as the mouse, and a quick tap off the pad's buttons is a click.

| Where | Control |
|---|---|
| left half of the screen | move stick (appears where the finger lands) |
| right half of the screen | camera stick |
| bottom right | A, B, X, Y |
| top corners | LB, LT (left), RB, RT (right) |
| top left | Menu, View |
| bottom left / near the face buttons | L3 / R3 |
| left edge, between LT and L3 | D-pad (Unreal ports): up, down, left, right; two arms held give a diagonal |

The key buttons (Unity ports) stay on screen with or without a controller.

## Touch controls (Recomp.TouchMouse)

| Gesture | Mouse |
|---|---|
| 1 finger tap / drag | left click / drag |
| 2 finger drag | middle drag |
| pinch | scroll wheel |
| 3 finger drag | right drag |
| 2 finger tap | right click |
| Apple Pencil | like one finger (iOS reports it as a pen, which games that read the mouse ignore) |
| key buttons (bottom left) | Esc, and above it the profile's `touch_keys` (Timberborn: Dev) |
| tap a text field | the iOS keyboard opens (TextMeshPro fields) |

**Placement mode** (Timberborn, through its built-in TheSTouchscreen mod). Desktop building games show
a ghost of the building under the mouse, let you rotate it, and place it on the click; a tap is a
click the moment it lifts, so there would be no time to rotate. While a building, path or platform
tool is active:

| Touch | Effect |
|---|---|
| 1 finger or the pencil on the map | moves the mouse without clicking: the ghost follows and stays where you lift |
| tap the game's UI (rotate, flip, menus, another building) | clicks at once; the mouse then goes back to where you aimed, so the ghost reappears there |
| **Place** (in the game's placement panel) | clicks where you aimed |
| **Rows** (in the game's placement panel) | lit: touches act directly again, so a drag draws a row (paths, walls) and places it on lift |
| 2 and 3 finger gestures | the camera, as usual |

Whether a touch is on the UI is asked of the game's EventSystem two frames after the mouse moved
onto the finger, the same test the game makes before it places. The shim side is
`Recomp.Placement` (a game mod sets `Placement.Active`); turning the mod off in the game's mod
list brings back placing on touch.

The virtual devices are named `Mouse` and `Keyboard`, like desktop ones: games store their
bindings as control paths such as `/Mouse/leftButton`, which match a device by name. The key
buttons press their keys on whichever keyboard those bindings resolve to. They are drawn with UI
Toolkit when the game uses it, otherwise as a uGUI overlay.
A real keyboard or trackpad, when connected, works alongside.

## Mods (Unity ports)

iOS does not let an app turn new code into machine code while it runs (no JIT). So a mod's code
can only run on the iPad if it was compiled into the app when the game was ported. Its data files
(blueprints, models, textures, translations) are read by the game as usual.

| Kind of mod | How it gets onto the iPad |
|---|---|
| **Data only** (no `.dll`) | Any time: drop its folder into Files > On My iPad > Timberborn > Mods. |
| **With code** (`.dll`) | Install it on the Mac, then port the game. Adding, updating or removing one means porting again. |
| **With Harmony patches** | The same. Its patches are woven into the game when it is ported (below). |

To add mods with code:

1. Install the mods for the Mac game as usual: subscribe in the Steam Workshop, or put the mod's
   folder in `~/Documents/Timberborn/Mods`. Start the game on the Mac once to check they work
   there; mods made for an older game version usually fail on both.
2. Choose which go into the port: the Mods box in Recomp Helper (one checkbox per mod), or
   `python3 recomp.py mods <Game.app>` to list them and `--exclude <id>` / `--include <id>` to change
   the choice. New mods are included unless you exclude them. Each mod shows what the port will do
   with it: its code is compiled in, it is data only, or it cannot run on iOS and why.
3. Port the game (Recomp Helper, or `recomp.py unity …`). The install stage also copies the
   ported mods to the iPad's mod folder (`recomp.py mods <Game.app> --device … --bundle-id …` does
   that alone). It adds and overwrites files, and leaves other mods in the iPad's folder alone; if
   an update deleted files from a mod, delete that mod's folder in Files first. Re-porting after
   a mod change takes ~15-20 minutes once Unity's cache is warm.
4. On the iPad, the game shows its mod manager at start; tap Start. Mods can be turned off there
   like on the Mac.

Every Timberborn port also carries **TheSTouchscreen**, a mod of the port itself
(`recomp/builtin_mods/timberborn/TheSTouchscreen`, listed by the profile's `mods.builtin`): it is built
against the game and the port's shims when the game is ported, and goes through the same checks
and install as the Mac's mods (source *Built in*). It is the place for touch tweaks of the game's
own UI. Recomp Helper shows it in its own box (*Built into the port: TheSTouchscreen*) rather than with the Mac's
mods, on by default; turning it off there leaves it out of the next port (`recomp.py mods
--exclude TheSTouch.TheSTouchscreen`). On the iPad it can also be turned off in the game's mod list,
without porting again. Other built-in mods (say, a small-screen UI for iPhone) would sit next to
it in `mods.builtin`, each with its own box.

What happens during the port (`recomp/mods.py`):

- the mod folders the game's profile names (`mods.mac`: Timberborn's Mods folder and its Steam
  Workshop folder) are scanned, and for each mod the version folder the game itself would load
  (`version-1.1/`, …);
- each DLL is checked against the iOS class library and this game version (`asmtool check`). A mod
  that uses something missing (an outdated mod, or an API that needs code generated at run time)
  is skipped with the reason, rather than stopping the build;
- the DLLs that pass are compiled with the game. On the iPad, when the game loads a mod DLL, the
  [libil2cpp patch](../recomp/il2cpp_patches.py) recognises it by its SHA-256 and returns the
  compiled assembly. Until then the mod's code is hidden from the game, so a disabled mod stays
  off. A DLL that was not compiled in is skipped with one log line;
- Harmony mods: `0Harmony.dll` is replaced by a stand-in with Harmony's API
  ([recomp/shims/RecompHarmony](../recomp/shims/RecompHarmony)), whose `PatchAll` does nothing, and
  each mod's `[HarmonyPatch]` classes are woven into the game's assemblies (`asmtool harmony`).
  The woven patches only act once the game has loaded that mod. Supported: targets given in
  `[HarmonyPatch]` (method, getter, setter, constructor, with argument types) or by a
  `TargetMethod()` built from `AccessTools` lookups; prefixes (including ones that skip the
  original), postfixes, finalizers; `__instance`, `__result`, `__state`, `__runOriginal`,
  `__originalMethod`, `__exception`, `__0`…, `___field` and arguments by name; `Prepare()` and
  priorities. Not supported, reported per patch: transpilers, reverse patches, `TargetMethods()`,
  `__args`, patches made at run time with `harmony.Patch(...)`, and `AccessTools.FieldRefAccess`.

Mods for other Unity games need a `mods` block in the game's profile, and that game's mod loader
has to load DLLs with `Assembly.Load(bytes)` or `Assembly.LoadFrom(path)`.

## Steam runtime

iOS has no Steam app, so a port of a Steam game carries its own Steam client,
`recomp/native/RecompSteam`. It connects to Steam's servers over the same WebSocket connection the
Steam client uses, logs on as the player and serves the Steamworks API the game calls
(`SteamAPI_*`), so the game's own Steam code runs unchanged. Everything goes straight to Steam,
never through a server of this project. `SteamAPI_Init` succeeds in every port, signed in or not:
games such as Valheim quit without Steam.

### Sign-in and license check

At the first launch a sign-in screen covers the game (a Unity game is paused under it), and the
game plays once a Steam account that owns it has signed in. The check is made in good faith, not as
DRM: the source is public and anyone can remove it, but a port built with the released tool, or
shared with someone else, does not play without the game's license.

- **Signing in**: scan the QR code with the Steam Mobile app (Steam Guard, QR scanner), or enter
  the account name and password, then approve in the Steam Mobile app or type the Steam Guard
  code. The port signs in as a Steam client, through the service Steam's own apps sign in with;
  the password is encrypted with the key Steam gives for it. That one sign-in serves the license,
  Steam Cloud, achievements and online play. A port that holds a sign-in from before the runtime
  asks once to sign in again.
- **The check**: the session logs on and asks Steam to sign the game's ownership ticket, which
  Steam does for a game the account owns or borrows through Steam Family Sharing, and refuses
  otherwise.
- **What stays on the device**: the sign-in (a refresh token), the Steam ID and the date of
  the last check, in the Keychain for this device only; they are not in backups and do not travel
  with a copy of the app. `Documents/Recomp Steam license.txt` says which account was checked
  and when.
- **Each launch** checks again behind a "Checking your Steam license" screen, usually for a
  second. Offline or with Steam slow to answer, the game starts after a few seconds anyway, for
  30 days after the last successful check; past that it asks to go online. A refunded game or a
  sign-in removed in Steam brings the sign-in screen back at the next launch.
- **Playing on another device**: Steam lets an account play one game at a time. When it already
  plays elsewhere, the cover offers *Play here* (which ends the other session) or *Play without
  Steam for now*; the port never takes over silently.
- **Signing out**: delete `Recomp Steam license.txt` (Files, *On My iPad*, the game's folder);
  the session ends and the next launch asks to sign in again. Steam lists the sign-in as
  "Recomp: *game* on *device*" under Settings > Security > Authorized devices, where it can be
  removed.

When porting, the game's app id comes from its profile's `steam_app_id`, or from the
`appmanifest_<id>.acf` of the Steam library it is installed in. A game that ships Steamworks
but has neither (copied out of its Steam library, or not a Steam copy) is refused. Games
without Steamworks (GOG, itch and other DRM-free builds) get no check. The Mac side is
`recomp/steam_license.py`, the iOS side `recomp/native/RecompLicense.m` (both routes).

### What the game gets

| Steam feature | In the port |
|---|---|
| **Online status** | Steam shows the player in the game from `SteamAPI_Init`. Leaving the app clears it at once (iOS suspends a backgrounded app within seconds), coming back sets it again, quitting clears it |
| **Steam Cloud** | The game's cloud files, both the ones it writes through `ISteamRemoteStorage` (Valheim) and Auto-Cloud folders, on the device. Download at launch: the game's first Steam call waits for it (15 s at most), and after a first sign-in the cover stays up until it is done ("Getting your saves from Steam Cloud…", 90 s at most). Upload right after launch, when the app goes to the background and when the game quits. A save changed on both sides brings up a "Steam Cloud conflict" prompt; the version not kept goes to `Documents/Recomp Steam Cloud backup/` first, and `Documents/Recomp Steam Cloud.txt` shows the last sync. Offline, the game plays on its local files |
| **Achievements and stats** | `ISteamUserStats` for the player: the game's schema, stats and unlock times from Steam; `StoreStats` sends changes. `ResetAllStats` is refused, so a port never wipes the player's stats |
| **DLC** | Ownership from the ownership ticket, the DLC list and names from Steam's product info (kept for offline launches) |
| **Auth tickets** | `GetAuthSessionTicket` for servers and services that check the player (PlayFab's `LoginWithSteam`), `BeginAuthSession` to check other players when hosting |
| **Networking** | `ISteamNetworkingSockets` on Valve's open-source GameNetworkingSockets, with a networking certificate Steam signs for the player (profile key `steam_networking`) |
| **Server browser** | `ISteamMatchmakingServers`: the internet list from Steam's master server (up to 5000 servers) and A2S pings |
| **Persona** | The player's own name and online state |

A Steam game's saves always go through the Steam runtime, with no choice: Steam Cloud when the
game has it (its cloud rules must be in the Mac Steam app's cache), else the device only. iCloud
Drive ([Saves across devices](#saves-across-devices)) is for games without Steam, and `--saves
icloud|off` (Recomp Helper's port panel) only picks between those two for them.
`recomp.py saves <Game.app> --status` says which one the last port used.

Not there yet: the friends list, lobbies and invites, Steam's relay network (SDR) and FakeIP, so
no joining a friend's game through Steam and no hosting without crossplay; the overlay, the
Workshop, Steam Input and voice. Unreal games call Steam through C++ interface objects, which the
runtime does not offer yet: in Stray the session signs in, checks the license and shows the
player in the game, while the game itself is told Steam is not running (no achievements).

Tested: Valheim on the iPad (sign-in, license, online status, Steam Cloud both ways with the Mac
Steam game, conflict prompt included, online play below) and Stray on the iPad (sign-in, license,
online status). Achievements: Valheim's and Stray's are read as Steam has them, and an unlock
through the runtime (`recomp-steam-cli achievements`, the same functions the game calls) reached
Steam; an unlock from play on a device is not seen yet. Timberborn has not run on the runtime yet.

### Online play (Valheim)

- **Steam servers**: *Join IP* (with the server's password) and the *Community* list, over Valve's
  UDP protocol (GameNetworkingSockets). The server checks the player's auth ticket as it does for
  the Mac game.
- **Crossplay**: PlayFab Party, from Microsoft's iOS framework (`recomp/playfab_party.py` fetches
  v1.10.5 when porting, the only iOS release whose headers match Valheim's Mac bundle). Joining a
  crossplay server by join code and hosting a world with *Crossplay* on both work; PlayFab logs in
  with the Steam auth ticket.
- **Not yet**: joining a friend's game through Steam, and hosting without crossplay (both need
  Steam's relay network). A ping that answers has not been seen yet: the only server pinged was
  an old one that no longer answers.
- iOS asks for local network access the first time the game talks to the LAN (a server or a Party
  peer on the same network).

Steamworks.NET's server-list and ping callbacks are C++ objects made of instance delegates, which
IL2CPP cannot marshal; the profile key `responders` gives them static trampolines (`asmtool
responders`). `scripts/valheim-test-servers.sh up|status|logs|down` starts a throwaway Steam
server and a crossplay server in Docker (colima) on the Mac, reachable from the LAN.

### Debugging the runtime

- **Log file**: Unity ports write stdout and stderr, the game's own log included, to
  `Library/Logs/recomp.log` in the app's container (the previous run in `recomp.log.1`), one line
  at a time with a time stamp, so a crash keeps every line before it. Runtime lines start with
  `[recomp] steam:`, license lines with `[recomp] license:`. Read it from the Mac:
  `xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer
  --domain-identifier <bundle id> --source Library/Logs/recomp.log --destination <folder>`.
- **`recomp-steam-cli`** (`recomp/native/RecompSteam/cli/build.sh`): the runtime from Terminal,
  built from the same sources: `login` (QR, token in the Keychain), `logon`, `owns`, `ticket`,
  `ufs`, `playing`, `schema`, `achievements <appid> [unlock <name>]` (a real unlock).
- **Mac test clone**: `scripts/steam-mac-clone.py <Game.app>` makes an APFS clone of a Steam game
  whose `libsteam_api.dylib` is the runtime built for macOS, and starts it signed in with the
  CLI's token. It runs the runtime's code on the Mac, debuggable, without the Steam app. One
  account plays one game at a time: the clone and the Mac Steam game cannot run together.

## Saves across devices

Games without Steam whose profile has a `saves` block share their saves through iCloud Drive
(a Steam game's port syncs with Steam Cloud instead: [Steam runtime](#steam-runtime)), in `iCloud Drive/Recomp Saves/<Game>/`, which Files and Finder both show. No Apple ID
setup or iCloud entitlement is needed; it works with any developer account.

- **iPad / iPhone**: at the first launch the port asks "Sync saves with your other devices through
  iCloud Drive?". Choose folder, then pick iCloud Drive > Recomp Saves (or its `<Game>` folder;
  create it if it does not exist). The port then syncs at launch (before the game reads its saves,
  at most 15 s), when it goes to the background, when it quits, and every 5 minutes.
  "Not now" writes `Recomp Saves.txt` in the app's folder (Files > On My iPad > `<Game>`); delete it
  to be asked again. With sync on, that file shows the folder, the last sync and any errors; rename
  it to `Recomp Saves off.txt` to stop syncing.
- **Mac**: in Recomp Helper, select the game and turn on *Sync saves with iCloud Drive* (or
  `python3 recomp.py saves <Game.app> --enable`). The Mac game keeps saving to its usual folder and
  Steam Cloud keeps working; Recomp Helper copies the saves both ways right after the game quits,
  when saves arrive from iOS, and hourly. macOS asks once to let Recomp Helper read Documents and
  iCloud Drive, and lists it under Login Items > Allow in the Background (leave it on). The first
  `--enable` backs the saves up to `~/Library/Application Support/Recomp Helper/save-backups/`.
  `recomp.py saves <Game.app> --status|--sync|--disable` does the rest.

Rules:

- per file, the newest version wins;
- when a file changed on two devices since they last synced, the other version is kept next to it as
  `<name>.conflict-<device>-<yyyyMMdd-HHmm><ext>`. If both devices were offline at the same time,
  iCloud Drive may keep the second one as `<name> 2<ext>` instead. Nothing is lost either way;
- deleting a save never deletes it on other devices: delete it everywhere;
- a device's first sync compares dates only, so a fresh install's default file can win over older
  progress (the older one is kept as a conflict copy). Turn sync on before playing on a new device.

Limits:

- saves only move while the game is not running on the Mac, and while the port runs or is in the
  background on iOS;
- saves that need mods load only when the port has the same mods ([Mods](#mods-unity-ports));
- local (ad-hoc signed) builds of Recomp Helper are a new app to macOS each time, so it asks for
  folder access again after each rebuild. A Developer ID build does not.

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
- `scripts/`: app build, signing, notarization and icon; `steam-mac-clone.py`, `valheim-test-servers.sh`
- `recomp/discover.py`: game scanning and environment checks; `recomp/windows_games.py`: Windows installs; `recomp/compat.py`: tested / untested / needs-work checks; `recomp/events.py`: progress events and failure hints
- `recomp/unity_ios.py`, `recomp/toolchain.py`, `recomp/unity_editor/`: Unity route
- `recomp/unreal_ios.py`: Unreal route; `recomp/macho.py`: Mach-O retargeting; `recomp/iossdk.py`: what
  the iOS SDK exports; `recomp/xcodeproj.py`: minimal Xcode project
- `recomp/native/appkit/`: the shim for retargeted Mac binaries
- `recomp/air_ios.py`: AIR route (prepare, package, xcode, install); `recomp/native/air/`: the iOS
  stand-ins for the game's native extensions (`<id>.c`)
- `recomp/qt_ios.py`: Qt route (toolchain, prepare, xcode, install); `recomp/native/qt/`: its per-app
  shim, window fitting and test hooks; `recomp/ios_opengl.py`, `recomp/native/opengl/`: the iOS
  `OpenGL.framework` (gl4es and GLU); `recomp/patches/`: the Qt and gl4es patches
- `recomp/il2cpp_patches.py`: libil2cpp patches; `recomp/profiles/`: per-game and per-app rules (all routes)
- `recomp/textures.py`: BCn → ASTC texture conversion and asset bundle retargeting; `recomp/native/`:
  native start-up fixes, `RecompSaves.m`, the iOS side of the save sync, `RecompLicense.m`, the
  iOS side of the Steam license check, `RecompLog.m`, the log file; `recomp/native/RecompSteam/`:
  the Steam runtime (session, sign-in, Steamworks API, Steam Cloud, networking, matchmaking, `cli/`)
- `recomp/steam_license.py`: the Mac side of the Steam license check (the app id a port checks)
- `recomp/saves.py`: the Mac side of the save sync (`recomp.py saves`); `recomp/steam_cloud.py`: the save mode and Steam Cloud keys
- `recomp/gamenetworkingsockets.py`, `recomp/playfab_party.py`: build GameNetworkingSockets, fetch PlayFab Party's iOS framework (when porting, not in git)
- `recomp/mods.py`: mods compiled into Unity ports (`recomp.py mods`)
- `recomp/shims/`: managed shims injected into games; `recomp/shims/RecompHarmony`: the Harmony stand-in
- `docs/images/`: screenshots for the README (one per tested game, `<game>-ipad.jpg`, and `recomp-helper.png`)
- `docs/TECHNICAL.md`: this file
- `stubs/`: hand-written native stub overrides
- `tools/inspect_app.py`: triage; `tools/xref.py`: find code using a string; `tools/asmtool`: assembly scan/rewrite and Harmony weaving (Mono.Cecil); `tools/ilspy.sh`: decompiler
- `toolchain/`, `build/`: downloaded editors, Qt and gl4es sources and builds, the AIR SDK and Java, per-game work (not in git)
