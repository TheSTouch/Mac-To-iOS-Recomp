// Deprecated: built from recomp/vendor/kettle
// The pseudo Steam client's session: one logon to Steam's connection managers (CM)
// as the player, over a WebSocket, the way the Steam client does. Everything else in
// RecompSteam (the Steamworks flat API, cloud saves, online play) builds on this file.
//
// This header is frozen: it only ever gains declarations, so code built against it
// keeps working. Plain C with blocks (clang), usable from C, Objective-C and C++.
//
// Threading: the session runs on one serial dispatch queue (RecompSteam_Queue()).
// Every completion and handler below runs on that queue, never on the caller's
// thread; hop to the main queue for UI. The getters are safe from any thread.
#ifndef RECOMP_STEAM_SESSION_H
#define RECOMP_STEAM_SESSION_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <dispatch/dispatch.h>

#ifdef __cplusplus
extern "C" {
#endif

// --- state -------------------------------------------------------------------------

typedef enum {
    RecompSteamOffline = 0,      // not started, or no network: reconnects on its own
    RecompSteamConnecting = 1,   // looking up a CM, opening the WebSocket, logging on
    RecompSteamLoggedOn = 2,
    RecompSteamDenied = 3,       // Steam refused the sign-in (token revoked or expired): sign in again
} RecompSteamState;

// EResult values the session reports.
enum {
    RecompSteamResultOK = 1, RecompSteamResultFail = 2, RecompSteamResultNoConnection = 3,
    RecompSteamResultInvalidPassword = 5, RecompSteamResultLoggedInElsewhere = 6,
    RecompSteamResultAccessDenied = 15, RecompSteamResultRevoked = 26, RecompSteamResultExpired = 27,
    RecompSteamResultTimeout = 16, RecompSteamResultServiceUnavailable = 20, RecompSteamResultTryAnotherCM = 48,
};

RecompSteamState RecompSteam_State(void);
uint64_t RecompSteam_SteamID(void);          // the signed-in account's SteamID64, 0 before the first logon
uint32_t RecompSteam_AppID(void);            // the game's Steam app id
uint32_t RecompSteam_CellID(void);           // from the last logon (0 before)
uint32_t RecompSteam_PublicIP(void);         // IPv4 Steam sees, host order (0 before)
uint32_t RecompSteam_ServerTime(void);       // Steam's clock (Unix seconds), extrapolated from the logon
// The persona name; copies at most size-1 bytes and NUL-terminates. Returns its length.
size_t RecompSteam_PersonaName(char *out, size_t size);
// The dispatch queue every completion and handler runs on.
dispatch_queue_t RecompSteam_Queue(void);

// Runs handler (on the session queue) at each state change, and once at once with the
// current state. Returns an id for RecompSteam_RemoveObserver.
int RecompSteam_AddStateObserver(void (^handler)(RecompSteamState state));
void RecompSteam_RemoveObserver(int observer);

// Waits until the session is logged on, or until timeout seconds have passed, or Steam
// refused the sign-in; then runs done(logged on?) on the session queue. For a game's
// launch: do not block the main thread on it.
void RecompSteam_WhenLoggedOn(double timeout, void (^done)(bool loggedOn));

// --- starting -------------------------------------------------------------------------

// Logs on with a refresh token from a SteamClient sign-in (RecompSteamAuth.h) for
// app_id, and keeps the session up: heartbeats, reconnects with backoff. machine_name
// is how the session is labelled ("Recomp: <game> on <device>"). Calling it again with
// another token logs on again with it.
void RecompSteam_Start(const char *refresh_token, uint32_t app_id, const char *machine_name);
// Starts from what is stored on this device (RecompSteamAuth.h), if anything. Returns
// whether a token was found. Idempotent: does nothing when already started.
bool RecompSteam_StartStored(void);
// Logs off and stops reconnecting.
void RecompSteam_Stop(void);

// --- messages ---------------------------------------------------------------------------

// A message from Steam. body is valid only during the handler: copy what you keep.
typedef struct {
    uint32_t emsg;               // without the protobuf flag
    int32_t eresult;             // the header's eresult (RecompSteamResultTimeout when no answer came)
    const uint8_t *body;
    size_t length;
    uint64_t steamid;            // the header's
    uint64_t jobid_source, jobid_target;
    const char *target_job_name; // "Service.Method#1" for service messages, else NULL
    uint32_t routing_appid;
} RecompSteamMessage;

typedef void (^RecompSteamReply)(const RecompSteamMessage *reply);

// Sends a protobuf message (body: the encoded body, RecompSteamProto.h) while logged on.
// Dropped when not logged on.
void RecompSteam_Send(uint32_t emsg, const void *body, size_t length);
// The same, routed to an app (routing_appid; 0 for none), waiting for the answer Steam
// sends to this job (jobid_target): reply runs once, with the answer or, after timeout
// seconds (0: 20 s) or a disconnect, with eresult RecompSteamResultTimeout and no body.
void RecompSteam_SendJob(uint32_t emsg, const void *body, size_t length, uint32_t routing_appid,
                         double timeout, RecompSteamReply reply);

// A unified service method ("Cloud.ClientBeginFileUpload#1") with an encoded request:
// reply gets the encoded response and the header's eresult. Needs a logon; called
// before one, it waits for it (within timeout).
void RecompSteam_Call(const char *method, const void *request, size_t length, double timeout,
                      RecompSteamReply reply);
// The same without signing in (ServiceMethodCallFromClientNonAuthed), over a connection of
// its own: what the sign-in uses (Authentication.BeginAuthSessionViaQR#1 and so on).
void RecompSteam_CallUnauthed(const char *method, const void *request, size_t length, double timeout,
                              RecompSteamReply reply);

// Runs handler for every message of that EMsg (Steam's own pushes, and answers no job
// waits for). Returns an id for RecompSteam_Unsubscribe.
int RecompSteam_Subscribe(uint32_t emsg, RecompSteamReply handler);
// Runs handler for service notifications Steam sends ("CloudClient.NotifyX#1").
int RecompSteam_SubscribeService(const char *method, RecompSteamReply handler);
void RecompSteam_Unsubscribe(int subscription);

// --- playing --------------------------------------------------------------------------

// What the account plays (ClientGamesPlayed): shown on Steam as playing; an empty list
// clears it. Kept across reconnects.
void RecompSteam_GamesPlayed(const uint32_t *app_ids, int count);
// Steam's word on whether the account can play here: blocked when it plays on another
// device (Steam allows one game per account at a time). app is what it plays there.
bool RecompSteam_PlayingBlocked(uint32_t *app);
// The player chose "Play here": ends the game on the other device. Never call it
// without asking.
void RecompSteam_KickPlayingSession(void);

// --- tickets and ownership -------------------------------------------------------------

// The app ownership ticket Steam signs for app_id (cached until near expiry). eresult
// is Steam's: OK when the account owns or borrows the app, AccessDenied when it does not.
void RecompSteam_AppOwnershipTicket(uint32_t app_id,
                                    void (^done)(int32_t eresult, const uint8_t *ticket, size_t length));
// An auth session ticket for app_id (GC token + session header + ownership ticket, as
// ISteamUser::GetAuthSessionTicket makes them), activated with Steam (ClientAuthList).
// done runs once Steam acknowledged it; handle identifies it for RecompSteam_CancelTicket.
void RecompSteam_AuthSessionTicket(uint32_t app_id,
                                   void (^done)(int32_t eresult, uint32_t handle, const uint8_t *ticket, size_t length));
void RecompSteam_CancelTicket(uint32_t handle);

// Logging: "[recomp] steam: ..." to the system log (public os_log) and, in a Unity port on
// iOS, to its log file; on the Mac to stderr as well.
void RecompSteam_Log(const char *format, ...) __attribute__((format(printf, 1, 2)));
// A line for the port's log file only (recomp/native/RecompLog.m, Unity ports); a no-op where
// that file is not built in.
void RecompLog_Line(const char *line);

#ifdef __cplusplus
}
#endif
#endif
