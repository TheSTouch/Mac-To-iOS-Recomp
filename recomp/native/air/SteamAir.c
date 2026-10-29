// SteamAir native extension for AIR ports, iOS stand-in: Steam is not running.
//
// Brawlhalla's ANE wraps libsteam_api's C++ interfaces. The game retries SteamAir_Init until it
// succeeds, so this first version reports Steam up with a local player who owns the game and has
// no ticket, which the game's own login can only fail. Function names and return types come from
// the Mac library's FRE calls.

#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include "FlashRuntimeExtensions.h"

static FREObject newBool(int v) {
    FREObject r = NULL;
    FRENewObjectFromBool(v, &r);
    return r;
}

static FREObject newString(const char *s) {
    FREObject r = NULL;
    uint32_t n = 0;
    while (s[n]) n++;
    FRENewObjectFromUTF8(n + 1, (const uint8_t *)s, &r);
    return r;
}

static FREObject newArray(void) {
    FREObject r = NULL;
    FRENewObject((const uint8_t *)"Array", 0, NULL, &r, NULL);
    return r;
}

// The first argument when it is a string (bank and event names), for the console log.
static const char *argDesc(uint32_t argc, FREObject argv[]) {
    static char buf[160];
    const uint8_t *s = NULL;
    uint32_t n = 0;
    buf[0] = 0;
    if (argc > 0 && FREGetObjectAsUTF8(argv[0], &n, &s) == FRE_OK && s)
        snprintf(buf, sizeof buf, " %.*s", (int)(n < 150 ? n : 150), (const char *)s);
    return buf;
}

#define FN(name) static FREObject name##_(FREContext, uint32_t, FREObject[]); \
    static FREObject name(FREContext ctx, void *data, uint32_t argc, FREObject argv[]) { \
        fprintf(stderr, "[air] %s%s\n", #name, argDesc(argc, argv)); \
        return name##_(ctx, argc, argv); \
    } \
    static FREObject name##_(FREContext ctx, uint32_t argc, FREObject argv[])
// Called every frame: not logged.
#define QFN(name) static FREObject name(FREContext ctx, void *data, uint32_t argc, FREObject argv[])

FN(SteamAir_Init) { return newBool(1); }
FN(SteamAir_RestartAppIfNecessary) { return newBool(0); }
QFN(SteamAir_RunCallbacks) { return NULL; }
FN(SteamAir_IsSubscribedApp) { return newBool(1); }
FN(SteamAir_BIsDLCInstalled) { return newBool(0); }
FN(SteamAir_IsOverlayEnabled) { return newBool(0); }
FN(SteamAir_IsSteamDeck) { return newBool(0); }
FN(SteamAir_GetPersonaName) { return newString("Player"); }
FN(SteamAir_GetPersonaID) { return newString(""); }
FN(SteamAir_GetSteamID) { return newString("76561197960265729"); }
FN(SteamAir_GetOrderID) { return newString(""); }
FN(SteamAir_GetLanguage) { return newString("english"); }
FN(SteamAir_GetEncryptedAppTicket) { return newArray(); }
FN(SteamAir_RequestNewTicketSilently) { return NULL; }
FN(SteamAir_GetSteamOrder) { return newArray(); }
FN(SteamAir_GetIcon) { return newArray(); }
FN(SteamAir_ActivateGameOverlayToUser) { return NULL; }
FN(SteamAir_ActivateGameOverlayToStore) { return NULL; }
FN(SteamAir_TriggerAchievement) { return newBool(0); }
FN(SteamAir_GetAchievement) { return newBool(0); }
FN(SteamAir_PullAchievementDataFromSteam) { return newBool(0); }
FN(SteamAir_CommitAchievementDataToSteam) { return NULL; }
FN(SteamAir_DevClearAchievements) { return newBool(0); }

#define ENTRY(name) {(const uint8_t *)#name, NULL, name}

static void SteamAirContextInitializer(void *extData, const uint8_t *ctxType, FREContext ctx,
                                       uint32_t *numFunctions, const FRENamedFunction **functions) {
    static const FRENamedFunction fns[] = {
        ENTRY(SteamAir_Init), ENTRY(SteamAir_RestartAppIfNecessary), ENTRY(SteamAir_RunCallbacks),
        ENTRY(SteamAir_IsSubscribedApp), ENTRY(SteamAir_BIsDLCInstalled), ENTRY(SteamAir_IsOverlayEnabled),
        ENTRY(SteamAir_IsSteamDeck), ENTRY(SteamAir_GetPersonaName), ENTRY(SteamAir_GetPersonaID),
        ENTRY(SteamAir_GetSteamID), ENTRY(SteamAir_GetOrderID), ENTRY(SteamAir_GetLanguage),
        ENTRY(SteamAir_GetEncryptedAppTicket), ENTRY(SteamAir_RequestNewTicketSilently),
        ENTRY(SteamAir_GetSteamOrder), ENTRY(SteamAir_GetIcon), ENTRY(SteamAir_ActivateGameOverlayToUser),
        ENTRY(SteamAir_ActivateGameOverlayToStore), ENTRY(SteamAir_TriggerAchievement),
        ENTRY(SteamAir_GetAchievement), ENTRY(SteamAir_PullAchievementDataFromSteam),
        ENTRY(SteamAir_CommitAchievementDataToSteam), ENTRY(SteamAir_DevClearAchievements),
    };
    *numFunctions = sizeof fns / sizeof fns[0];
    *functions = fns;
}

static void SteamAirContextFinalizer(FREContext ctx) {}

void SteamAirExtInitializer(void **extData, FREContextInitializer *ctxInit, FREContextFinalizer *ctxFinal) {
    *extData = NULL;
    *ctxInit = SteamAirContextInitializer;
    *ctxFinal = SteamAirContextFinalizer;
}

void SteamAirExtFinalizer(void *extData) {}
