// SteamAir native extension for AIR ports, on RecompSteam (recomp/native/RecompSteam): the port's
// own Steam session stands for the Steam client.
//
// Brawlhalla's ANE wraps libsteam_api's C++ interfaces; this does what each of its 23 functions
// does in the Mac library (its arm64 slice), through RecompSteam's flat API. air_ios.py links it
// with RecompSteam, the license cover (RecompLicense.m), the save sync and the log into the
// extension's arm64 slice; the armv7 slice is empty (ADT only checks that there is one).
//
// The game's ActionScript learns what happened through status events (FREDispatchStatusEventAsync,
// code and level as decimal strings), as from the Mac library:
//   1  the encrypted app ticket arrived, level = its EResult (the game then calls
//      SteamAir_GetEncryptedAppTicket); EResult 25 (limit exceeded) instead asks again 20 s later
//   2  MicroTxnAuthorizationResponse_t (level 1)       3  LicensesUpdated_t (level 1; asks for a
//   4  the ticket asked for after 3, level = EResult       new ticket)
//   5  UserStatsReceived_t (level 1)                   6  UserStatsStored_t, level = EResult
//   7  UserAchievementStored_t of an unlocked achievement, level = its name
//
// The ticket carries data the game's server checks: "em", then for each file of a list, 1 and
// the SHA-256 of the file (zeros when missing), then 0. The files are the Mac bundle's (its
// executable among them), so air_ios.py computes the data at port time from the Mac game and
// puts it in Info.plist "RecompAirTicketData" (hex: ADT takes no <data> in InfoAdditions).
//
// SteamAir_Init answers false (the game calls it again) until the session knows the player:
// logged on, or 15 s after the first call with a Steam ID from the stored sign-in (offline).
// Before the first sign-in on a device the Steam ID is 0, and the game reads it right after Init.

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CommonCrypto/CommonDigest.h>
#include "FlashRuntimeExtensions.h"
#include "RecompSteamFlat.h"

// RecompSteam's flat API (RecompSteamFlat.m, RecompSteamUser.m, RecompSteamStats.m).
bool SteamAPI_Init(void);
void SteamAPI_RunCallbacks(void);
bool SteamAPI_RestartAppIfNecessary(uint32_t app);
uint64_t SteamAPI_ISteamUser_GetSteamID(void *self);
uint64_t SteamAPI_ISteamUser_RequestEncryptedAppTicket(void *self, void *data, int length);
bool SteamAPI_ISteamUser_GetEncryptedAppTicket(void *self, void *ticket, int max, uint32_t *length);
const char *SteamAPI_ISteamFriends_GetPersonaName(void *self);
bool SteamAPI_ISteamApps_BIsSubscribed(void *self);
bool SteamAPI_ISteamApps_BIsDlcInstalled(void *self, uint32_t app);
uint64_t SteamAPI_ISteamApps_GetAppOwner(void *self);
bool SteamAPI_ISteamUtils_IsOverlayEnabled(void *self);
const char *SteamAPI_ISteamUtils_GetSteamUILanguage(void *self);
bool SteamAPI_ISteamUserStats_RequestCurrentStats(void *self);
bool SteamAPI_ISteamUserStats_GetAchievement(void *self, const char *name, bool *achieved);
bool SteamAPI_ISteamUserStats_SetAchievement(void *self, const char *name);
bool SteamAPI_ISteamUserStats_StoreStats(void *self);
bool SteamAPI_ISteamUserStats_ResetAllStats(void *self, bool achievements);

enum {
    k_iLicensesUpdated = 125, k_iMicroTxnAuthorizationResponse = 152, k_iEncryptedAppTicketResponse = 154,
    k_iUserStatsReceived = 1101, k_iUserStatsStored = 1102, k_iUserAchievementStored = 1103,
    k_EResultLimitExceeded = 25,
};
#pragma pack(push, 4)
typedef struct { uint32_t m_unAppID; uint64_t m_ulOrderID; uint8_t m_bAuthorized; } MicroTxnAuthorizationResponse_t;
typedef struct { uint64_t m_nGameID; int32_t m_eResult; } UserStatsStored_t;
typedef struct {
    uint64_t m_nGameID;
    bool m_bGroupAchievement;
    char m_rgchAchievementName[128];
    uint32_t m_nCurProgress, m_nMaxProgress;
} UserAchievementStored_t;
#pragma pack(pop)

static FREContext gCtx;
static bool gSteamInit, gStarted;
static double gFirstInit;
// The Mac library's SteamAir object: the last order, a ticket asked for after a purchase, the retry.
static uint64_t gOrderID, gTicketCall;
static uint32_t gOrderApp;
static bool gOrderAuthorized, gAfterPurchase, gRetry;
static double gRetryAt;

static double Now(void) { return CFAbsoluteTimeGetCurrent(); }

static void Dispatch(int code, const char *level)
{
    char c[16];
    snprintf(c, sizeof c, "%d", code);
    if (gCtx) FREDispatchStatusEventAsync(gCtx, (const uint8_t *)c, (const uint8_t *)level);
}

static void DispatchInt(int code, int level)
{
    char l[16];
    snprintf(l, sizeof l, "%d", level);
    Dispatch(code, l);
}

// --- the ticket ----------------------------------------------------------------------------------

static int Nibble(char c)
{
    return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
}

static CFDataRef TicketData(void)
{
    static CFDataRef data;
    static bool read;
    if (read) return data;
    read = true;
    CFTypeRef v = CFBundleGetValueForInfoDictionaryKey(CFBundleGetMainBundle(), CFSTR("RecompAirTicketData"));
    char hex[2048];
    if (!v || CFGetTypeID(v) != CFStringGetTypeID() ||
        !CFStringGetCString(v, hex, sizeof hex, kCFStringEncodingASCII)) {
        fprintf(stderr, "[air] Info.plist has no RecompAirTicketData: the ticket carries no game data\n");
        return NULL;
    }
    uint8_t bytes[1024];
    size_t n = 0;
    for (const char *p = hex; p[0] && p[1] && n < sizeof bytes; p += 2) {
        int hi = Nibble(p[0]), lo = Nibble(p[1]);
        if (hi < 0 || lo < 0) break;
        bytes[n++] = (uint8_t)(hi << 4 | lo);
    }
    data = CFDataCreate(NULL, bytes, (CFIndex)n);
    return data;
}

// SteamAir::SetupCallBacks: asks for a ticket around the game's data.
static void RequestTicket(void)
{
    CFDataRef d = TicketData();
    gRetry = false;
    gTicketCall = SteamAPI_ISteamUser_RequestEncryptedAppTicket(NULL, d ? (void *)CFDataGetBytePtr(d) : NULL,
                                                                d ? (int)CFDataGetLength(d) : 0);
    fprintf(stderr, "[air] RequestEncryptedAppTicket (%ld bytes of game data)\n", d ? (long)CFDataGetLength(d) : 0L);
}

// --- callbacks (SteamAPI_RunCallbacks hands them over) ------------------------------------------

static void OnCallback(int ident, void *data, size_t size, uint64_t call)
{
    if (call) {
        if (call != gTicketCall || ident != k_iEncryptedAppTicketResponse || size < 4) return;
        int32_t er;
        memcpy(&er, data, 4);
        fprintf(stderr, "[air] EncryptedAppTicketResponse: EResult %d\n", er);
        if (gAfterPurchase) {
            DispatchInt(4, er);
        } else if (er == k_EResultLimitExceeded) {
            gRetry = true;
            gRetryAt = Now() + 20;
        } else {
            DispatchInt(1, er);
        }
        gAfterPurchase = false;
        return;
    }
    switch (ident) {
    case k_iMicroTxnAuthorizationResponse:
        if (size >= sizeof(MicroTxnAuthorizationResponse_t)) {
            const MicroTxnAuthorizationResponse_t *r = data;
            gOrderApp = r->m_unAppID;
            gOrderID = r->m_ulOrderID;
            gOrderAuthorized = r->m_bAuthorized != 0;
            DispatchInt(2, 1);
        }
        break;
    case k_iLicensesUpdated:
        DispatchInt(3, 1);
        gAfterPurchase = true;
        RequestTicket();
        break;
    case k_iUserStatsReceived:
        DispatchInt(5, 1);
        break;
    case k_iUserStatsStored:
        if (size >= sizeof(UserStatsStored_t)) DispatchInt(6, ((const UserStatsStored_t *)data)->m_eResult);
        break;
    case k_iUserAchievementStored:
        if (size >= sizeof(UserAchievementStored_t)) {
            const UserAchievementStored_t *a = data;
            if (a->m_nCurProgress >= a->m_nMaxProgress) {
                char name[129];
                memcpy(name, a->m_rgchAchievementName, 128);
                name[128] = 0;
                Dispatch(7, name);
            }
        }
        break;
    }
}

// --- FRE helpers -----------------------------------------------------------------------------------

static FREObject newBool(int v) {
    FREObject r = NULL;
    FRENewObjectFromBool(v, &r);
    return r;
}

static FREObject newInt(int32_t v) {
    FREObject r = NULL;
    FRENewObjectFromInt32(v, &r);
    return r;
}

static FREObject newString(const char *s) {
    FREObject r = NULL;
    FRENewObjectFromUTF8((uint32_t)strlen(s) + 1, (const uint8_t *)s, &r);
    return r;
}

static FREObject newObject(const char *cls) {
    FREObject r = NULL;
    FRENewObject((const uint8_t *)cls, 0, NULL, &r, NULL);
    return r;
}

static int32_t argInt(uint32_t argc, FREObject argv[], uint32_t i) {
    int32_t v = 0;
    if (argc > i) FREGetObjectAsInt32(argv[i], &v);
    return v;
}

static const char *argString(uint32_t argc, FREObject argv[], uint32_t i) {
    const uint8_t *s = NULL;
    uint32_t n = 0;
    if (argc <= i || FREGetObjectAsUTF8(argv[i], &n, &s) != FRE_OK) return NULL;
    return (const char *)s;
}

// The first argument when it is a string (achievement names), for the console log.
static const char *argDesc(uint32_t argc, FREObject argv[]) {
    static char buf[160];
    const uint8_t *s = NULL;
    uint32_t n = 0;
    buf[0] = 0;
    for (uint32_t i = 0; i < argc && i < 2; i++)
        if (FREGetObjectAsUTF8(argv[i], &n, &s) == FRE_OK && s) {
            snprintf(buf, sizeof buf, " %.*s", (int)(n < 150 ? n : 150), (const char *)s);
            break;
        }
    return buf;
}

#define FN(name) static FREObject name##_(FREContext, uint32_t, FREObject[]); \
    static FREObject name(FREContext ctx, void *data, uint32_t argc, FREObject argv[]) { \
        fprintf(stderr, "[air] %s%s\n", #name, argDesc(argc, argv)); \
        return name##_(ctx, argc, argv); \
    } \
    static FREObject name##_(FREContext ctx, uint32_t argc, FREObject argv[])
// Called every frame (or retried until it succeeds): not logged.
#define QFN(name) static FREObject name(FREContext ctx, void *data, uint32_t argc, FREObject argv[])

// --- the functions -------------------------------------------------------------------------------

QFN(SteamAir_Init) {
    if (!gSteamInit) {
        gSteamInit = SteamAPI_Init();
        gFirstInit = Now();
        fprintf(stderr, "[air] SteamAir_Init: SteamAPI_Init %s\n", gSteamInit ? "ok" : "failed");
        if (!gSteamInit) return newBool(0);
        RS_RunRegisteredCallback = OnCallback;
    }
    if (!gStarted) {
        bool loggedOn = RecompSteam_State() == RecompSteamLoggedOn;
        if (!loggedOn && !(RS_SteamID() && Now() - gFirstInit >= 15)) return newBool(0);
        gStarted = true;
        fprintf(stderr, "[air] SteamAir_Init: %s\n", loggedOn ? "logged on" : "offline, stored sign-in");
        RequestTicket();
    }
    return newBool(1);
}

FN(SteamAir_RestartAppIfNecessary) {
    int32_t app = argInt(argc, argv, 0);
    return newBool(app ? SteamAPI_RestartAppIfNecessary((uint32_t)app) : 1);
}

QFN(SteamAir_RunCallbacks) {
    if (gStarted) {
        SteamAPI_RunCallbacks();
        if (gRetry && Now() >= gRetryAt) RequestTicket();
    }
    return NULL;
}

FN(SteamAir_IsSubscribedApp) {
    return newBool(argInt(argc, argv, 0) ? SteamAPI_ISteamApps_BIsSubscribed(NULL) : 1);
}

FN(SteamAir_BIsDLCInstalled) {
    int32_t app = argInt(argc, argv, 0);
    return newBool(app ? SteamAPI_ISteamApps_BIsDlcInstalled(NULL, (uint32_t)app) : 1);
}

FN(SteamAir_IsOverlayEnabled) { return newBool(SteamAPI_ISteamUtils_IsOverlayEnabled(NULL)); }
FN(SteamAir_IsSteamDeck) { return newBool(0); }
FN(SteamAir_GetPersonaName) { return newString(SteamAPI_ISteamFriends_GetPersonaName(NULL)); }

// SHA-256 (hex) of "hf873gf" and the app owner's Steam ID.
FN(SteamAir_GetPersonaID) {
    char text[64], hex[2 * CC_SHA256_DIGEST_LENGTH + 1];
    unsigned char md[CC_SHA256_DIGEST_LENGTH];
    snprintf(text, sizeof text, "hf873gf%lld", (long long)SteamAPI_ISteamApps_GetAppOwner(NULL));
    CC_SHA256(text, (CC_LONG)strlen(text), md);
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(hex + 2 * i, 3, "%02x", md[i]);
    return newString(hex);
}

FN(SteamAir_GetSteamID) {
    char s[32];
    snprintf(s, sizeof s, "%lld", (long long)SteamAPI_ISteamUser_GetSteamID(NULL));
    return newString(s);
}

FN(SteamAir_GetOrderID) {
    char s[32];
    snprintf(s, sizeof s, "%lld", (long long)gOrderID);
    return newString(s);
}

FN(SteamAir_GetLanguage) { return newString(SteamAPI_ISteamUtils_GetSteamUILanguage(NULL)); }

// The ticket's bytes, then its length: a Vector.<int> of 1025.
FN(SteamAir_GetEncryptedAppTicket) {
    uint8_t ticket[1024] = {0};
    uint32_t length = 0;
    if (!SteamAPI_ISteamUser_GetEncryptedAppTicket(NULL, ticket, sizeof ticket, &length)) length = 0;
    FREObject v = newObject("Vector.<int>");
    FRESetArrayLength(v, 1025);
    for (uint32_t i = 0; i < 1024; i++) FRESetArrayElementAt(v, i, newInt(ticket[i]));
    FRESetArrayElementAt(v, 1024, newInt((int32_t)length));
    fprintf(stderr, "[air] ticket handed over: %u bytes\n", length);
    return v;
}

FN(SteamAir_RequestNewTicketSilently) {
    RequestTicket();
    return NULL;
}

// [app id, order id, authorized]: no purchase is ever made from a port, so order 0.
FN(SteamAir_GetSteamOrder) {
    char s[32];
    FREObject a = newObject("Array");
    FRESetArrayLength(a, 3);
    snprintf(s, sizeof s, "%lld", (long long)gOrderID);
    FRESetArrayElementAt(a, 0, newInt((int32_t)gOrderApp));
    FRESetArrayElementAt(a, 1, newString(s));
    FRESetArrayElementAt(a, 2, newBool(gOrderAuthorized));
    return a;
}

// The avatar's pixels (ARGB): RecompSteam has no avatars, so none.
FN(SteamAir_GetIcon) { return newObject("Vector.<uint>"); }
// No Steam overlay on iOS.
FN(SteamAir_ActivateGameOverlayToUser) { return NULL; }
FN(SteamAir_ActivateGameOverlayToStore) { return NULL; }

// (index, name): the name is the second argument.
FN(SteamAir_TriggerAchievement) {
    const char *name = argString(argc, argv, 1);
    return newBool(name ? SteamAPI_ISteamUserStats_SetAchievement(NULL, name) : 0);
}

FN(SteamAir_GetAchievement) {
    const char *name = argString(argc, argv, 1);
    bool achieved = false;
    if (name) SteamAPI_ISteamUserStats_GetAchievement(NULL, name, &achieved);
    return newBool(achieved);
}

FN(SteamAir_PullAchievementDataFromSteam) { return newBool(SteamAPI_ISteamUserStats_RequestCurrentStats(NULL)); }

FN(SteamAir_CommitAchievementDataToSteam) {
    SteamAPI_ISteamUserStats_StoreStats(NULL);
    return NULL;
}

FN(SteamAir_DevClearAchievements) { return newBool(SteamAPI_ISteamUserStats_ResetAllStats(NULL, true)); }

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
    gCtx = ctx;
    *numFunctions = sizeof fns / sizeof fns[0];
    *functions = fns;
}

static void SteamAirContextFinalizer(FREContext ctx) {
    if (ctx == gCtx) gCtx = NULL;
}

void SteamAirExtInitializer(void **extData, FREContextInitializer *ctxInit, FREContextFinalizer *ctxFinal) {
    *extData = NULL;
    *ctxInit = SteamAirContextInitializer;
    *ctxFinal = SteamAirContextFinalizer;
}

void SteamAirExtFinalizer(void *extData) {}
