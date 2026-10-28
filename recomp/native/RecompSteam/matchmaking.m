// ISteamMatchmakingServers for the flat API: the internet server list from Steam's master
// server (GameServers.MasterServerQuery#1 over the session), and PingServer with a direct
// A2S_INFO query to the server's query port. ARC.
//
// Results reach the game through the responder object it passes (Steamworks.NET's
// ISteamMatchmakingServerListResponse / ISteamMatchmakingPingResponse: a C++-style object
// whose first word points to its vtable), called on the game's thread from a frame hook.
// Under IL2CPP, Steamworks.NET's own vtable of instance delegates cannot be marshalled; a
// port's profile ("responders", asmtool responders) swaps in static trampolines that find the
// instance by its address, so the same calls work there.
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <errno.h>
#include <os/lock.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#include "RecompSteamFlat.h"
#include "RecompSteamInternal.h"

#define RLOG(...) RecompSteam_Log(__VA_ARGS__)
#define EXPORT __attribute__((used, visibility("default")))

#pragma pack(push, 4)
typedef struct { uint16_t connectionPort, queryPort; uint32_t ip; } servernetadr_t;
typedef struct {
    servernetadr_t netadr;
    int32_t ping;
    bool hadSuccessfulResponse, doNotRefresh;
    char gameDir[32], map[32], gameDescription[64];
    uint32_t appID;
    int32_t players, maxPlayers, botPlayers;
    bool password, secure;
    uint32_t timeLastPlayed;
    int32_t serverVersion;
    char serverName[64], gameTags[128];
    uint64_t steamID;
} gameserveritem_t;  // 372 bytes, as Steamworks.NET marshals it
typedef struct { char key[256], value[256]; } MatchMakingKeyValuePair_t;
#pragma pack(pop)
_Static_assert(sizeof(gameserveritem_t) == 372, "gameserveritem_t");

enum { kServerResponded = 0, kServerFailedToRespond = 1, kNoServersListedOnMasterServer = 2 };
enum { kMaxServers = 5000, kDeliverPerFrame = 250 };

// The responders' vtables, in the SDK's order.
typedef void (*ListServerFn)(void *self, void *request, int server);
typedef void (*ListDoneFn)(void *self, void *request, int response);
typedef void (*PingRespondedFn)(void *self, gameserveritem_t *server);
typedef void (*PingFailedFn)(void *self);
static void *VFunc(void *object, int index) { return object ? (*(void ***)object)[index] : NULL; }

@interface RSServerList : NSObject {
@public
    void *response;
    NSData *servers;      // gameserveritem_t[], once Steam answered
    int delivered;
    bool refreshing, done, released;
}
@end
@implementation RSServerList
@end

@interface RSPing : NSObject {
@public
    void *response;
    int query;
    gameserveritem_t item;
    bool finished, ok, cancelled;
}
@end
@implementation RSPing
@end

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSNumber *, RSServerList *> *gLists;
static NSMutableArray<RSPing *> *gPings;
static uintptr_t gNextList;
static int gNextPing;

static void Copy(char *dest, size_t size, const char *src)
{
    if (src) strlcpy(dest, src, size); else dest[0] = 0;
}

// --- the master server list -----------------------------------------------------------------------

// A string field of a server, or of default_server_data, directly or by index in server_strings.
static void ServerString(const rs_pb_field *server, const rs_pb_field *defaults, NSArray<NSData *> *strings,
                         uint32_t field, uint32_t indexField, char *out, size_t size)
{
    const rs_pb_field *sources[2] = {server, defaults};
    for (int s = 0; s < 2; s++) {
        if (!sources[s]) continue;
        rs_pb_field f;
        if (rs_pb_get(sources[s]->data, sources[s]->length, field, &f) && f.wire == RS_PB_BYTES) {
            size_t n = MIN(f.length, size - 1);
            memcpy(out, f.data, n);
            out[n] = 0;
            return;
        }
        if (rs_pb_get(sources[s]->data, sources[s]->length, indexField, &f) && f.varint < strings.count) {
            NSData *d = strings[f.varint];
            size_t n = MIN(d.length, size - 1);
            memcpy(out, d.bytes, n);
            out[n] = 0;
            return;
        }
    }
    out[0] = 0;
}

static uint64_t ServerVarint(const rs_pb_field *server, const rs_pb_field *defaults, uint32_t field)
{
    rs_pb_field f;
    if (rs_pb_get(server->data, server->length, field, &f)) return f.varint;
    if (defaults && rs_pb_get(defaults->data, defaults->length, field, &f)) return f.varint;
    return 0;
}

// CMsgGMSClientServerQueryResponse -> gameserveritem_t[]
static NSData *ParseServers(const uint8_t *body, size_t length, uint32_t app)
{
    NSMutableArray<NSData *> *strings = [NSMutableArray array];
    rs_pb_field defaults = {0};
    bool haveDefaults = rs_pb_get(body, length, 3, &defaults);
    rs_pb_reader r = rs_pb_read(body, length);
    rs_pb_field f;
    while (rs_pb_next(&r, &f))
        if (f.number == 4) [strings addObject:[NSData dataWithBytes:f.data length:f.length]];
    NSMutableData *out = [NSMutableData data];
    r = rs_pb_read(body, length);
    while (rs_pb_next(&r, &f)) {
        if (f.number != 1) continue;
        const rs_pb_field *d = haveDefaults ? &defaults : NULL;
        gameserveritem_t item = {0};
        rs_pb_field ip;
        if (rs_pb_get(f.data, f.length, 4, &ip) && ip.wire == RS_PB_BYTES)
            item.netadr.ip = (uint32_t)rs_pb_get_varint(ip.data, ip.length, 1, 0);  // CMsgIPAddress.v4
        if (!item.netadr.ip) item.netadr.ip = (uint32_t)ServerVarint(&f, d, 1);
        if (!item.netadr.ip) continue;  // IPv6 only: the SDK's list has no room for it
        item.netadr.queryPort = (uint16_t)ServerVarint(&f, d, 2);
        item.netadr.connectionPort = (uint16_t)ServerVarint(&f, d, 9);
        item.steamID = ServerVarint(&f, d, 6);
        item.players = (int32_t)ServerVarint(&f, d, 8);
        item.maxPlayers = (int32_t)ServerVarint(&f, d, 13);
        item.botPlayers = (int32_t)ServerVarint(&f, d, 14);
        item.appID = (uint32_t)ServerVarint(&f, d, 12) ?: app;
        uint32_t flags = (uint32_t)ServerVarint(&f, d, 11);
        item.password = flags & 1;
        item.secure = flags & 2;
        item.ping = (int32_t)ServerVarint(&f, d, 36);
        item.hadSuccessfulResponse = true;
        ServerString(&f, d, strings, 16, 17, item.gameDir, sizeof item.gameDir);
        ServerString(&f, d, strings, 18, 19, item.map, sizeof item.map);
        ServerString(&f, d, strings, 20, 21, item.serverName, sizeof item.serverName);
        ServerString(&f, d, strings, 22, 23, item.gameDescription, sizeof item.gameDescription);
        ServerString(&f, d, strings, 26, 27, item.gameTags, sizeof item.gameTags);
        char version[32];
        ServerString(&f, d, strings, 24, 25, version, sizeof version);
        item.serverVersion = atoi(version);
        [out appendBytes:&item length:sizeof item];
    }
    return out;
}

// Runs on the game's thread: hands finished lists to their responders, a few hundred servers a frame.
static void DeliverLists(void)
{
    NSMutableArray<NSArray *> *work = [NSMutableArray array];
    os_unfair_lock_lock(&gLock);
    [gLists enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, RSServerList *list, BOOL *stop) {
        if (list->servers && !list->done && !list->released) [work addObject:@[key, list]];
    }];
    os_unfair_lock_unlock(&gLock);
    for (NSArray *pair in work) {
        void *request = (void *)(uintptr_t)[pair[0] unsignedLongValue];
        RSServerList *list = pair[1];
        int count = (int)(list->servers.length / sizeof(gameserveritem_t));
        ListServerFn responded = VFunc(list->response, 0);
        int end = MIN(count, list->delivered + kDeliverPerFrame);
        for (int i = list->delivered; i < end && responded; i++) responded(list->response, request, i);
        list->delivered = end;
        if (end < count && responded) continue;
        list->done = true;
        list->refreshing = false;
        RLOG("matchmaking: list %lu: %d servers handed to the game%s", (unsigned long)(uintptr_t)request, count,
             responded ? "" : " (no responder)");
        ListDoneFn complete = VFunc(list->response, 2);
        if (complete) complete(list->response, request, count ? kServerResponded : kNoServersListedOnMasterServer);
    }
}

static void DeliverPings(void);

static void Frame(void)
{
    DeliverLists();
    DeliverPings();
}

static void StartFrames(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLists = [NSMutableDictionary dictionary];
        gPings = [NSMutableArray array];
        RS_AddFrameHook(Frame);
    });
}

EXPORT void *SteamAPI_ISteamMatchmakingServers_RequestInternetServerList(void *self, uint32_t app, MatchMakingKeyValuePair_t **filters, uint32_t count, void *response)
{
    (void)self;
    StartFrames();
    NSMutableString *filter = [NSMutableString stringWithFormat:@"\\appid\\%u", app];
    for (uint32_t i = 0; filters && i < count; i++)
        if (filters[i] && filters[i]->key[0]) [filter appendFormat:@"\\%s\\%s", filters[i]->key, filters[i]->value];
    RSServerList *list = [RSServerList new];
    list->response = response;
    list->refreshing = true;
    os_unfair_lock_lock(&gLock);
    uintptr_t handle = ++gNextList;
    gLists[@(handle)] = list;
    os_unfair_lock_unlock(&gLock);
    RLOG("matchmaking: list %lu: asking the master server for %s%s", (unsigned long)handle, filter.UTF8String,
         response ? "" : " (no responder)");

    rs_pb_writer query = {0}, w = {0};
    rs_pb_varint(&query, 1, app);
    rs_pb_string(&query, 4, filter.UTF8String);
    rs_pb_varint(&query, 5, kMaxServers);
    rs_pb_varint(&w, 1, app);
    rs_pb_message(&w, 2, &query);
    RecompSteam_Call("GameServers.MasterServerQuery#1", w.data, w.length, 30, ^(const RecompSteamMessage *reply) {
        rs_pb_field resp;
        NSData *servers = [NSData data];
        if (reply->eresult == RecompSteamResultOK && rs_pb_get(reply->body, reply->length, 1, &resp))
            servers = ParseServers(resp.data, resp.length, app);
        RLOG("matchmaking: list %lu: %lu servers (EResult %d)", (unsigned long)handle,
             (unsigned long)(servers.length / sizeof(gameserveritem_t)), reply->eresult);
        os_unfair_lock_lock(&gLock);
        list->servers = servers;
        os_unfair_lock_unlock(&gLock);
    });
    rs_pb_free(&query);
    rs_pb_free(&w);
    return (void *)handle;
}

static RSServerList *List(void *request)
{
    os_unfair_lock_lock(&gLock);
    RSServerList *list = gLists[@((uintptr_t)request)];
    os_unfair_lock_unlock(&gLock);
    return list;
}

EXPORT gameserveritem_t *SteamAPI_ISteamMatchmakingServers_GetServerDetails(void *self, void *request, int server)
{
    (void)self;
    RSServerList *list = List(request);
    int count = list ? (int)(list->servers.length / sizeof(gameserveritem_t)) : 0;
    if (server < 0 || server >= count) return NULL;
    return (gameserveritem_t *)list->servers.bytes + server;
}

EXPORT int SteamAPI_ISteamMatchmakingServers_GetServerCount(void *self, void *request)
{
    (void)self;
    RSServerList *list = List(request);
    return list ? (int)(list->servers.length / sizeof(gameserveritem_t)) : 0;
}

EXPORT bool SteamAPI_ISteamMatchmakingServers_IsRefreshing(void *self, void *request)
{
    (void)self;
    RSServerList *list = List(request);
    return list && list->refreshing;
}

EXPORT void SteamAPI_ISteamMatchmakingServers_CancelQuery(void *self, void *request)
{
    (void)self;
    RSServerList *list = List(request);
    if (list) list->refreshing = false;
}

EXPORT void SteamAPI_ISteamMatchmakingServers_ReleaseRequest(void *self, void *request)
{
    (void)self;
    os_unfair_lock_lock(&gLock);
    RSServerList *list = gLists[@((uintptr_t)request)];
    if (list) list->released = true;
    [gLists removeObjectForKey:@((uintptr_t)request)];
    os_unfair_lock_unlock(&gLock);
}

// --- PingServer: A2S_INFO -----------------------------------------------------------------------

static const uint8_t *ReadString(const uint8_t *p, const uint8_t *end, char *out, size_t size)
{
    const uint8_t *z = p ? memchr(p, 0, (size_t)(end - p)) : NULL;
    if (!z) return NULL;
    Copy(out, size, (const char *)p);
    return z + 1;
}

// Parses an A2S_INFO reply ('I') into item; false when malformed.
static bool ParseInfo(const uint8_t *p, size_t length, gameserveritem_t *item)
{
    const uint8_t *end = p + length;
    if (length < 6 || p[4] != 'I') return false;
    p += 6;  // header, 'I', protocol
    char game[64];
    p = ReadString(p, end, item->serverName, sizeof item->serverName);
    p = ReadString(p, end, item->map, sizeof item->map);
    p = ReadString(p, end, item->gameDir, sizeof item->gameDir);
    p = ReadString(p, end, game, sizeof game);
    if (!p || end - p < 9) return false;
    Copy(item->gameDescription, sizeof item->gameDescription, game);
    item->players = p[2];
    item->maxPlayers = p[3];
    item->botPlayers = p[4];
    item->password = p[7];
    item->secure = p[8];
    p += 9;
    char version[32];
    p = ReadString(p, end, version, sizeof version);
    if (!p) return false;
    item->serverVersion = atoi(version);
    if (p < end) {
        uint8_t edf = *p++;
        if ((edf & 0x80) && end - p >= 2) { item->netadr.connectionPort = (uint16_t)(p[0] | p[1] << 8); p += 2; }
        if ((edf & 0x10) && end - p >= 8) { memcpy(&item->steamID, p, 8); p += 8; }
        if ((edf & 0x40) && end - p >= 2) { p += 2; p = ReadString(p, end, version, sizeof version); }
        if ((edf & 0x20) && p) p = ReadString(p, end, item->gameTags, sizeof item->gameTags);
        if ((edf & 0x01) && p && end - p >= 8) { uint64_t gameid; memcpy(&gameid, p, 8); item->appID = (uint32_t)(gameid & 0xffffff); }
    }
    return true;
}

static void Query(RSPing *ping)
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) { ping->finished = true; return; }
    struct timeval timeout = {.tv_sec = 2};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    struct sockaddr_in to = {.sin_len = sizeof to, .sin_family = AF_INET,
                             .sin_port = htons(ping->item.netadr.queryPort), .sin_addr.s_addr = htonl(ping->item.netadr.ip)};
    uint8_t request[29 + 4] = "\xff\xff\xff\xffTSource Engine Query";
    size_t requestLength = 25;
    uint8_t reply[1400];
    ssize_t n = -1;
    struct timeval start, stop;
    gettimeofday(&start, NULL);
    for (int attempt = 0; attempt < 3; attempt++) {
        sendto(fd, request, requestLength, 0, (struct sockaddr *)&to, sizeof to);
        n = recv(fd, reply, sizeof reply, 0);
        if (n >= 9 && reply[4] == 'A') {  // a challenge: ask again with it
            memcpy(request + 25, reply + 5, 4);
            requestLength = 29;
            continue;
        }
        if (n > 0) break;
    }
    int error = n < 0 ? errno : 0;
    gettimeofday(&stop, NULL);
    close(fd);
    gameserveritem_t item = ping->item;
    bool ok = n > 0 && ParseInfo(reply, (size_t)n, &item);
    if (ok) {
        item.ping = (int32_t)((stop.tv_sec - start.tv_sec) * 1000 + (stop.tv_usec - start.tv_usec) / 1000);
        item.hadSuccessfulResponse = true;
        if (!item.netadr.connectionPort) item.netadr.connectionPort = ping->item.netadr.connectionPort;
        RLOG("matchmaking: ping %d: \"%s\", %d/%d players, version %d, game port %u, %d ms", ping->query,
             item.serverName, item.players, item.maxPlayers, item.serverVersion, item.netadr.connectionPort, item.ping);
    } else if (n > 0) {
        RLOG("matchmaking: ping %d: unreadable answer ('%c', %zd bytes)", ping->query, n > 4 ? reply[4] : '?', n);
    } else {
        RLOG("matchmaking: ping %d: no answer (%s)", ping->query, strerror(error));
    }
    os_unfair_lock_lock(&gLock);
    ping->item = item;
    ping->ok = ok;
    ping->finished = true;
    os_unfair_lock_unlock(&gLock);
}

static void DeliverPings(void)
{
    NSMutableArray<RSPing *> *done = [NSMutableArray array];
    os_unfair_lock_lock(&gLock);
    for (RSPing *ping in gPings) if (ping->finished) [done addObject:ping];
    [gPings removeObjectsInArray:done];
    os_unfair_lock_unlock(&gLock);
    for (RSPing *ping in done) {
        if (ping->cancelled) continue;
        if (ping->ok) {
            PingRespondedFn fn = VFunc(ping->response, 0);
            if (fn) fn(ping->response, &ping->item);
        } else {
            PingFailedFn fn = VFunc(ping->response, 1);
            if (fn) fn(ping->response);
        }
    }
}

EXPORT int SteamAPI_ISteamMatchmakingServers_PingServer(void *self, uint32_t ip, uint16_t port, void *response)
{
    (void)self;
    StartFrames();
    RSPing *ping = [RSPing new];
    ping->response = response;
    ping->item.netadr.ip = ip;
    ping->item.netadr.queryPort = port;
    ping->item.netadr.connectionPort = port ? port - 1 : 0;  // the usual layout; A2S's EDF says for sure
    os_unfair_lock_lock(&gLock);
    ping->query = ++gNextPing;
    [gPings addObject:ping];
    os_unfair_lock_unlock(&gLock);
    RLOG("matchmaking: ping %d: A2S_INFO to %u.%u.%u.%u:%u%s", ping->query, ip >> 24, ip >> 16 & 255, ip >> 8 & 255,
         ip & 255, port, response ? "" : " (no responder)");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ Query(ping); });
    return ping->query;
}

EXPORT void SteamAPI_ISteamMatchmakingServers_CancelServerQuery(void *self, int query)
{
    (void)self;
    os_unfair_lock_lock(&gLock);
    for (RSPing *ping in gPings) if (ping->query == query) ping->cancelled = true;
    os_unfair_lock_unlock(&gLock);
}
