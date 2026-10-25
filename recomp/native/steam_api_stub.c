// Stand-in for libsteam_api.dylib on iOS, where there is no Steam client.
// SteamAPI_Init reports failure, which games and Unreal's Steam subsystem
// treat as "Steam not running" and continue without it.
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

typedef int32_t HSteamUser;

bool SteamAPI_Init(void) {
    fprintf(stderr, "[recomp] SteamAPI_Init: no Steam on iOS\n");
    return false;
}
bool SteamAPI_InitSafe(void) { return SteamAPI_Init(); }
bool SteamAPI_RestartAppIfNecessary(uint32_t appId) { return false; }
bool SteamAPI_IsSteamRunning(void) { return false; }
void SteamAPI_Shutdown(void) {}
void SteamAPI_RunCallbacks(void) {}
void SteamAPI_RegisterCallback(void *callback, int id) {}
void SteamAPI_UnregisterCallback(void *callback) {}
void SteamAPI_RegisterCallResult(void *callback, uint64_t call) {}
void SteamAPI_UnregisterCallResult(void *callback, uint64_t call) {}
HSteamUser SteamAPI_GetHSteamUser(void) { return 0; }
int32_t SteamAPI_GetHSteamPipe(void) { return 0; }
HSteamUser SteamGameServer_GetHSteamUser(void) { return 0; }
void SteamGameServer_RunCallbacks(void) {}
void SteamGameServer_Shutdown(void) {}
bool SteamInternal_GameServer_Init(uint32_t ip, uint16_t steamPort, uint16_t gamePort, uint16_t queryPort,
                                   int serverMode, const char *version) {
    return false;
}
void *SteamInternal_FindOrCreateUserInterface(HSteamUser user, const char *version) { return 0; }
void *SteamInternal_FindOrCreateGameServerInterface(HSteamUser user, const char *version) { return 0; }
void *SteamInternal_CreateInterface(const char *version) { return 0; }

// The SDK's accessors keep { init function, counter, context } and expect the
// context back after the init function has filled it (with null interfaces here).
struct ContextInitData {
    void (*init)(void *ctx);
    uintptr_t counter;
    char ctx[];
};

void *SteamInternal_ContextInit(void *data) {
    struct ContextInitData *d = data;
    if (d->counter != 1) {
        d->counter = 1;
        d->init(d->ctx);
    }
    return d->ctx;
}
