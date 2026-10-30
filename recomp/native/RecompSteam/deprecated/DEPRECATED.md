# Deprecated: the old copy of the Steam client core

These files are kept for reference only. They are **no longer built**: no route compiles or
includes anything in this folder.

The Steam client core (the session, the sign-in, the protobuf codec, the Steam Cloud protocol)
now comes from [Kettle](https://github.com/TheSTouch/kettle), a git submodule at
`recomp/vendor/kettle` (`Sources/KettleExperimental`), pinned to a tag. Kettle is the source:
fixes to these files go to Kettle first, then the submodule moves to the new tag.
`recomp/steam_runtime.py` lists what each route builds.

| Here | In Kettle |
|---|---|
| `RecompSteamSession.m`, `.h` | `RecompSteamSession.m`, `include/RecompSteamSession.h` |
| `RecompSteamAuth.m`, `.h` | `RecompSteamAuth.m`, `include/RecompSteamAuth.h` |
| `RecompSteamProto.c`, `.h` | `RecompSteamProto.c`, `include/RecompSteamProto.h` |
| `RecompSteamUtil.c` | `RecompSteamUtil.c` |
| `RecompSteamInternal.h` | `RecompSteamInternal.h` |
| `cloud_protocol.m` | `cloud_protocol.m` |
| `cloud.h` (its Cloud service part) | `include/RecompSteamCloud.h` |

`cloud.h` here is the whole header as it was; the sync and launch parts still live in
`../cloud.h`, which builds on Kettle's `RecompSteamCloud.h`. `RS_GameAppID` and
`RecompSteam_StartStored`, which Kettle's headers no longer declare, are declared in
`../RecompSteamFlat.h`.
