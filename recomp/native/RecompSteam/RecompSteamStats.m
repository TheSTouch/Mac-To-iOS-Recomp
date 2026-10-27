// ISteamUserStats over the session: the player's stats and achievements for the game,
// with the game's schema (stat ids, achievement bits and names), from
// ClientGetUserStats; changes go back with ClientStoreUserStats2 when the game calls
// StoreStats. ARC.
//
// The schema is binary KeyValues: {"<app>": {"stats": {"<id>": {"type", "name",
// "bits": {"<bit>": {"name", "display": {"name": {...}, "desc": {...}, "hidden"}}}}}}}.
// Types come named or numbered: INT (1), FLOAT (2), AVGRATE (3), ACHIEVEMENTS (4) and
// GROUPACHIEVEMENTS (5); achievement stats hold one bit each, unlock times in achievement_blocks.
#import <Foundation/Foundation.h>
#include "RecompSteamFlat.h"
#include "RecompSteamInternal.h"

#define RLOG(...) RecompSteam_Log(__VA_ARGS__)
#define EXPORT __attribute__((used, visibility("default")))

#pragma pack(push, 4)
typedef struct { uint64_t m_nGameID; int32_t m_eResult; uint64_t m_steamIDUser; } UserStatsReceived_t;   // 1101
typedef struct { uint64_t m_nGameID; int32_t m_eResult; } UserStatsStored_t;                            // 1102
typedef struct {
    uint64_t m_nGameID;
    bool m_bGroupAchievement;
    char m_rgchAchievementName[128];
    uint32_t m_nCurProgress, m_nMaxProgress;
} UserAchievementStored_t;                                                                             // 1103
#pragma pack(pop)
enum { k_iUserStatsReceived = 1101, k_iUserStatsStored = 1102, k_iUserAchievementStored = 1103 };

// --- binary KeyValues -------------------------------------------------------------------------

static NSDictionary *ReadKV(const uint8_t **p, const uint8_t *end)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    while (*p < end) {
        uint8_t type = *(*p)++;
        if (type == 8 || type == 11) break;
        const uint8_t *k = *p;
        while (*p < end && **p) (*p)++;
        if (*p >= end) break;
        NSString *key = [[NSString alloc] initWithBytes:k length:*p - k encoding:NSUTF8StringEncoding] ?: @"";
        (*p)++;
        id value = nil;
        switch (type) {
        case 0: value = ReadKV(p, end); break;
        case 1: {
            const uint8_t *v = *p;
            while (*p < end && **p) (*p)++;
            value = [[NSString alloc] initWithBytes:v length:*p - v encoding:NSUTF8StringEncoding] ?: @"";
            if (*p < end) (*p)++;
            break;
        }
        case 2: case 4: case 6:
            if (end - *p < 4) return d;
            value = @((int32_t)((*p)[0] | (*p)[1] << 8 | (*p)[2] << 16 | (uint32_t)(*p)[3] << 24));
            *p += 4;
            break;
        case 3: {
            if (end - *p < 4) return d;
            float f;
            memcpy(&f, *p, 4);
            value = @(f);
            *p += 4;
            break;
        }
        case 7: case 10: {
            if (end - *p < 8) return d;
            uint64_t v = 0;
            for (int i = 0; i < 8; i++) v |= (uint64_t)(*p)[i] << (8 * i);
            value = @(v);
            *p += 8;
            break;
        }
        default:
            return d;   // unknown type: stop rather than misread
        }
        if (value) d[key] = value;
    }
    return d;
}

// --- the game's stats --------------------------------------------------------------------------

@interface RSStat : NSObject
@property (nonatomic) uint32_t ident;
@property (nonatomic) int type;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint32_t value;      // as stored (floats as their bits)
@property (nonatomic) BOOL dirty;
@end
@implementation RSStat
@end

@interface RSAchievement : NSObject
@property (nonatomic, copy) NSString *name, *displayName, *desc;
@property (nonatomic) BOOL hidden, newlyUnlocked;
@property (nonatomic) uint32_t stat, bit, unlockTime;
@end
@implementation RSAchievement
@end

static NSLock *gLock;
static NSMutableDictionary<NSString *, RSStat *> *gStats;              // by name
static NSMutableDictionary<NSNumber *, RSStat *> *gStatsById;
static NSMutableArray<RSAchievement *> *gAchievements;                 // in schema order
static NSMutableDictionary<NSString *, RSAchievement *> *gAchByName;
static uint32_t gCRC;
static BOOL gLoaded, gLoading;

static NSString *English(id v)
{
    if ([v isKindOfClass:NSString.class]) return v;
    if ([v isKindOfClass:NSDictionary.class]) return v[@"english"] ?: [v allValues].firstObject;
    return @"";
}

// "INT", "FLOAT", "AVGRATE", "ACHIEVEMENTS", "GROUPACHIEVEMENTS", or their numbers.
static int StatType(id t)
{
    if ([t isKindOfClass:NSNumber.class]) return [t intValue];
    NSString *s = [[t description] uppercaseString];
    if (s.intValue) return s.intValue;
    NSDictionary *names = @{@"INT": @1, @"FLOAT": @2, @"AVGRATE": @3, @"ACHIEVEMENTS": @4, @"GROUPACHIEVEMENTS": @5};
    return [names[s] intValue];
}

static void Load(NSData *body)
{
    rs_pb_field schema;
    NSDictionary *root = nil;
    if (rs_pb_get(body.bytes, body.length, 4, &schema)) {
        const uint8_t *p = schema.data;
        root = ReadKV(&p, schema.data + schema.length);
    }
    NSDictionary *game = root.allValues.firstObject;
    NSDictionary *stats = [game isKindOfClass:NSDictionary.class] ? game[@"stats"] : nil;
    NSMutableDictionary *byName = [NSMutableDictionary dictionary], *byId = [NSMutableDictionary dictionary];
    NSMutableArray *achs = [NSMutableArray array];
    NSMutableDictionary *achByName = [NSMutableDictionary dictionary];
    NSArray *keys = [stats.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [@(a.intValue) compare:@(b.intValue)];
    }];
    for (NSString *k in keys) {
        NSDictionary *s = stats[k];
        if (![s isKindOfClass:NSDictionary.class]) continue;
        RSStat *st = [[RSStat alloc] init];
        st.ident = (uint32_t)k.intValue;
        st.type = StatType(s[@"type"] ?: s[@"type_int"]);
        st.name = [s[@"name"] description] ?: k;
        byName[st.name] = st;
        byId[@(st.ident)] = st;
        NSDictionary *bits = s[@"bits"];
        if ((st.type == 4 || st.type == 5) && [bits isKindOfClass:NSDictionary.class]) {
            NSArray *bitKeys = [bits.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                return [@(a.intValue) compare:@(b.intValue)];
            }];
            for (NSString *bk in bitKeys) {
                NSDictionary *b = bits[bk];
                if (![b isKindOfClass:NSDictionary.class]) continue;
                RSAchievement *a = [[RSAchievement alloc] init];
                a.name = [b[@"name"] description] ?: @"";
                a.stat = st.ident;
                a.bit = (uint32_t)[b[@"bit"] ?: bk intValue];
                NSDictionary *disp = b[@"display"];
                a.displayName = English(disp[@"name"]);
                a.desc = English(disp[@"desc"]);
                a.hidden = [disp[@"hidden"] intValue] != 0;
                [achs addObject:a];
                achByName[a.name] = a;
            }
        }
    }
    rs_pb_reader r = rs_pb_read(body.bytes, body.length);
    rs_pb_field f;
    while (rs_pb_next(&r, &f)) {
        if (f.number == 5 && f.wire == RS_PB_BYTES) {
            uint32_t ident = (uint32_t)rs_pb_get_varint(f.data, f.length, 1, 0);
            ((RSStat *)byId[@(ident)]).value = (uint32_t)rs_pb_get_varint(f.data, f.length, 2, 0);
        } else if (f.number == 6 && f.wire == RS_PB_BYTES) {
            uint32_t stat = (uint32_t)rs_pb_get_varint(f.data, f.length, 1, 0);
            // unlock_time: one fixed32 per bit, repeated (packed or not).
            rs_pb_reader br = rs_pb_read(f.data, f.length);
            rs_pb_field bf;
            uint32_t bit = 0;
            while (rs_pb_next(&br, &bf)) {
                if (bf.number != 2) continue;
                if (bf.wire == RS_PB_BYTES) {
                    for (size_t i = 0; i + 4 <= bf.length; i += 4, bit++) {
                        uint32_t t = bf.data[i] | bf.data[i + 1] << 8 | bf.data[i + 2] << 16 | (uint32_t)bf.data[i + 3] << 24;
                        for (RSAchievement *a in achs) if (a.stat == stat && a.bit == bit) a.unlockTime = t;
                    }
                } else {
                    for (RSAchievement *a in achs) if (a.stat == stat && a.bit == bit) a.unlockTime = (uint32_t)bf.varint;
                    bit++;
                }
            }
        }
    }
    [gLock lock];
    gStats = byName;
    gStatsById = byId;
    gAchievements = achs;
    gAchByName = achByName;
    gCRC = (uint32_t)rs_pb_get_varint(body.bytes, body.length, 3, 0);
    gLoaded = YES;
    [gLock unlock];
    int unlocked = 0;
    for (RSAchievement *a in achs) unlocked += (((RSStat *)gStatsById[@(a.stat)]).value >> a.bit) & 1;
    RLOG("stats: %lu stats, %lu achievements (%d unlocked)", (unsigned long)byName.count, (unsigned long)achs.count, unlocked);
}

// Fetches the player's stats; posts UserStatsReceived_t (as a callback, and under call when non-zero).
static void Fetch(uint64_t call)
{
    uint32_t app = RecompSteam_AppID();
    rs_pb_writer w = {0};
    rs_pb_fixed64(&w, 1, app);
    rs_pb_varint(&w, 3, (uint64_t)(int64_t)-1);   // no schema cached: send it
    rs_pb_fixed64(&w, 4, RS_SteamID());
    RecompSteam_SendJob(RS_ClientGetUserStats, w.data, w.length, 0, 20, ^(const RecompSteamMessage *m) {
        int32_t er = m->length ? (int32_t)rs_pb_get_varint(m->body, m->length, 2, 2) : RecompSteamResultTimeout;
        if (er == RecompSteamResultOK) Load([NSData dataWithBytes:m->body length:m->length]);
        else RLOG("stats: not received (EResult %d)", er);
        [gLock lock];
        gLoading = NO;
        [gLock unlock];
        UserStatsReceived_t r = {app, er, RS_SteamID()};
        if (call) RS_PostCallResult(call, k_iUserStatsReceived, &r, sizeof r);
        else RS_PostCallback(k_iUserStatsReceived, &r, sizeof r);
    });
    rs_pb_free(&w);
}

static bool Request(uint64_t call)
{
    [gLock lock];
    BOOL busy = gLoading;
    gLoading = YES;
    [gLock unlock];
    if (busy && !call) return true;
    RecompSteam_WhenLoggedOn(20, ^(bool ok) {
        if (ok) {
            Fetch(call);
            return;
        }
        [gLock lock];
        gLoading = NO;
        [gLock unlock];
        UserStatsReceived_t r = {RecompSteam_AppID(), RecompSteamResultNoConnection, RS_SteamID()};
        if (call) RS_PostCallResult(call, k_iUserStatsReceived, &r, sizeof r);
        else RS_PostCallback(k_iUserStatsReceived, &r, sizeof r);
    });
    return true;
}

__attribute__((constructor)) static void Init(void)
{
    gLock = [[NSLock alloc] init];
}

// --- ISteamUserStats ------------------------------------------------------------------------------

EXPORT bool SteamAPI_ISteamUserStats_RequestCurrentStats(void *self) { (void)self; return Request(0); }

EXPORT uint64_t SteamAPI_ISteamUserStats_RequestUserStats(void *self, uint64_t steamid)
{
    (void)self;
    if (steamid != RS_SteamID()) return 0;   // other players' stats: not offered
    uint64_t call = RS_NewCall();
    Request(call);
    return call;
}

static RSStat *Stat(const char *name)
{
    if (!name) return nil;
    [gLock lock];
    RSStat *s = gStats[@(name)];
    [gLock unlock];
    return s;
}

EXPORT bool SteamAPI_ISteamUserStats_GetStatInt32(void *self, const char *name, int32_t *out)
{
    (void)self;
    RSStat *s = Stat(name);
    if (!s || s.type != 1) return false;
    if (out) *out = (int32_t)s.value;
    return true;
}

EXPORT bool SteamAPI_ISteamUserStats_GetStatFloat(void *self, const char *name, float *out)
{
    (void)self;
    RSStat *s = Stat(name);
    if (!s || (s.type != 2 && s.type != 3)) return false;
    uint32_t bits = s.value;
    if (out) memcpy(out, &bits, 4);
    return true;
}

EXPORT bool SteamAPI_ISteamUserStats_SetStatInt32(void *self, const char *name, int32_t value)
{
    (void)self;
    RSStat *s = Stat(name);
    if (!s || s.type != 1) return false;
    [gLock lock];
    if (s.value != (uint32_t)value) s.dirty = YES;
    s.value = (uint32_t)value;
    [gLock unlock];
    return true;
}

EXPORT bool SteamAPI_ISteamUserStats_SetStatFloat(void *self, const char *name, float value)
{
    (void)self;
    RSStat *s = Stat(name);
    if (!s || s.type != 2) return false;
    uint32_t bits;
    memcpy(&bits, &value, 4);
    [gLock lock];
    if (s.value != bits) s.dirty = YES;
    s.value = bits;
    [gLock unlock];
    return true;
}

static RSAchievement *Achievement(const char *name)
{
    if (!name) return nil;
    [gLock lock];
    RSAchievement *a = gAchByName[@(name)];
    [gLock unlock];
    return a;
}

static bool Unlocked(RSAchievement *a)
{
    [gLock lock];
    bool on = (gStatsById[@(a.stat)].value >> a.bit) & 1;
    [gLock unlock];
    return on;
}

EXPORT bool SteamAPI_ISteamUserStats_GetAchievement(void *self, const char *name, bool *achieved)
{
    (void)self;
    RSAchievement *a = Achievement(name);
    if (!a) return false;
    if (achieved) *achieved = Unlocked(a);
    return true;
}

EXPORT bool SteamAPI_ISteamUserStats_GetAchievementAndUnlockTime(void *self, const char *name, bool *achieved,
                                                                 uint32_t *time)
{
    (void)self;
    RSAchievement *a = Achievement(name);
    if (!a) return false;
    bool on = Unlocked(a);
    if (achieved) *achieved = on;
    if (time) *time = on ? a.unlockTime : 0;
    return true;
}

EXPORT bool SteamAPI_ISteamUserStats_GetUserAchievement(void *self, uint64_t steamid, const char *name, bool *achieved)
{
    return steamid == RS_SteamID() && SteamAPI_ISteamUserStats_GetAchievement(self, name, achieved);
}

static bool SetBit(const char *name, bool on)
{
    RSAchievement *a = Achievement(name);
    if (!a) return false;
    [gLock lock];
    RSStat *s = gStatsById[@(a.stat)];
    uint32_t v = on ? s.value | (1u << a.bit) : s.value & ~(1u << a.bit);
    if (v != s.value) {
        s.value = v;
        s.dirty = YES;
        a.newlyUnlocked = on;
        if (on) a.unlockTime = RecompSteam_ServerTime();
    }
    [gLock unlock];
    if (on) RLOG("achievement %s set (stored at the next StoreStats)", name);
    return true;
}

EXPORT bool SteamAPI_ISteamUserStats_SetAchievement(void *self, const char *name) { (void)self; return SetBit(name, true); }
EXPORT bool SteamAPI_ISteamUserStats_ClearAchievement(void *self, const char *name) { (void)self; return SetBit(name, false); }
EXPORT bool SteamAPI_ISteamUserStats_IndicateAchievementProgress(void *self, const char *name, uint32_t cur, uint32_t max)
{
    (void)self; (void)cur; (void)max;
    return Achievement(name) != nil;
}

EXPORT bool SteamAPI_ISteamUserStats_StoreStats(void *self)
{
    (void)self;
    uint32_t app = RecompSteam_AppID();
    NSMutableArray<RSStat *> *changed = [NSMutableArray array];
    NSMutableArray<NSString *> *unlocked = [NSMutableArray array];
    [gLock lock];
    BOOL loaded = gLoaded;
    for (RSStat *s in gStats.allValues)
        if (s.dirty) [changed addObject:s];
    for (RSAchievement *a in gAchievements)
        if (a.newlyUnlocked) {
            [unlocked addObject:a.name];
            a.newlyUnlocked = NO;
        }
    uint32_t crc = gCRC;
    [gLock unlock];
    if (!loaded) return false;
    if (!changed.count) {
        UserStatsStored_t r = {app, RecompSteamResultOK};
        RS_PostCallback(k_iUserStatsStored, &r, sizeof r);
        return true;
    }
    rs_pb_writer w = {0};
    rs_pb_fixed64(&w, 1, app);
    rs_pb_fixed64(&w, 2, RS_SteamID());
    rs_pb_fixed64(&w, 3, RS_SteamID());
    rs_pb_varint(&w, 4, crc);
    rs_pb_bool(&w, 5, false);
    for (RSStat *s in changed) {
        rs_pb_writer e = {0};
        rs_pb_varint(&e, 1, s.ident);
        rs_pb_varint(&e, 2, s.value);
        rs_pb_message(&w, 6, &e);
        rs_pb_free(&e);
    }
    RecompSteam_SendJob(RS_ClientStoreUserStats2, w.data, w.length, 0, 20, ^(const RecompSteamMessage *m) {
        int32_t er = m->length ? (int32_t)rs_pb_get_varint(m->body, m->length, 2, 2) : RecompSteamResultTimeout;
        RLOG("stats stored: EResult %d (%lu changed)", er, (unsigned long)changed.count);
        [gLock lock];
        if (er == RecompSteamResultOK) {
            for (RSStat *s in changed) s.dirty = NO;
            gCRC = (uint32_t)rs_pb_get_varint(m->body, m->length, 3, gCRC);
        }
        [gLock unlock];
        UserStatsStored_t r = {app, er};
        RS_PostCallback(k_iUserStatsStored, &r, sizeof r);
        if (er == RecompSteamResultOK)
            for (NSString *name in unlocked) {
                UserAchievementStored_t a = {app, false, "", 0, 0};
                snprintf(a.m_rgchAchievementName, sizeof a.m_rgchAchievementName, "%s", name.UTF8String);
                RS_PostCallback(k_iUserAchievementStored, &a, sizeof a);
            }
    });
    rs_pb_free(&w);
    return true;
}

EXPORT uint32_t SteamAPI_ISteamUserStats_GetNumAchievements(void *self)
{
    (void)self;
    [gLock lock];
    uint32_t n = (uint32_t)gAchievements.count;
    [gLock unlock];
    return n;
}

EXPORT const char *SteamAPI_ISteamUserStats_GetAchievementName(void *self, uint32_t index)
{
    (void)self;
    [gLock lock];
    RSAchievement *a = index < gAchievements.count ? gAchievements[index] : nil;
    [gLock unlock];
    return a ? a.name.UTF8String : "";
}

EXPORT const char *SteamAPI_ISteamUserStats_GetAchievementDisplayAttribute(void *self, const char *name, const char *key)
{
    (void)self;
    RSAchievement *a = Achievement(name);
    if (!a || !key) return "";
    if (!strcmp(key, "name")) return a.displayName.UTF8String ?: "";
    if (!strcmp(key, "desc")) return a.desc.UTF8String ?: "";
    if (!strcmp(key, "hidden")) return a.hidden ? "1" : "0";
    return "";
}

// Resetting the player's stats on Steam is not something a port does.
EXPORT bool SteamAPI_ISteamUserStats_ResetAllStats(void *self, bool achievements)
{
    (void)self; (void)achievements;
    RLOG("ResetAllStats refused");
    return false;
}

// Stats come with the logon, as the Steam client gives them to a game it starts.
__attribute__((constructor)) static void FetchAtLogon(void)
{
    RecompSteam_AddStateObserver(^(RecompSteamState s) {
        static BOOL fetched;
        if (s == RecompSteamLoggedOn && !fetched && RecompSteam_AppID() && getenv("RECOMP_STEAM_CLI") == NULL) {
            fetched = YES;
            Request(0);
        }
    });
}
