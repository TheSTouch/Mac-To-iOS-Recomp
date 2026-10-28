// ISteamUser's tickets and auth sessions, and ISteamApps' DLC, for the flat API. ARC.
//
// GetAuthSessionTicket hands the game its ticket at once (built from the ownership ticket
// and a GC token the session keeps) and posts GetAuthSessionTicketResponse_t once Steam
// acknowledged it; servers and PlayFab check it with Steam. BeginAuthSession checks
// another player's ticket the same way (ClientAuthList) and posts
// ValidateAuthTicketResponse_t with Steam's answer.
//
// DLC: the app's list ("extended/listofdlc") and each DLC's name come from Steam's product
// info (PICS), kept in the user defaults for offline launches; ownership comes from the
// ownership ticket (RecompSteamApps.m).
#import <Foundation/Foundation.h>
#include <os/lock.h>
#include "RecompSteamFlat.h"
#include "RecompSteamInternal.h"

#define RLOG(...) RecompSteam_Log(__VA_ARGS__)
#define EXPORT __attribute__((used, visibility("default")))

#pragma pack(push, 4)
typedef struct { uint32_t m_hAuthTicket; int32_t m_eResult; } GetAuthSessionTicketResponse_t;     // 163
typedef struct { uint64_t m_SteamID; int32_t m_eAuthSessionResponse; uint64_t m_OwnerSteamID; } ValidateAuthTicketResponse_t;  // 143
#pragma pack(pop)
enum { k_iGetAuthSessionTicketResponse = 163, k_iValidateAuthTicketResponse = 143 };

// --- ISteamUser ---------------------------------------------------------------------------------

// The SDK's last argument (a SteamNetworkingIdentity, SDK 1.57+) names who the ticket is for;
// Steam does not need it for the ticket itself.
EXPORT uint32_t SteamAPI_ISteamUser_GetAuthSessionTicket(void *self, void *ticket, int max, uint32_t *length,
                                                          const void *identity)
{
    (void)self; (void)identity;
    uint32_t n = 0;
    uint32_t handle = RS_AuthSessionTicketNow(RecompSteam_AppID(), ticket, max > 0 ? (size_t)max : 0, &n,
                                              ^(int32_t er, uint32_t h) {
        GetAuthSessionTicketResponse_t r = {h, er};
        RLOG("GetAuthSessionTicketResponse (163) posted: ticket %u, EResult %d", h, er);
        RS_PostCallback(k_iGetAuthSessionTicketResponse, &r, sizeof r);
    });
    if (length) *length = handle ? n : 0;
    RLOG("GetAuthSessionTicket: %s (%u bytes)", handle ? "ticket" : "none, not logged on", handle ? n : 0);
    return handle;
}

EXPORT void SteamAPI_ISteamUser_CancelAuthTicket(void *self, uint32_t handle)
{
    (void)self;
    RecompSteam_CancelTicket(handle);
}

// EBeginAuthSessionResult
EXPORT int SteamAPI_ISteamUser_BeginAuthSession(void *self, const void *ticket, int length, uint64_t steamid)
{
    (void)self;
    int r = RS_BeginAuthSession(RecompSteam_AppID(), ticket, length > 0 ? (size_t)length : 0, steamid,
                                ^(uint32_t response, uint64_t owner) {
        ValidateAuthTicketResponse_t v = {steamid, (int32_t)response, owner ? owner : steamid};
        RS_PostCallback(k_iValidateAuthTicketResponse, &v, sizeof v);
    });
    RLOG("BeginAuthSession: result %d", r);
    return r;
}

EXPORT void SteamAPI_ISteamUser_EndAuthSession(void *self, uint64_t steamid)
{
    (void)self;
    RS_EndAuthSession(steamid);
}

// EUserHasLicenseForAppResult: 0 has it, 1 does not, 2 no auth session for that user.
EXPORT int SteamAPI_ISteamUser_UserHasLicenseForApp(void *self, uint64_t steamid, uint32_t app)
{
    (void)self;
    if (steamid != RS_SteamID()) return 2;
    return RS_OwnsApp(app) ? 0 : 1;
}

// --- DLC -----------------------------------------------------------------------------------------

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static NSArray<NSDictionary *> *gDLC;   // [{app, name}], in the app's order

static NSString *DefaultsKey(void) { return [NSString stringWithFormat:@"RecompSteamDLC.%u", RecompSteam_AppID()]; }

static NSArray *DLCList(void)
{
    os_unfair_lock_lock(&gLock);
    NSArray *list = gDLC;
    os_unfair_lock_unlock(&gLock);
    if (!list) {
        id saved = [NSUserDefaults.standardUserDefaults arrayForKey:DefaultsKey()];
        list = [saved isKindOfClass:NSArray.class] ? saved : @[];
        os_unfair_lock_lock(&gLock);
        if (!gDLC) gDLC = list;
        os_unfair_lock_unlock(&gLock);
    }
    return list;
}

// The value of the first "key" "value" pair in a text KeyValues document, after `after`.
static NSString *VDFValue(NSString *vdf, NSString *key, NSString *after)
{
    NSRange from = after ? [vdf rangeOfString:[NSString stringWithFormat:@"\"%@\"", after]] : NSMakeRange(0, 0);
    if (from.location == NSNotFound) return nil;
    NSString *pattern = [NSString stringWithFormat:@"\"%@\"\\s+\"([^\"]*)\"", [NSRegularExpression escapedPatternForString:key]];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
    NSRange search = NSMakeRange(NSMaxRange(from), vdf.length - NSMaxRange(from));
    NSTextCheckingResult *m = [re firstMatchInString:vdf options:0 range:search];
    return m ? [vdf substringWithRange:[m rangeAtIndex:1]] : nil;
}

// Product info (text KeyValues) for apps: done({app: vdf}) on the session queue.
static void ProductInfo(NSArray<NSNumber *> *apps, void (^done)(NSDictionary<NSNumber *, NSString *> *info))
{
    rs_pb_writer w = {0};
    for (NSNumber *app in apps) {
        rs_pb_writer a = {0};
        rs_pb_varint(&a, 1, app.unsignedIntValue);
        rs_pb_message(&w, 2, &a);
        rs_pb_free(&a);
    }
    rs_pb_bool(&w, 3, false);
    RecompSteam_SendJob(RS_ClientPICSProductInfoRequest, w.data, w.length, 0, 30, ^(const RecompSteamMessage *m) {
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        rs_pb_reader r = rs_pb_read(m->body, m->length);
        rs_pb_field f;
        while (rs_pb_next(&r, &f)) {
            if (f.number != 1 || f.wire != RS_PB_BYTES) continue;
            uint32_t app = (uint32_t)rs_pb_get_varint(f.data, f.length, 1, 0);
            rs_pb_field buf;
            if (!rs_pb_get(f.data, f.length, 5, &buf)) continue;
            NSString *vdf = [[NSString alloc] initWithBytes:buf.data length:buf.length encoding:NSUTF8StringEncoding];
            if (vdf) info[@(app)] = vdf;
        }
        done(info);
    });
    rs_pb_free(&w);
}

static void FetchDLC(void)
{
    uint32_t app = RecompSteam_AppID();
    ProductInfo(@[@(app)], ^(NSDictionary *info) {
        NSString *list = VDFValue(info[@(app)], @"listofdlc", @"extended");
        NSMutableArray *ids = [NSMutableArray array];
        for (NSString *s in [list componentsSeparatedByString:@","])
            if (s.intValue > 0) [ids addObject:@(s.intValue)];
        if (!info[@(app)]) {
            RLOG("no product info for app %u", app);
            return;
        }
        void (^keep)(NSDictionary *) = ^(NSDictionary *names) {
            NSMutableArray *dlc = [NSMutableArray array];
            for (NSNumber *d in ids)
                [dlc addObject:@{@"app": d, @"name": VDFValue(names[d], @"name", @"common") ?: @""}];
            os_unfair_lock_lock(&gLock);
            gDLC = dlc;
            os_unfair_lock_unlock(&gLock);
            [NSUserDefaults.standardUserDefaults setObject:dlc forKey:DefaultsKey()];
            int owned = 0;
            for (NSNumber *d in ids) owned += RS_OwnsApp(d.unsignedIntValue);
            RLOG("app %u: %lu DLC, %d owned", app, (unsigned long)ids.count, owned);
        };
        if (ids.count) ProductInfo(ids, keep);
        else keep(@{});
    });
}

__attribute__((constructor)) static void WatchLogon(void)
{
    RecompSteam_AddStateObserver(^(RecompSteamState s) {
        static BOOL fetched;
        if (s == RecompSteamLoggedOn && !fetched && RecompSteam_AppID()) {
            fetched = YES;
            FetchDLC();
        }
    });
}

EXPORT int SteamAPI_ISteamApps_GetDLCCount(void *self) { (void)self; return (int)DLCList().count; }

EXPORT bool SteamAPI_ISteamApps_BGetDLCDataByIndex(void *self, int index, uint32_t *app, bool *available, char *name,
                                                    int size)
{
    (void)self;
    NSArray *list = DLCList();
    if (index < 0 || index >= (int)list.count) return false;
    NSDictionary *d = list[index];
    uint32_t a = [d[@"app"] unsignedIntValue];
    if (app) *app = a;
    if (available) *available = true;
    if (name && size > 0) snprintf(name, size, "%s", [d[@"name"] UTF8String] ?: "");
    return true;
}

// A DLC is "installed" when owned: a port carries everything the Mac game has.
EXPORT bool SteamAPI_ISteamApps_BIsDlcInstalled(void *self, uint32_t app) { (void)self; return RS_OwnsApp(app); }
