// Steamworks as a signed-in user with no network, for games that refuse to run
// without Steam (a game profile selects it over steamworks.overrides.c).
// SteamAPI_Init succeeds and every interface is a dummy object; all other calls
// are generated as "return 0" by asmtool internalize, so the user has no friends,
// no stats, no cloud and no lobbies, and callbacks never arrive.
#include <stdlib.h>

static char recomp_steam_interface[256];
#define RECOMP_STEAM_INTERFACE ((void *)recomp_steam_interface)

__attribute__((used)) int SteamAPI_Init(void) { return 1; }
// ESteamAPIInitResult 0: OK.
__attribute__((used)) int SteamInternal_SteamAPI_Init(const char *versions, char *errMsg)
{
    (void)versions;
    if (errMsg) errMsg[0] = '\0';
    return 0;
}
__attribute__((used)) int SteamAPI_RestartAppIfNecessary(uint32_t appId) { (void)appId; return 0; }
__attribute__((used)) int SteamAPI_IsSteamRunning(void) { return 1; }
__attribute__((used)) int32_t SteamAPI_GetHSteamPipe(void) { return 1; }
__attribute__((used)) int32_t SteamAPI_GetHSteamUser(void) { return 1; }

__attribute__((used)) void *SteamInternal_CreateInterface(const char *version) { (void)version; return RECOMP_STEAM_INTERFACE; }
__attribute__((used)) void *SteamInternal_FindOrCreateUserInterface(int32_t user, const char *version)
{ (void)user; (void)version; return RECOMP_STEAM_INTERFACE; }
__attribute__((used)) void *SteamInternal_ContextInit(void *context) { (void)context; return RECOMP_STEAM_INTERFACE; }

__attribute__((used)) void *SteamAPI_ISteamClient_GetISteamAppList(void *client, int32_t user, int32_t pipe, const char *version) { return RECOMP_STEAM_INTERFACE; }
__attribute__((used)) void *SteamAPI_ISteamClient_GetISteamApps(void *client, int32_t user, int32_t pipe, const char *version) { return RECOMP_STEAM_INTERFACE; }
__attribute__((used)) void *SteamAPI_ISteamClient_GetISteamController(void *client, int32_t user, int32_t pipe, const char *version) { return RECOMP_STEAM_INTERFACE; }
__attribute__((used)) void *SteamAPI_ISteamClient_GetISteamFriends(void *client, int32_t user, int32_t pipe, const char *version) { return RECOMP_STEAM_INTERFACE; }
__attribute__((used)) void *SteamAPI_ISteamClient_GetISteamGameSearch(void *client, int32_t user, int32_t pipe, const char *version) { return RECOMP_STEAM_INTERFACE; }
__attribute__((used)) void *SteamAPI_ISteamClient_GetISteamGenericInterface(void *client, int32_t user, int32_t pipe, const char *version) { return RECOMP_STEAM_INTERFACE; }
__attribute__((used)) void *SteamAPI_ISteamClient_GetISteamHTMLSurface(void *client, int32_t user, int32_t pipe, const char *version) { return RECOMP_STEAM_INTERFACE; }
__attribute__((used)) void *SteamAPI_ISteamClient_GetISteamHTTP(void *client, int32_t user, int32_t pipe, const char *version) { return RECOMP_STEAM_INTERFACE; }
__attribute__((used)) void *SteamAPI_ISteamClient_GetISteamInput(void *client, int32_t user, int32_t pipe, const char *version) { return RECOMP_STEAM_INTERFACE; }
__attribute__((used)) void *SteamAPI_ISteamClient_GetISteamInventory(void *client, int32_t user, int32_t pipe, const char *version) { return RECOMP_STEAM_INTERFACE; }
__attribute__((used)) void *SteamAPI_ISteamClient_GetISteamMatchmaking(void *client, int32_t user, int32_t pipe, const char *version) { return RECOMP_STEAM_INTERFACE; }
__attribute__((used)) void *SteamAPI_ISteamClient_GetISteamMatchmakingServers(void *client, int32_t user, int32_t pipe, const char *version) { return RECOMP_STEAM_INTERFACE; }
__attribute__((used)) void *SteamAPI_ISteamClient_GetISteamMusic(void *client, int32_t user, int32_t pipe, const char *version) { return RECOMP_STEAM_INTERFACE; }
__attribute__((used)) void *SteamAPI_ISteamClient_GetISteamMusicRemote(void *client, int32_t user, int32_t pipe, const char *version) { return RECOMP_STEAM_INTERFACE; }
__attribute__((used)) void *SteamAPI_ISteamClient_GetISteamNetworking(void *client, int32_t user, int32_t pipe, const char *version) { return RECOMP_STEAM_INTERFACE; }
__attribute__((used)) void *SteamAPI_ISteamClient_GetISteamParentalSettings(void *client, int32_t user, int32_t pipe, const char *version) { return RECOMP_STEAM_INTERFACE; }
__attribute__((used)) void *SteamAPI_ISteamClient_GetISteamParties(void *client, int32_t user, int32_t pipe, const char *version) { return RECOMP_STEAM_INTERFACE; }
__attribute__((used)) void *SteamAPI_ISteamClient_GetISteamRemotePlay(void *client, int32_t user, int32_t pipe, const char *version) { return RECOMP_STEAM_INTERFACE; }
__attribute__((used)) void *SteamAPI_ISteamClient_GetISteamRemoteStorage(void *client, int32_t user, int32_t pipe, const char *version) { return RECOMP_STEAM_INTERFACE; }
__attribute__((used)) void *SteamAPI_ISteamClient_GetISteamScreenshots(void *client, int32_t user, int32_t pipe, const char *version) { return RECOMP_STEAM_INTERFACE; }
__attribute__((used)) void *SteamAPI_ISteamClient_GetISteamUGC(void *client, int32_t user, int32_t pipe, const char *version) { return RECOMP_STEAM_INTERFACE; }
__attribute__((used)) void *SteamAPI_ISteamClient_GetISteamUser(void *client, int32_t user, int32_t pipe, const char *version) { return RECOMP_STEAM_INTERFACE; }
__attribute__((used)) void *SteamAPI_ISteamClient_GetISteamUserStats(void *client, int32_t user, int32_t pipe, const char *version) { return RECOMP_STEAM_INTERFACE; }
__attribute__((used)) void *SteamAPI_ISteamClient_GetISteamVideo(void *client, int32_t user, int32_t pipe, const char *version) { return RECOMP_STEAM_INTERFACE; }
// GetISteamUtils takes (client, pipe, version); the arguments are ignored either way.
__attribute__((used)) void *SteamAPI_ISteamClient_GetISteamUtils(void *client, int32_t user, int32_t pipe, const char *version) { return RECOMP_STEAM_INTERFACE; }

// A fixed individual-account id (universe 1, type 1, instance 1, account 1):
// code that only accepts valid ids keeps going.
__attribute__((used)) uint64_t SteamAPI_ISteamUser_GetSteamID(void *self) { (void)self; return 0x0110000100000001ULL; }
__attribute__((used)) int SteamAPI_ISteamUser_BLoggedOn(void *self) { (void)self; return 1; }
__attribute__((used)) const char *SteamAPI_ISteamFriends_GetPersonaName(void *self) { (void)self; return "Player"; }
// The game's own app id, which its launcher sets in SteamAppId.
__attribute__((used)) uint32_t SteamAPI_ISteamUtils_GetAppID(void *self)
{
    (void)self;
    const char *id = getenv("SteamAppId");
    return id ? (uint32_t)strtoul(id, NULL, 10) : 0;
}
