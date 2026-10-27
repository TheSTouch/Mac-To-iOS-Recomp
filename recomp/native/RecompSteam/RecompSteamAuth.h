// Signing in to Steam as a Steam client (EAuthTokenPlatformType SteamClient), and the
// refresh token that sign-in leaves on this device. The session (RecompSteamSession.h)
// logs on with that token; one sign-in serves the license check, saves, achievements
// and online play.
//
// The sign-in talks to Steam's Authentication service over a CM connection, as the
// Steam client does (a SteamClient sign-in is not offered over api.steampowered.com).
//
// Like RecompSteamSession.h, this header only ever gains declarations.
#ifndef RECOMP_STEAM_AUTH_H
#define RECOMP_STEAM_AUTH_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// The refresh token stored on this device for app_id, malloc'd (free it), or NULL.
// Only a token from a SteamClient sign-in counts: an older MobileApp one cannot log on.
//   iOS: the Keychain item RecompLicense.m keeps (service "Recomp Steam license",
//        account "<app id>", JSON with "refresh").
//   macOS: $RECOMP_STEAM_TOKEN, else the Keychain item recomp-steam-cli stores through
//        /usr/bin/security (service "Recomp Steam", account "steam-client-token"), one for
//        every game.
char *RecompSteamAuth_StoredToken(uint32_t app_id);
// macOS: keeps token as the Keychain item above (recomp-steam-cli login). False on failure.
bool RecompSteamAuth_StoreToken(const char *refresh_token);
// Whether token is a SteamClient one (its "aud" claim lists "client").
bool RecompSteamAuth_IsClientToken(const char *refresh_token);
// The SteamID64 a token was issued to (0 if unreadable).
uint64_t RecompSteamAuth_TokenSteamID(const char *refresh_token);

// EAuthSessionGuardType, as allowed_confirmations lists them.
enum { RecompSteamGuardNone = 1, RecompSteamGuardEmailCode = 2, RecompSteamGuardDeviceCode = 3,
       RecompSteamGuardDeviceConfirmation = 4, RecompSteamGuardEmailConfirmation = 5 };

// Called with the sign-in's result: eresult OK with the tokens and account name, or the
// error (RecompSteamResultTimeout when Steam was not reached). Strings are valid during
// the call only. Runs on the session queue.
typedef void (^RecompSteamSignedIn)(int32_t eresult, const char *refresh_token, const char *access_token,
                                    const char *account_name);

// QR sign-in: challenge(url) runs with each QR code to show (it is renewed while
// waiting); approved() runs when the Steam Mobile app scanned it. Polls until the player
// approves, cancel, or timeout seconds (0: 10 minutes) pass. Returns a flow id.
int RecompSteamAuth_BeginQR(const char *device_name, double timeout, void (^challenge)(const char *url),
                            void (^scanned)(void), RecompSteamSignedIn done);

// Account name and password: guard(types, count, email_domain) runs when Steam Guard asks
// for a confirmation or a code (RecompSteamAuth_SubmitCode); then done as above.
int RecompSteamAuth_BeginPassword(const char *device_name, const char *account, const char *password,
                                  void (^guard)(const int *types, int count, const char *email_domain),
                                  RecompSteamSignedIn done);
// A Steam Guard code for the flow's account; done(eresult) says whether Steam took it.
void RecompSteamAuth_SubmitCode(int flow, const char *code, int code_type, void (^done)(int32_t eresult));
// Stops a flow: its callbacks no longer run.
void RecompSteamAuth_Cancel(int flow);

#ifdef __cplusplus
}
#endif
#endif
