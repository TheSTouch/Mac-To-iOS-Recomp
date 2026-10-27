// The Steamworks flat API on the session: what a game calls in libsteam_api, answered
// from RecompSteamSession.h. Steamworks.NET calls these by name (P/Invoke; on iOS they are
// linked in through asmtool internalize, which leaves out every name defined in
// RecompSteam/); Unreal's Steam subsystem reaches the same code through the C++
// interfaces of RecompSteamCpp.mm.
//
// Anything not defined here or in another RecompSteam file answers 0: on iOS asmtool's
// generated stubs, in the Mac clone and the Unreal libsteam_api stubs made from the
// game's own libsteam_api (scripts/steam-mac-clone.py, recomp/unreal_ios.py).
//
// Callbacks: the game polls, on its own thread, either with SteamAPI_RunCallbacks
// (registered CCallbackBase objects) or with SteamAPI_ManualDispatch_* (Steamworks.NET).
// Runtime code posts them from any thread with RS_PostCallback / RS_PostCallResult.
// Structs follow the SDK's packing on macOS and iOS: #pragma pack(4).
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <os/lock.h>
#include "RecompSteamFlat.h"
#include "RecompSteamInternal.h"

#define RLOG(...) RecompSteam_Log(__VA_ARGS__)
#define EXPORT __attribute__((used, visibility("default")))

// --- interfaces ----------------------------------------------------------------------------

// Each accessor hands out the address of one object per interface: the flat functions
// ignore it, the C++ route (RecompSteamCpp.mm) puts a vtable there.
void *RS_Interfaces[RS_INTERFACE_COUNT];
void *(*RS_InterfaceMakers[RS_INTERFACE_COUNT])(void);
static char gDummy[RS_INTERFACE_COUNT][64];

void *RS_Interface(int which)
{
    if (which < 0 || which >= RS_INTERFACE_COUNT) return NULL;
    if (!RS_Interfaces[which] && RS_InterfaceMakers[which]) RS_Interfaces[which] = RS_InterfaceMakers[which]();
    return RS_Interfaces[which] ? RS_Interfaces[which] : gDummy[which];
}

// The interface a version string ("SteamUser023", "STEAMAPPS_INTERFACE_VERSION008") names.
int RS_InterfaceForVersion(const char *version)
{
    static const struct { const char *prefix; int which; } map[] = {
        {"SteamClient", RS_IClient}, {"SteamUserStats", RS_IUserStats}, {"SteamUser", RS_IUser},
        {"SteamFriends", RS_IFriends}, {"SteamUtils", RS_IUtils}, {"STEAMAPPS_INTERFACE", RS_IApps},
        {"SteamMatchMakingServers", RS_IMatchmakingServers}, {"SteamMatchMaking", RS_IMatchmaking},
        {"SteamNetworkingSockets", RS_INetworkingSockets}, {"SteamNetworkingUtils", RS_INetworkingUtils},
        {"SteamNetworkingMessages", RS_INetworkingMessages}, {"SteamNetworking", RS_INetworking},
        {"STEAMREMOTESTORAGE_INTERFACE", RS_IRemoteStorage}, {"STEAMUGC_INTERFACE", RS_IUGC},
        {"SteamGameServerStats", RS_IGameServerStats}, {"SteamGameServer", RS_IGameServer},
        {"STEAMHTTP_INTERFACE", RS_IHTTP}, {"SteamInput", RS_IInput}, {"SteamController", RS_IController},
        {"STEAMSCREENSHOTS_INTERFACE", RS_IScreenshots}, {"STEAMINVENTORY_INTERFACE", RS_IInventory},
        {"SteamApps", RS_IApps},
    };
    if (!version) return RS_IOther;
    for (size_t i = 0; i < sizeof map / sizeof *map; i++)
        if (!strncmp(version, map[i].prefix, strlen(map[i].prefix))) return map[i].which;
    return RS_IOther;
}

EXPORT void *SteamInternal_CreateInterface(const char *version) { return RS_Interface(RS_InterfaceForVersion(version)); }
EXPORT void *SteamInternal_FindOrCreateUserInterface(int32_t user, const char *version)
{
    (void)user;
    return RS_Interface(RS_InterfaceForVersion(version));
}
EXPORT void *SteamInternal_FindOrCreateGameServerInterface(int32_t user, const char *version)
{
    (void)user;
    return RS_Interface(RS_InterfaceForVersion(version));
}
EXPORT void *SteamClient(void) { return RS_Interface(RS_IClient); }

// The SDK's inline accessors keep { init function, counter, context } and expect the
// context back after the init function filled it (calling the functions above).
struct RSContextInitData {
    void (*init)(void *ctx);
    uintptr_t counter;
    char ctx[];
};

EXPORT void *SteamInternal_ContextInit(void *data)
{
    struct RSContextInitData *d = data;
    static uintptr_t generation = 1;
    if (d->counter != generation) {
        d->init(d->ctx);
        d->counter = generation;
    }
    return d->ctx;
}

#define GETTER(Name, which) \
    EXPORT void *SteamAPI_ISteamClient_GetISteam##Name(void *self, int32_t user, int32_t pipe, const char *version) \
    { (void)self; (void)user; (void)pipe; (void)version; return RS_Interface(which); }
GETTER(User, RS_IUser)
GETTER(Friends, RS_IFriends)
GETTER(Apps, RS_IApps)
GETTER(UserStats, RS_IUserStats)
GETTER(Matchmaking, RS_IMatchmaking)
GETTER(MatchmakingServers, RS_IMatchmakingServers)
GETTER(Networking, RS_INetworking)
GETTER(RemoteStorage, RS_IRemoteStorage)
GETTER(UGC, RS_IUGC)
GETTER(GameServer, RS_IGameServer)
GETTER(GameServerStats, RS_IGameServerStats)
GETTER(HTTP, RS_IHTTP)
GETTER(Input, RS_IInput)
GETTER(Controller, RS_IController)
GETTER(Screenshots, RS_IScreenshots)
GETTER(Inventory, RS_IInventory)
GETTER(AppList, RS_IOther)
GETTER(GameSearch, RS_IOther)
GETTER(HTMLSurface, RS_IOther)
GETTER(Music, RS_IOther)
GETTER(MusicRemote, RS_IOther)
GETTER(ParentalSettings, RS_IOther)
GETTER(Parties, RS_IOther)
GETTER(RemotePlay, RS_IOther)
GETTER(Video, RS_IOther)
GETTER(GenericInterface, RS_IOther)
// GetISteamUtils takes (self, pipe, version).
EXPORT void *SteamAPI_ISteamClient_GetISteamUtils(void *self, int32_t pipe, const char *version)
{
    (void)self; (void)pipe; (void)version;
    return RS_Interface(RS_IUtils);
}
EXPORT int32_t SteamAPI_ISteamClient_CreateSteamPipe(void *self) { (void)self; return 1; }
EXPORT bool SteamAPI_ISteamClient_BReleaseSteamPipe(void *self, int32_t pipe) { (void)self; (void)pipe; return true; }
EXPORT int32_t SteamAPI_ISteamClient_ConnectToGlobalUser(void *self, int32_t pipe) { (void)self; (void)pipe; return 1; }

// --- init and shutdown ------------------------------------------------------------------------

static bool gInited;
bool RS_CppGame;
static double gStartedAt;

EXPORT bool SteamAPI_Init(void)
{
    if (gInited) return true;
    // Steam Cloud's launch pass (cloud_launch.m) finishes before the game reads its saves:
    // games with Auto-Cloud read their files directly, and this is the hook that runs
    // first. Looked up by name so this file does not depend on the cloud files.
    static void (*waitForCloud)(void);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ waitForCloud = (void (*)(void))dlsym(RTLD_DEFAULT, "RSCloudWaitForLaunch"); });
    if (waitForCloud) waitForCloud();
    RS_PresenceStart();
    // A C++ game (Unreal's Steam subsystem) calls the interfaces through their vtables:
    // until RecompSteamCpp.mm provides them, it is told there is no Steam, while the
    // session still signs in and shows the game as played.
    if (RS_CppGame && !RS_Interfaces[RS_IUser]) {
        RecompSteam_StartStored();
        RLOG("SteamAPI_Init: C++ interfaces not offered, reporting no Steam (the session runs)");
        return false;
    }
    // A port of a Steam game: Steam is "running" whether or not the player has signed in yet.
    // The license check covers the game until they have, and the session logs on behind it
    // (or stays offline within the grace period). Games such as Valheim quit without Steam.
    RecompSteam_StartStored();
    if (!RS_GameAppID() && !RecompSteam_AppID()) {
        RLOG("SteamAPI_Init: no Steam app id, reporting no Steam");
        return false;
    }
    gInited = true;
    gStartedAt = CFAbsoluteTimeGetCurrent();
    RLOG("SteamAPI_Init: app %u", RecompSteam_AppID());
    return true;
}
EXPORT bool SteamAPI_InitSafe(void) { return SteamAPI_Init(); }
// ESteamAPIInitResult: 0 OK, 1 failed generic.
EXPORT int SteamInternal_SteamAPI_Init(const char *versions, char *errMsg)
{
    (void)versions;
    bool ok = SteamAPI_Init();
    if (errMsg) snprintf(errMsg, 1024, "%s", ok ? "" : "No Steam sign-in on this device");
    return ok ? 0 : 1;
}
EXPORT int SteamAPI_InitFlat(char *errMsg) { return SteamInternal_SteamAPI_Init(NULL, errMsg); }
EXPORT bool SteamAPI_RestartAppIfNecessary(uint32_t app) { (void)app; return false; }
EXPORT bool SteamAPI_IsSteamRunning(void) { return gInited; }
EXPORT void SteamAPI_Shutdown(void)
{
    if (!gInited) return;
    gInited = false;
    RS_PresenceStop();
}
EXPORT int32_t SteamAPI_GetHSteamPipe(void) { return 1; }
EXPORT int32_t SteamAPI_GetHSteamUser(void) { return 1; }
EXPORT const char *SteamAPI_GetSteamInstallPath(void) { return ""; }
EXPORT void SteamAPI_ReleaseCurrentThreadMemory(void) {}

// --- callbacks ---------------------------------------------------------------------------------

#pragma pack(push, 4)
typedef struct {
    int32_t m_hSteamUser;
    int32_t m_iCallback;
    uint8_t *m_pubParam;
    int32_t m_cubParam;
} CallbackMsg_t;

typedef struct {
    uint64_t m_hAsyncCall;
    int32_t m_iCallback;
    uint32_t m_cubParam;
} SteamAPICallCompleted_t;
#pragma pack(pop)
enum { k_iSteamAPICallCompleted = 703 };

@interface RSCallback : NSObject
@property (nonatomic) int ident;
@property (nonatomic, strong) NSData *data;
@property (nonatomic) uint64_t call;   // 0 for a plain callback
@end
@implementation RSCallback
@end

static os_unfair_lock gCbLock = OS_UNFAIR_LOCK_INIT;
static NSMutableArray<RSCallback *> *gPending;                        // waiting to be dispatched
static NSMutableDictionary<NSNumber *, RSCallback *> *gResults;       // finished call results
static uint64_t gNextCall = 1;

void RS_PostCallback(int ident, const void *data, size_t size)
{
    RSCallback *c = [[RSCallback alloc] init];
    c.ident = ident;
    c.data = [NSData dataWithBytes:data length:size];
    os_unfair_lock_lock(&gCbLock);
    if (!gPending) gPending = [NSMutableArray array];
    [gPending addObject:c];
    os_unfair_lock_unlock(&gCbLock);
}

uint64_t RS_NewCall(void)
{
    os_unfair_lock_lock(&gCbLock);
    uint64_t call = gNextCall++;
    os_unfair_lock_unlock(&gCbLock);
    return call;
}

void RS_PostCallResult(uint64_t call, int ident, const void *data, size_t size)
{
    RSCallback *c = [[RSCallback alloc] init];
    c.ident = ident;
    c.call = call;
    c.data = [NSData dataWithBytes:data length:size];
    os_unfair_lock_lock(&gCbLock);
    if (!gPending) gPending = [NSMutableArray array];
    if (!gResults) gResults = [NSMutableDictionary dictionary];
    gResults[@(call)] = c;
    [gPending addObject:c];
    os_unfair_lock_unlock(&gCbLock);
}

static RSCallback *PopPending(void)
{
    os_unfair_lock_lock(&gCbLock);
    RSCallback *c = gPending.firstObject;
    if (c) [gPending removeObjectAtIndex:0];
    os_unfair_lock_unlock(&gCbLock);
    return c;
}

static RSCallback *TakeResult(uint64_t call, BOOL remove)
{
    os_unfair_lock_lock(&gCbLock);
    RSCallback *c = gResults[@(call)];
    if (c && remove) [gResults removeObjectForKey:@(call)];
    os_unfair_lock_unlock(&gCbLock);
    return c;
}

// Manual dispatch (Steamworks.NET).
static RSCallback *gLast;
static CallbackMsg_t gLastMsg;
static SteamAPICallCompleted_t gLastCompleted;

EXPORT void SteamAPI_ManualDispatch_Init(void) {}
EXPORT void SteamAPI_ManualDispatch_RunFrame(int32_t pipe) { (void)pipe; RS_Frame(); }
EXPORT bool SteamAPI_ManualDispatch_GetNextCallback(int32_t pipe, CallbackMsg_t *msg)
{
    (void)pipe;
    gLast = PopPending();
    if (!gLast) return false;
    gLastMsg.m_hSteamUser = 1;
    if (gLast.call) {
        // A finished call result is announced as SteamAPICallCompleted_t; the game then
        // fetches it with GetAPICallResult.
        gLastCompleted.m_hAsyncCall = gLast.call;
        gLastCompleted.m_iCallback = gLast.ident;
        gLastCompleted.m_cubParam = (uint32_t)gLast.data.length;
        gLastMsg.m_iCallback = k_iSteamAPICallCompleted;
        gLastMsg.m_pubParam = (uint8_t *)&gLastCompleted;
        gLastMsg.m_cubParam = sizeof gLastCompleted;
    } else {
        gLastMsg.m_iCallback = gLast.ident;
        gLastMsg.m_pubParam = (uint8_t *)gLast.data.bytes;
        gLastMsg.m_cubParam = (int32_t)gLast.data.length;
    }
    *msg = gLastMsg;
    return true;
}
EXPORT void SteamAPI_ManualDispatch_FreeLastCallback(int32_t pipe) { (void)pipe; gLast = nil; }

static bool CopyResult(uint64_t call, void *out, int size, int expected, bool *failed)
{
    RSCallback *c = TakeResult(call, YES);
    if (!c) return false;
    if (failed) *failed = c.ident != expected || (int)c.data.length > size;
    if (c.ident == expected && out) memcpy(out, c.data.bytes, MIN((size_t)size, c.data.length));
    return true;
}

EXPORT bool SteamAPI_ManualDispatch_GetAPICallResult(int32_t pipe, uint64_t call, void *out, int size, int expected,
                                                      bool *failed)
{
    (void)pipe;
    return CopyResult(call, out, size, expected, failed);
}
EXPORT bool SteamAPI_ISteamUtils_IsAPICallCompleted(void *self, uint64_t call, bool *failed)
{
    (void)self;
    bool done = TakeResult(call, NO) != nil;
    if (failed) *failed = false;
    return done;
}
EXPORT bool SteamAPI_ISteamUtils_GetAPICallResult(void *self, uint64_t call, void *out, int size, int expected,
                                                   bool *failed)
{
    (void)self;
    return CopyResult(call, out, size, expected, failed);
}
EXPORT int SteamAPI_ISteamUtils_GetAPICallFailureReason(void *self, uint64_t call) { (void)self; (void)call; return -1; }

// RunCallbacks (the SDK's own dispatch, for C++ games): CCallbackBase objects registered
// for an id, call results for a SteamAPICall_t. RecompSteamCpp.mm runs them; without it
// the callbacks are dropped.
void (*RS_RunRegisteredCallback)(int ident, void *data, size_t size, uint64_t call) = NULL;

EXPORT void SteamAPI_RunCallbacks(void)
{
    RS_Frame();
    RSCallback *c;
    while ((c = PopPending())) {
        if (c.call) TakeResult(c.call, YES);
        if (RS_RunRegisteredCallback) RS_RunRegisteredCallback(c.ident, (void *)c.data.bytes, c.data.length, c.call);
    }
}

// Once per game frame, on the game's thread.
static void (*gFrameHooks[8])(void);
void RS_AddFrameHook(void (*hook)(void))
{
    for (int i = 0; i < 8; i++)
        if (!gFrameHooks[i] || gFrameHooks[i] == hook) {
            gFrameHooks[i] = hook;
            return;
        }
}
void RS_Frame(void)
{
    for (int i = 0; i < 8 && gFrameHooks[i]; i++) gFrameHooks[i]();
}

// --- ISteamUser ------------------------------------------------------------------------------

// Before the first logon the SteamID comes from the stored token, so code that only
// accepts valid ids keeps going offline.
uint64_t RS_SteamID(void)
{
    uint64_t id = RecompSteam_SteamID();
    if (!id) {
        static uint64_t stored;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            char *token = RecompSteamAuth_StoredToken(RecompSteam_AppID());
            if (token) stored = RecompSteamAuth_TokenSteamID(token);
            free(token);
        });
        id = stored;
    }
    return id;
}

EXPORT uint64_t SteamAPI_ISteamUser_GetSteamID(void *self) { (void)self; return RS_SteamID(); }
EXPORT bool SteamAPI_ISteamUser_BLoggedOn(void *self) { (void)self; return RecompSteam_State() == RecompSteamLoggedOn; }
EXPORT int32_t SteamAPI_ISteamUser_GetHSteamUser(void *self) { (void)self; return 1; }
EXPORT int SteamAPI_ISteamUser_GetPlayerSteamLevel(void *self) { (void)self; return 1; }
EXPORT bool SteamAPI_ISteamUser_BIsBehindNAT(void *self) { (void)self; return true; }

// --- ISteamFriends (own persona) -------------------------------------------------------------

EXPORT const char *SteamAPI_ISteamFriends_GetPersonaName(void *self)
{
    (void)self;
    static char names[2][128];
    static int which;
    char *buf = names[which ^= 1];   // stays valid until the next call but one
    if (!RecompSteam_PersonaName(buf, 128)) snprintf(buf, 128, "Player");
    return buf;
}
// EPersonaState: 1 online, 0 offline.
EXPORT int SteamAPI_ISteamFriends_GetPersonaState(void *self) { (void)self; return RecompSteam_State() == RecompSteamLoggedOn; }
EXPORT const char *SteamAPI_ISteamFriends_GetFriendPersonaName(void *self, uint64_t friend_id)
{
    if (friend_id == RS_SteamID()) return SteamAPI_ISteamFriends_GetPersonaName(self);
    return "";
}

// --- ISteamUtils ---------------------------------------------------------------------------------

EXPORT uint32_t SteamAPI_ISteamUtils_GetAppID(void *self) { (void)self; return RecompSteam_AppID(); }
EXPORT uint32_t SteamAPI_ISteamUtils_GetServerRealTime(void *self) { (void)self; return RecompSteam_ServerTime(); }
EXPORT int SteamAPI_ISteamUtils_GetConnectedUniverse(void *self) { (void)self; return 1; }   // public
EXPORT uint32_t SteamAPI_ISteamUtils_GetSecondsSinceAppActive(void *self)
{
    (void)self;
    return gStartedAt ? (uint32_t)(CFAbsoluteTimeGetCurrent() - gStartedAt) : 0;
}
EXPORT uint32_t SteamAPI_ISteamUtils_GetSecondsSinceComputerActive(void *self) { (void)self; return 0; }
EXPORT const char *SteamAPI_ISteamUtils_GetSteamUILanguage(void *self) { (void)self; return "english"; }
EXPORT const char *SteamAPI_ISteamUtils_GetIPCountry(void *self) { (void)self; return ""; }
EXPORT uint8_t SteamAPI_ISteamUtils_GetCurrentBatteryPower(void *self) { (void)self; return 255; }
EXPORT bool SteamAPI_ISteamUtils_IsOverlayEnabled(void *self) { (void)self; return false; }

// --- ISteamApps (from the ownership ticket) --------------------------------------------------------

EXPORT const char *SteamAPI_ISteamApps_GetCurrentGameLanguage(void *self) { (void)self; return "english"; }
EXPORT const char *SteamAPI_ISteamApps_GetAvailableGameLanguages(void *self) { (void)self; return "english"; }
EXPORT bool SteamAPI_ISteamApps_BIsSubscribed(void *self) { (void)self; return RS_OwnsApp(RecompSteam_AppID()); }
EXPORT bool SteamAPI_ISteamApps_BIsSubscribedApp(void *self, uint32_t app) { (void)self; return RS_OwnsApp(app); }
EXPORT bool SteamAPI_ISteamApps_BIsAppInstalled(void *self, uint32_t app)
{
    (void)self;
    return app == RecompSteam_AppID();
}
EXPORT uint64_t SteamAPI_ISteamApps_GetAppOwner(void *self) { (void)self; return RS_AppOwner(); }
EXPORT bool SteamAPI_ISteamApps_BIsSubscribedFromFamilySharing(void *self)
{
    (void)self;
    uint64_t owner = RS_AppOwner();
    return owner && owner != RS_SteamID();
}
