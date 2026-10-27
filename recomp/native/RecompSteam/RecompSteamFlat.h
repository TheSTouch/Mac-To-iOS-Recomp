// Shared by RecompSteam's Steamworks files (the flat API, the C++ interfaces, and the
// cloud and networking files of the other parts): interfaces, callbacks, ownership.
// Like RecompSteamSession.h, it only ever gains declarations.
#ifndef RECOMP_STEAM_FLAT_H
#define RECOMP_STEAM_FLAT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "RecompSteamAuth.h"
#include "RecompSteamSession.h"
#include "RecompSteamProto.h"

#ifdef __cplusplus
extern "C" {
#endif

// Interfaces the accessors hand out (SteamUser(), SteamClient()->GetISteamApps(), ...).
enum {
    RS_IClient, RS_IUser, RS_IFriends, RS_IUtils, RS_IApps, RS_IUserStats, RS_IMatchmaking,
    RS_IMatchmakingServers, RS_INetworking, RS_INetworkingSockets, RS_INetworkingUtils, RS_INetworkingMessages,
    RS_IRemoteStorage, RS_IUGC, RS_IGameServer, RS_IGameServerStats, RS_IHTTP, RS_IInput, RS_IController,
    RS_IScreenshots, RS_IInventory, RS_IOther, RS_INTERFACE_COUNT
};
// The object an accessor returns for an interface. A C++ implementation stores its
// object's address in RS_Interfaces[which] (before the game asks).
void *RS_Interface(int which);
extern void *RS_Interfaces[RS_INTERFACE_COUNT];
int RS_InterfaceForVersion(const char *version);

// Callbacks to the game, from any thread: delivered at its next RunCallbacks or
// ManualDispatch frame. ident is the struct's k_iCallback.
void RS_PostCallback(int ident, const void *data, size_t size);
// Call results: RS_NewCall gives the SteamAPICall_t to return to the game, then post
// the result struct under it when it is ready.
uint64_t RS_NewCall(void);
void RS_PostCallResult(uint64_t call, int ident, const void *data, size_t size);
// Runs hook on the game's thread once per callback frame (RunCallbacks / RunFrame).
void RS_AddFrameHook(void (*hook)(void));
void RS_Frame(void);
// Set by RecompSteamCpp.mm: runs the CCallbackBase objects registered for a callback.
extern void (*RS_RunRegisteredCallback)(int ident, void *data, size_t size, uint64_t call);

// Set (before SteamAPI_Init) by the libsteam_api of a C++ game (recomp/unreal_ios.py).
extern bool RS_CppGame;

// The player's SteamID, also before the first logon (from the stored token).
uint64_t RS_SteamID(void);
// Whether the account owns (or borrows) app: the game itself, or a DLC in its ownership ticket.
bool RS_OwnsApp(uint32_t app);
// Whose license the game is played on (the player, or a family member's account).
uint64_t RS_AppOwner(void);
// "Playing <game>" on Steam while the game runs (cleared at quit, and after a while in the background).
void RS_PresenceStart(void);
void RS_PresenceStop(void);

#ifdef __cplusplus
}
#endif
#endif
