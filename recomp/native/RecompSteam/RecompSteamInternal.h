// Shared between RecompSteam's own files; not for other code (use RecompSteamSession.h).
#ifndef RECOMP_STEAM_INTERNAL_H
#define RECOMP_STEAM_INTERNAL_H

#include "RecompSteamSession.h"
#include "RecompSteamProto.h"

#ifdef __cplusplus
extern "C" {
#endif

// EMsg values used by the runtime.
enum {
    RS_Multi = 1, RS_ServiceMethod = 146, RS_ServiceMethodResponse = 147, RS_ServiceMethodCallFromClient = 151,
    RS_ClientHeartBeat = 703, RS_ClientLogOff = 706, RS_ClientChangeStatus = 716, RS_ClientGamesPlayed = 742,
    RS_ClientLogOnResponse = 751, RS_ClientLoggedOff = 757, RS_ClientPersonaState = 766, RS_ClientAccountInfo = 768,
    RS_ClientGameConnectTokens = 779, RS_ClientLicenseList = 780, RS_ClientRequestFriendData = 815,
    RS_ClientGetUserStats = 818, RS_ClientGetUserStatsResponse = 819, RS_ClientStoreUserStatsResponse = 821,
    RS_ClientGetAppOwnershipTicket = 857, RS_ClientGetAppOwnershipTicketResponse = 858,
    RS_ClientTicketAuthComplete = 5429, RS_ClientAuthList = 5432, RS_ClientStoreUserStats2 = 5466,
    RS_ClientLogon = 5514, RS_ClientAuthListAck = 5575,
    RS_ClientPICSProductInfoRequest = 8903, RS_ClientPICSProductInfoResponse = 8904,
    RS_ClientPICSAccessTokenRequest = 8905, RS_ClientPICSAccessTokenResponse = 8906,
    RS_ClientPlayingSessionState = 9600, RS_ClientKickPlayingSession = 9601,
    RS_ServiceMethodCallFromClientNonAuthed = 9804, RS_ClientHello = 9805,
};

#define RS_PROTOCOL_VERSION 65580

uint32_t rs_crc32(const void *data, size_t length);
// gunzip into a malloc'd buffer (*out, *out_length); false on failure.
bool rs_gunzip(const void *data, size_t length, size_t expected, uint8_t **out, size_t *out_length);

// The account's SteamID64 a refresh token was issued to (its JWT "sub"), 0 if unreadable.
uint64_t rs_token_steamid(const char *jwt);
// Whether the token's "aud" claim lists audience ("client": a Steam client sign-in).
bool rs_token_has_audience(const char *jwt, const char *audience);

#ifdef __cplusplus
}
#endif
#endif
