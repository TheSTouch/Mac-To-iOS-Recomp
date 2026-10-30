// recomp-steam-cli: the RecompSteam runtime from Terminal, built from the same sources
// as the ports (cli/build.sh). For checking the runtime and for the Mac test clones.
//
//   login            sign in with a QR code (opened in Preview) as a Steam client; the
//                    refresh token goes to the Keychain (service "Recomp Steam")
//   logon            log on with the stored token and say who is signed in
//   owns <appid>     whether the account owns (or borrows) the app: its ownership ticket
//   ticket <appid>   play the app and make an auth session ticket, activated with Steam
//   appticket <appid> [data]
//                    an encrypted app ticket for the app, around data (none by default), through
//                    the runtime's ISteamUser::RequestEncryptedAppTicket; prints its fields, not the ticket
//   ufs <appid>      list the app's Steam Cloud files
//   playing          what Steam says the account plays on another device (presence check)
//   schema <appid>   save the app's stats schema (binary KeyValues) and the player's stats to $TMPDIR
//   achievements <appid> [unlock <name>]
//                    list the app's achievements and the player's, through the runtime's
//                    ISteamUserStats; unlock sets one and stores it on Steam (for real)
//   token            print the stored token (for scripts/steam-mac-clone.py)
#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#include "RecompSteamAuth.h"
#include "RecompSteamInternal.h"

bool SteamAPI_ISteamUserStats_RequestCurrentStats(void *self);
uint32_t SteamAPI_ISteamUserStats_GetNumAchievements(void *self);
const char *SteamAPI_ISteamUserStats_GetAchievementName(void *self, uint32_t index);
const char *SteamAPI_ISteamUserStats_GetAchievementDisplayAttribute(void *self, const char *name, const char *key);
bool SteamAPI_ISteamUserStats_GetAchievementAndUnlockTime(void *self, const char *name, bool *achieved, uint32_t *time);
bool SteamAPI_ISteamUserStats_SetAchievement(void *self, const char *name);
bool SteamAPI_ISteamUserStats_StoreStats(void *self);
uint64_t SteamAPI_ISteamUser_RequestEncryptedAppTicket(void *self, void *data, int length);
bool SteamAPI_ISteamUser_GetEncryptedAppTicket(void *self, void *ticket, int max, uint32_t *length);
bool SteamAPI_ISteamUtils_IsAPICallCompleted(void *self, uint64_t call, bool *failed);
bool SteamAPI_ISteamUtils_GetAPICallResult(void *self, uint64_t call, void *out, int size, int expected, bool *failed);

static void Out(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void Out(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    printf("%s\n", s.UTF8String);
    fflush(stdout);
}

static void Exit(int code) { fflush(stdout); exit(code); }

static NSString *WriteQR(const char *url)
{
    CIFilter *f = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [f setValue:[@(url) dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    [f setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *img = [f.outputImage imageByApplyingTransform:CGAffineTransformMakeScale(10, 10)];
    CIContext *ctx = [CIContext contextWithOptions:nil];
    CGImageRef cg = [ctx createCGImage:img fromRect:CGRectInset(img.extent, -40, -40)];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"recomp-steam-qr.png"];
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],
                                                                CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(dst, cg, NULL);
    CGImageDestinationFinalize(dst);
    CFRelease(dst);
    CGImageRelease(cg);
    return path;
}

static void Login(void)
{
    NSString *host = NSProcessInfo.processInfo.hostName;
    if ([host hasSuffix:@".local"]) host = [host substringToIndex:host.length - 6];
    NSString *name = [NSString stringWithFormat:@"Recomp: Mac test clone on %@", host];
    RecompSteamAuth_BeginQR(name.UTF8String, 900, ^(const char *url) {
        NSString *png = WriteQR(url);
        Out(@"QR code: %@ (opened in Preview). Scan it in the Steam Mobile app: Steam Guard > scan a QR code.", png);
        [NSTask launchedTaskWithLaunchPath:@"/usr/bin/open" arguments:@[@"-a", @"Preview", png]];
    }, ^{
        Out(@"scanned: approve the sign-in in the Steam Mobile app");
    }, ^(int32_t er, const char *refresh, const char *access, const char *account) {
        if (er != RecompSteamResultOK) {
            Out(@"sign-in failed: EResult %d", er);
            Exit(1);
        }
        if (!RecompSteamAuth_IsClientToken(refresh)) Out(@"warning: Steam did not issue a Steam client token");
        if (!RecompSteamAuth_StoreToken(refresh)) {
            Out(@"signed in, but the Keychain refused the token");
            Exit(1);
        }
        Out(@"signed in as %s; token kept in the Keychain (service \"Recomp Steam\")", account);
        Exit(0);
    });
}

static void WithLogon(uint32_t app, void (^then)(void))
{
    char *token = RecompSteamAuth_StoredToken(app);
    if (!token) {
        Out(@"no stored Steam client sign-in: run `recomp-steam-cli login` first");
        Exit(1);
    }
    RecompSteam_Start(token, app, "Recomp: recomp-steam-cli");
    free(token);
    RecompSteam_WhenLoggedOn(30, ^(bool ok) {
        if (!ok) {
            Out(@"not logged on (state %d)", RecompSteam_State());
            Exit(1);
        }
        then();
    });
}

static void Hex(const uint8_t *p, size_t n)
{
    NSMutableString *s = [NSMutableString string];
    for (size_t i = 0; i < n; i++) [s appendFormat:@"%02x", p[i]];
    Out(@"%@", s);
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        NSString *cmd = argc > 1 ? @(argv[1]) : @"";
        uint32_t app = argc > 2 ? (uint32_t)atoi(argv[2]) : 0;
        if (getenv("RECOMP_STEAM_QUIET")) setenv("RECOMP_STEAM_QUIET", "1", 1);
        if ([cmd isEqual:@"login"]) {
            Login();
        } else if ([cmd isEqual:@"token"]) {
            char *t = RecompSteamAuth_StoredToken(0);
            if (!t) Exit(1);
            printf("%s\n", t);
            Exit(0);
        } else if ([cmd isEqual:@"logon"]) {
            WithLogon(app, ^{
                char persona[128];
                RecompSteam_PersonaName(persona, sizeof persona);
                // Persona arrives just after the logon.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), RecompSteam_Queue(), ^{
                    char p[128];
                    RecompSteam_PersonaName(p, sizeof p);
                    Out(@"logged on: persona \"%s\", cell %u, Steam time %u", p, RecompSteam_CellID(),
                        RecompSteam_ServerTime());
                    RecompSteam_Stop();
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), RecompSteam_Queue(), ^{ Exit(0); });
                });
            });
        } else if ([cmd isEqual:@"playing"]) {
            WithLogon(app, ^{
                // What friends see: the account's own persona state, with the game it plays.
                RecompSteam_Subscribe(RS_ClientPersonaState, ^(const RecompSteamMessage *m) {
                    rs_pb_reader r = rs_pb_read(m->body, m->length);
                    rs_pb_field f;
                    while (rs_pb_next(&r, &f))
                        if (f.number == 2 && f.wire == RS_PB_BYTES &&
                            rs_pb_get_varint(f.data, f.length, 1, 0) == RecompSteam_SteamID()) {
                            char game[128];
                            rs_pb_get_string(f.data, f.length, 55, game, sizeof game);
                            Out(@"persona: playing app %llu %s", rs_pb_get_varint(f.data, f.length, 3, 0), game);
                        }
                });
                rs_pb_writer w = {0};
                rs_pb_varint(&w, 1, 0xFFFF);   // every persona field
                rs_pb_fixed64(&w, 2, RecompSteam_SteamID());
                RecompSteam_Send(RS_ClientRequestFriendData, w.data, w.length);
                rs_pb_free(&w);
                // ClientPlayingSessionState arrives just after the logon.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), RecompSteam_Queue(), ^{
                    uint32_t other = 0;
                    bool blocked = RecompSteam_PlayingBlocked(&other);
                    Out(blocked ? @"playing app %u on another device" : @"not blocked by another device (%u)", other);
                    RecompSteam_Stop();
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), RecompSteam_Queue(), ^{ Exit(0); });
                });
            });
        } else if ([cmd isEqual:@"schema"] && app) {
            WithLogon(app, ^{
                rs_pb_writer w = {0};
                rs_pb_fixed64(&w, 1, app);
                rs_pb_varint(&w, 3, (uint64_t)(int64_t)-1);
                rs_pb_fixed64(&w, 4, RecompSteam_SteamID());
                RecompSteam_SendJob(818, w.data, w.length, 0, 20, ^(const RecompSteamMessage *m) {
                    NSString *path = [NSTemporaryDirectory() stringByAppendingFormat:@"recomp-steam-stats-%u.bin", app];
                    [[NSData dataWithBytes:m->body length:m->length] writeToFile:path atomically:YES];
                    Out(@"EResult %llu, %zu bytes -> %@", rs_pb_get_varint(m->body, m->length, 2, 2), m->length, path);
                    Exit(0);
                });
                rs_pb_free(&w);
            });
        } else if ([cmd isEqual:@"achievements"] && app) {
            NSString *unlock = argc > 4 && !strcmp(argv[3], "unlock") ? @(argv[4]) : nil;
            WithLogon(app, ^{
                SteamAPI_ISteamUserStats_RequestCurrentStats(NULL);
                __block int tries = 0;
                __block void (^wait)(void);   // re-armed until the stats arrive, then cleared
                wait = ^{
                    if (!SteamAPI_ISteamUserStats_GetNumAchievements(NULL) && ++tries < 40) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), RecompSteam_Queue(), wait);
                        return;
                    }
                    uint32_t n = SteamAPI_ISteamUserStats_GetNumAchievements(NULL);
                    for (uint32_t i = 0; i < n; i++) {
                        const char *name = SteamAPI_ISteamUserStats_GetAchievementName(NULL, i);
                        bool on = false;
                        uint32_t when = 0;
                        SteamAPI_ISteamUserStats_GetAchievementAndUnlockTime(NULL, name, &on, &when);
                        Out(@"%s %-24s %s", on ? "X" : " ", name,
                            SteamAPI_ISteamUserStats_GetAchievementDisplayAttribute(NULL, name, "name"));
                    }
                    wait = nil;
                    if (!unlock) Exit(0);
                    bool set = SteamAPI_ISteamUserStats_SetAchievement(NULL, unlock.UTF8String);
                    bool stored = set && SteamAPI_ISteamUserStats_StoreStats(NULL);
                    Out(@"unlock %@: %s", unlock, stored ? "sent" : "unknown achievement");
                    // "stats stored: EResult ..." follows in the log.
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), RecompSteam_Queue(), ^{ Exit(0); });
                };
                wait();
            });
        } else if ([cmd isEqual:@"owns"] && app) {
            WithLogon(app, ^{
                RecompSteam_AppOwnershipTicket(app, ^(int32_t er, const uint8_t *t, size_t n) {
                    Out(@"app %u: %s (EResult %d, ticket %zu bytes)", app,
                        er == RecompSteamResultOK ? "owned" : "not owned", er, n);
                    Exit(er == RecompSteamResultOK ? 0 : 2);
                });
            });
        } else if ([cmd isEqual:@"ticket"] && app) {
            WithLogon(app, ^{
                RecompSteam_GamesPlayed(&app, 1);
                RecompSteam_AuthSessionTicket(app, ^(int32_t er, uint32_t handle, const uint8_t *t, size_t n) {
                    if (er != RecompSteamResultOK) {
                        Out(@"no ticket: EResult %d", er);
                        Exit(1);
                    }
                    Out(@"auth session ticket %u: %zu bytes, activated", handle, n);
                    Hex(t, n);
                    // Leave a few seconds for ClientTicketAuthComplete to show in the log.
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), RecompSteam_Queue(), ^{
                        RecompSteam_GamesPlayed(NULL, 0);
                        RecompSteam_Stop();
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), RecompSteam_Queue(), ^{ Exit(0); });
                    });
                });
            });
        } else if ([cmd isEqual:@"appticket"] && app) {
            NSData *data = argc > 3 ? [@(argv[3]) dataUsingEncoding:NSUTF8StringEncoding] : [NSData data];
            WithLogon(app, ^{
                uint64_t call = SteamAPI_ISteamUser_RequestEncryptedAppTicket(NULL, (void *)data.bytes, (int)data.length);
                __block int tries = 0;
                __block void (^wait)(void);   // re-armed until the call result is posted, then cleared
                wait = ^{
                    if (!SteamAPI_ISteamUtils_IsAPICallCompleted(NULL, call, NULL)) {
                        if (++tries < 120) {
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), RecompSteam_Queue(), wait);
                            return;
                        }
                        Out(@"no EncryptedAppTicketResponse after 30 s");
                        Exit(1);
                    }
                    wait = nil;
                    int32_t er = 0;
                    bool failed = false;
                    SteamAPI_ISteamUtils_GetAPICallResult(NULL, call, &er, sizeof er, 154, &failed);
                    uint8_t ticket[2048];
                    uint32_t n = 0;
                    bool got = SteamAPI_ISteamUser_GetEncryptedAppTicket(NULL, ticket, sizeof ticket, &n);
                    Out(@"app %u: EResult %d, encrypted app ticket %s, %u bytes", app, er, got ? "kept" : "none", n);
                    if (got)
                        Out(@"  version %llu, crc %08llx, %llu bytes of encrypted game data, %llu of ownership ticket, "
                            @"%zu encrypted", rs_pb_get_varint(ticket, n, 1, 0), rs_pb_get_varint(ticket, n, 2, 0),
                            rs_pb_get_varint(ticket, n, 3, 0), rs_pb_get_varint(ticket, n, 4, 0),
                            ({ rs_pb_field f = {0}; rs_pb_get(ticket, n, 5, &f); f.length; }));
                    Exit(er == RecompSteamResultOK && got ? 0 : 2);
                };
                wait();
            });
        } else if ([cmd isEqual:@"ufs"] && app) {
            WithLogon(app, ^{
                rs_pb_writer w = {0};
                rs_pb_varint(&w, 1, app);
                rs_pb_bool(&w, 2, true);
                rs_pb_varint(&w, 3, 500);
                RecompSteam_Call("Cloud.EnumerateUserFiles#1", w.data, w.length, 20, ^(const RecompSteamMessage *m) {
                    if (m->eresult != RecompSteamResultOK) {
                        Out(@"Cloud.EnumerateUserFiles: EResult %d", m->eresult);
                        Exit(1);
                    }
                    Out(@"%llu files", rs_pb_get_varint(m->body, m->length, 2, 0));
                    rs_pb_reader r = rs_pb_read(m->body, m->length);
                    rs_pb_field f;
                    while (rs_pb_next(&r, &f)) {
                        if (f.number != 1 || f.wire != RS_PB_BYTES) continue;
                        char name[512];
                        rs_pb_get_string(f.data, f.length, 3, name, sizeof name);
                        Out(@"  %-60s %8llu bytes  root %llu", name, rs_pb_get_varint(f.data, f.length, 5, 0),
                            rs_pb_get_varint(f.data, f.length, 8, 0));
                    }
                    Exit(0);
                });
                rs_pb_free(&w);
            });
        } else {
            fprintf(stderr, "usage: recomp-steam-cli login | logon | playing | owns <appid> | ticket <appid> | appticket <appid> [data] | ufs <appid> | token\n");
            return 2;
        }
        dispatch_main();
    }
}
