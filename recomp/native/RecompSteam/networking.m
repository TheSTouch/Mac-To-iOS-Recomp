// ISteamNetworkingSockets and ISteamNetworkingUtils on Valve's open-source
// GameNetworkingSockets (recomp/gamenetworkingsockets.py, linked as static libraries). ARC.
//
// GNS's own flat API (SteamAPI_ISteamNetworkingSockets_*, ...) takes the interface object
// as its first argument, so the accessors hand out GNS's objects (RS_Interfaces) and the
// game's calls go straight to it. This file starts GNS as the player (their SteamID), runs
// its callbacks on the game's thread, turns connection status changes into the game's
// SteamNetConnectionStatusChangedCallback_t, and gets the player a networking certificate
// signed by Steam: a Steam game server (Valheim's, say) parks connections that present an
// unsigned one, even when it allows unauthenticated ones (IP_AllowWithoutAuth).
//
// The certificate: GNS makes a key pair and a request (GetCertificateRequest); the CM signs
// the public key (ClientNetworkingCertRequest 5621 -> ClientNetworkingCertRequestResponse
// 5622, whose fields 4-6 are those of CMsgSteamDatagramCertificateSigned), and GNS takes the
// reply as it is (SetCertificate). Renewed before it expires.
//
// Built only with RECOMP_GNS defined (the port sets it when it links GNS); without it the
// generated stubs answer and the game sees no networking.
#ifdef RECOMP_GNS
#import <Foundation/Foundation.h>
#include <os/lock.h>
#include <string.h>
#include "RecompSteamFlat.h"
#include "RecompSteamInternal.h"

#define RLOG(...) RecompSteam_Log(__VA_ARGS__)
#define EXPORT __attribute__((used, visibility("default")))

enum { RS_ClientNetworkingCertRequest = 5621, k_iSteamNetConnectionStatusChangedCallback = 1221 };
// sizeof(SteamNetConnectionStatusChangedCallback_t) with the SDK's pack(4), as Steamworks.NET marshals it.
enum { kStatusChangedSize = 704 };
// SteamNetworkingIdentity: 136 bytes, filled by GNS's own helpers.
typedef struct { uint8_t bytes[136]; } RSIdentity;
typedef struct { uint8_t bytes[18]; } RSIPAddr;
typedef char RSErrMsg[1024];

// GNS (C linkage; C++ references are pointers here).
bool GameNetworkingSockets_Init(const RSIdentity *identity, RSErrMsg *err);
void *SteamNetworkingSockets_LibV12(void);
void *SteamNetworkingUtils_LibV4(void);
void RecompGNS_SetAppID(uint32_t app);  // recomp/gamenetworkingsockets.py's patch
void SteamAPI_SteamNetworkingIdentity_Clear(RSIdentity *self);
void SteamAPI_SteamNetworkingIdentity_SetSteamID64(RSIdentity *self, uint64_t steamid);
void SteamAPI_ISteamNetworkingSockets_RunCallbacks(void *self);
bool SteamAPI_ISteamNetworkingSockets_GetCertificateRequest(void *self, int *length, void *blob, RSErrMsg *err);
bool SteamAPI_ISteamNetworkingSockets_SetCertificate(void *self, const void *cert, int length, RSErrMsg *err);
bool SteamAPI_ISteamNetworkingUtils_SetGlobalCallback_SteamNetConnectionStatusChanged(void *self, void (*fn)(void *));
void SteamNetworkingIPAddr_ToString(const RSIPAddr *addr, char *buf, size_t size, bool withPort);
bool SteamNetworkingIPAddr_ParseString(RSIPAddr *addr, const char *s);
int SteamNetworkingIPAddr_GetFakeIPType(const RSIPAddr *addr);
void SteamNetworkingIdentity_ToString(const RSIdentity *identity, char *buf, size_t size);
bool SteamNetworkingIdentity_ParseString(RSIdentity *identity, size_t size, const char *s);

static bool gStarted, gRunning;
static bool gCertPending;
// A signed certificate (or an empty NSData: refused) from the session's queue, for Frame.
static os_unfair_lock gCertLock = OS_UNFAIR_LOCK_INIT;
static NSData *gCertReply;
static uint64_t gCertExpiry;
static int32_t gCertResult;
static double gCertRenewAt;  // CFAbsoluteTime; 0 = when logged on

static void Frame(void);

static void StatusChanged(void *info)
{
    RS_PostCallback(k_iSteamNetConnectionStatusChangedCallback, info, kStatusChangedSize);
}

static void RequestCertificate(void)
{
    if (gCertPending || RecompSteam_State() != RecompSteamLoggedOn) return;
    void *sockets = SteamNetworkingSockets_LibV12();
    uint8_t blob[2048];
    int length = sizeof blob;
    RSErrMsg err = "";
    if (!SteamAPI_ISteamNetworkingSockets_GetCertificateRequest(sockets, &length, blob, &err)) {
        RLOG("networking: no certificate request: %s", err);
        gCertRenewAt = CFAbsoluteTimeGetCurrent() + 60;
        return;
    }
    // CMsgSteamDatagramCertificateRequest.cert (1) -> CMsgSteamDatagramCertificate.key_data (2):
    // the raw ed25519 public key the CM signs.
    rs_pb_field cert, key;
    if (!rs_pb_get(blob, (size_t)length, 1, &cert) || !rs_pb_get(cert.data, cert.length, 2, &key)) {
        RLOG("networking: unreadable certificate request");
        gCertRenewAt = CFAbsoluteTimeGetCurrent() + 3600;
        return;
    }
    rs_pb_writer w = {0};
    rs_pb_bytes(&w, 2, key.data, key.length);
    rs_pb_varint(&w, 3, RecompSteam_AppID());
    gCertPending = true;
    RecompSteam_SendJob(RS_ClientNetworkingCertRequest, w.data, w.length, 0, 30, ^(const RecompSteamMessage *reply) {
        rs_pb_field signedCert;
        bool ok = reply->eresult == RecompSteamResultOK && rs_pb_get(reply->body, reply->length, 4, &signedCert);
        uint64_t expiry = 0;
        if (ok) {
            // CMsgSteamDatagramCertificate.time_expiry (9), to renew a day before.
            rs_pb_field f;
            if (rs_pb_get(signedCert.data, signedCert.length, 9, &f)) expiry = f.varint;
        }
        // GNS's interface belongs to the game's thread: Frame installs it.
        os_unfair_lock_lock(&gCertLock);
        gCertReply = ok ? [NSData dataWithBytes:reply->body length:reply->length] : [NSData data];
        gCertExpiry = expiry;
        gCertResult = reply->eresult;
        os_unfair_lock_unlock(&gCertLock);
    });
    rs_pb_free(&w);
}

static void InstallCertificate(void)
{
    os_unfair_lock_lock(&gCertLock);
    NSData *body = gCertReply;
    uint64_t expiry = gCertExpiry;
    int32_t eresult = gCertResult;
    gCertReply = nil;
    os_unfair_lock_unlock(&gCertLock);
    if (!body) return;
    gCertPending = false;
    RSErrMsg err = "";
    if (!body.length || !SteamAPI_ISteamNetworkingSockets_SetCertificate(SteamNetworkingSockets_LibV12(), body.bytes, (int)body.length, &err)) {
        RLOG("networking: certificate refused (eresult %d) %s", eresult, err);
        gCertRenewAt = CFAbsoluteTimeGetCurrent() + 300;
        return;
    }
    double now = CFAbsoluteTimeGetCurrent();
    double left = expiry ? (double)expiry - (now + kCFAbsoluteTimeIntervalSince1970) : 0;
    gCertRenewAt = now + (left > 2 * 86400 ? left - 86400 : 3600);
    RLOG("networking: Steam signed the networking certificate (%.0f h left)", left / 3600);
}

// Starts GNS as the player, once: the first time the game asks for either interface
// (SteamAPI_Init). Its objects do not exist before GameNetworkingSockets_Init.
static void Start(void)
{
    if (gStarted) return;
    gStarted = true;
    RSIdentity identity;
    SteamAPI_SteamNetworkingIdentity_Clear(&identity);
    SteamAPI_SteamNetworkingIdentity_SetSteamID64(&identity, RS_SteamID());
    RSErrMsg err = "";
    if (!GameNetworkingSockets_Init(&identity, &err)) {
        RLOG("networking: GameNetworkingSockets_Init failed: %s", err);
        return;
    }
    // Steam's certificate is scoped to the game: GNS checks it against its own app id.
    RecompGNS_SetAppID(RecompSteam_AppID());
    SteamAPI_ISteamNetworkingUtils_SetGlobalCallback_SteamNetConnectionStatusChanged(SteamNetworkingUtils_LibV4(), StatusChanged);
    gRunning = true;
    RS_AddFrameHook(Frame);
}

static void *MakeSockets(void)
{
    Start();
    return gRunning ? SteamNetworkingSockets_LibV12() : NULL;
}

static void *MakeUtils(void)
{
    Start();
    return gRunning ? SteamNetworkingUtils_LibV4() : NULL;
}

static void Frame(void)
{
    InstallCertificate();
    SteamAPI_ISteamNetworkingSockets_RunCallbacks(SteamNetworkingSockets_LibV12());
    if (CFAbsoluteTimeGetCurrent() >= gCertRenewAt) RequestCertificate();
}

__attribute__((constructor)) static void RegisterNetworking(void)
{
    RS_InterfaceMakers[RS_INetworkingSockets] = MakeSockets;
    RS_InterfaceMakers[RS_INetworkingUtils] = MakeUtils;
}

// --- Steamworks flat functions GNS's flat API does not have --------------------------------------

EXPORT void SteamAPI_ISteamNetworkingUtils_SteamNetworkingIPAddr_ToString(void *self, const RSIPAddr *addr, char *buf, uint32_t size, bool withPort)
{
    (void)self;
    SteamNetworkingIPAddr_ToString(addr, buf, size, withPort);
}

EXPORT bool SteamAPI_ISteamNetworkingUtils_SteamNetworkingIPAddr_ParseString(void *self, RSIPAddr *addr, const char *s)
{
    (void)self;
    return SteamNetworkingIPAddr_ParseString(addr, s);
}

EXPORT int SteamAPI_ISteamNetworkingUtils_SteamNetworkingIPAddr_GetFakeIPType(void *self, const RSIPAddr *addr)
{
    (void)self;
    return SteamNetworkingIPAddr_GetFakeIPType(addr);
}

EXPORT void SteamAPI_ISteamNetworkingUtils_SteamNetworkingIdentity_ToString(void *self, const RSIdentity *identity, char *buf, uint32_t size)
{
    (void)self;
    SteamNetworkingIdentity_ToString(identity, buf, size);
}

EXPORT bool SteamAPI_ISteamNetworkingUtils_SteamNetworkingIdentity_ParseString(void *self, RSIdentity *identity, const char *s)
{
    (void)self;
    return SteamNetworkingIdentity_ParseString(identity, sizeof *identity, s);
}

#endif
