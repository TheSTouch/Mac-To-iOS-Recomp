// The session behind RecompSteamSession.h: a WebSocket to one of Steam's connection
// managers, logged on with the player's refresh token as a Steam client would be
// (protocol as in SteamKit2 and node-steam-user, both of which this follows).
//
// A message on the wire: uint32 EMsg | 0x80000000, uint32 header length, a
// CMsgProtoBufHeader, then the body, all little-endian. Steam batches messages in
// Multi (1), gzipped when large. Jobs: a request carries jobid_source, the answer
// names it in jobid_target.
//
// ARC. Everything mutable is touched on gQueue only, except the few values the
// getters read, which sit behind gLock.
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <os/lock.h>
#include <os/log.h>
#include <stdarg.h>
#include <sys/sysctl.h>
#include "RecompSteamInternal.h"

void RecompSteam_Log(const char *format, ...)
{
    va_list ap;
    va_start(ap, format);
    NSString *s = [[NSString alloc] initWithFormat:@(format) arguments:ap];
    va_end(ap);
    // os_log, public: NSLog's arguments show as <private> in a device's log.
    os_log(OS_LOG_DEFAULT, "[recomp] steam: %{public}s", s.UTF8String);
#if TARGET_OS_IPHONE
    RecompLog_Line([@"[recomp] steam: " stringByAppendingString:s].UTF8String);   // the port's recomp.log
#else
    fprintf(stderr, "[recomp] steam: %s\n", s.UTF8String);   // the Mac clone's run.log, recomp-steam-cli
#endif
}
// RecompLog.m defines the real one in Unity ports; Unreal ports and the Mac tools have none.
__attribute__((weak)) void RecompLog_Line(const char *line) { (void)line; }
#define RLOG(...) RecompSteam_Log(__VA_ARGS__)

static dispatch_queue_t gQueue;
dispatch_queue_t RecompSteam_Queue(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gQueue = dispatch_queue_create("recomp.steam", DISPATCH_QUEUE_SERIAL); });
    return gQueue;
}
#define Q RecompSteam_Queue()

static const uint64_t kNoJob = ~0ull;

// --- values the getters read ------------------------------------------------------------

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static RecompSteamState gState;
static uint64_t gSteamID;
static uint32_t gAppID, gCellID, gPublicIP, gServerTime, gPlayingApp;
static bool gPlayingBlocked;
static double gServerTimeAt;  // CFAbsoluteTime when gServerTime was received
static char gPersona[128];

RecompSteamState RecompSteam_State(void) { os_unfair_lock_lock(&gLock); RecompSteamState s = gState; os_unfair_lock_unlock(&gLock); return s; }
uint64_t RecompSteam_SteamID(void) { os_unfair_lock_lock(&gLock); uint64_t v = gSteamID; os_unfair_lock_unlock(&gLock); return v; }
uint32_t RecompSteam_AppID(void) { os_unfair_lock_lock(&gLock); uint32_t v = gAppID; os_unfair_lock_unlock(&gLock); return v; }
uint32_t RecompSteam_CellID(void) { os_unfair_lock_lock(&gLock); uint32_t v = gCellID; os_unfair_lock_unlock(&gLock); return v; }
uint32_t RecompSteam_PublicIP(void) { os_unfair_lock_lock(&gLock); uint32_t v = gPublicIP; os_unfair_lock_unlock(&gLock); return v; }
uint32_t RecompSteam_ServerTime(void)
{
    os_unfair_lock_lock(&gLock);
    uint32_t t = gServerTime ? gServerTime + (uint32_t)(CFAbsoluteTimeGetCurrent() - gServerTimeAt) : 0;
    os_unfair_lock_unlock(&gLock);
    return t ? t : (uint32_t)time(NULL);
}
size_t RecompSteam_PersonaName(char *out, size_t size)
{
    if (!size) return 0;
    os_unfair_lock_lock(&gLock);
    size_t n = strlen(gPersona);
    if (n >= size) n = size - 1;
    memcpy(out, gPersona, n);
    out[n] = 0;
    os_unfair_lock_unlock(&gLock);
    return n;
}
bool RecompSteam_PlayingBlocked(uint32_t *app)
{
    os_unfair_lock_lock(&gLock);
    bool b = gPlayingBlocked;
    if (app) *app = gPlayingApp;
    os_unfair_lock_unlock(&gLock);
    return b;
}

// --- CM list ----------------------------------------------------------------------------------

static NSMutableArray<NSString *> *gCMs;      // websocket endpoints, best first
static NSMutableSet<NSString *> *gBadCMs;

static void FetchCMs(void (^done)(NSString *endpoint))
{
    if (gCMs.count) {
        NSMutableArray *good = [NSMutableArray array];
        for (NSString *e in gCMs) if (![gBadCMs containsObject:e]) [good addObject:e];
        if (!good.count) { [gBadCMs removeAllObjects]; good = [gCMs mutableCopy]; }
        NSUInteger pick = arc4random_uniform((uint32_t)MIN(good.count, 5));
        done(good[pick]);
        return;
    }
    NSString *url = [NSString stringWithFormat:@"https://api.steampowered.com/ISteamDirectory/GetCMListForConnect/v1/"
                     @"?cellid=%u&cmtype=websockets&realm=steamglobal", RecompSteam_CellID()];
    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:url]
                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *r, NSError *error) {
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSArray *list = [json isKindOfClass:NSDictionary.class] ? json[@"response"][@"serverlist"] : nil;
        dispatch_async(Q, ^{
            NSMutableArray *servers = [NSMutableArray array];
            if ([list isKindOfClass:NSArray.class])
                for (NSDictionary *s in list)
                    if ([s isKindOfClass:NSDictionary.class] && [s[@"type"] isEqual:@"websockets"] &&
                        [s[@"endpoint"] isKindOfClass:NSString.class])
                        [servers addObject:s];
            [servers sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [@([a[@"wtd_load"] doubleValue]) compare:@([b[@"wtd_load"] doubleValue])];
            }];
            if (!servers.count) {
                RLOG("no CM list (%s)", error ? error.localizedDescription.UTF8String : "empty answer");
                done(nil);
                return;
            }
            gCMs = [NSMutableArray array];
            for (NSDictionary *s in servers) [gCMs addObject:s[@"endpoint"]];
            if (!gBadCMs) gBadCMs = [NSMutableSet set];
            FetchCMs(done);
        });
    }] resume];
}

// --- a link: one WebSocket to a CM, framing, jobs ------------------------------------------------

@class RSLink;
typedef void (^RSLinkHandler)(RSLink *link, const RecompSteamMessage *msg);

@interface RSLink : NSObject <NSURLSessionWebSocketDelegate>
@property (nonatomic, copy) NSString *endpoint;
@property (nonatomic, copy) void (^onOpen)(RSLink *link);
@property (nonatomic, copy) void (^onClose)(RSLink *link);
@property (nonatomic, copy) RSLinkHandler onMessage;   // messages no job waits for
@property (nonatomic) uint64_t steamid;
@property (nonatomic) int32_t sessionid;
@property (nonatomic) BOOL open, closed;
@end

typedef struct {
    uint32_t emsg;
    bool proto;
    uint64_t steamid, jobid_source, jobid_target;
    int32_t sessionid, eresult;
    uint32_t routing_appid;
    char job_name[128];
    bool has_job_name;
    const uint8_t *body;
    size_t length;
} RSParsed;

static bool ParseMessage(const uint8_t *p, size_t n, RSParsed *m)
{
    memset(m, 0, sizeof *m);
    m->jobid_source = m->jobid_target = kNoJob;
    m->eresult = RecompSteamResultOK;
    if (n < 8) return false;
    uint32_t raw = p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
    m->emsg = raw & 0x7fffffff;
    m->proto = raw & 0x80000000;
    if (m->proto) {
        uint32_t hl = p[4] | p[5] << 8 | p[6] << 16 | (uint32_t)p[7] << 24;
        if (hl > n - 8) return false;
        rs_pb_reader r = rs_pb_read(p + 8, hl);
        rs_pb_field f;
        m->eresult = 2;
        while (rs_pb_next(&r, &f)) {
            switch (f.number) {
            case 1: m->steamid = f.varint; break;
            case 2: m->sessionid = (int32_t)f.varint; break;
            case 3: m->routing_appid = (uint32_t)f.varint; break;
            case 10: m->jobid_source = f.varint; break;
            case 11: m->jobid_target = f.varint; break;
            case 12:
                if (f.wire == RS_PB_BYTES) {
                    size_t k = MIN(f.length, sizeof m->job_name - 1);
                    memcpy(m->job_name, f.data, k);
                    m->job_name[k] = 0;
                    m->has_job_name = true;
                }
                break;
            case 13: m->eresult = (int32_t)f.varint; break;
            }
        }
        m->body = p + 8 + hl;
        m->length = n - 8 - hl;
        return true;
    }
    // ExtendedClientMsgHdr: size(1) version(2) target(8) source(8) canary(1) steamid(8) session(4)
    if (n < 36) return false;
    uint64_t t = 0, s = 0, id = 0;
    for (int i = 0; i < 8; i++) {
        t |= (uint64_t)p[7 + i] << (8 * i);
        s |= (uint64_t)p[15 + i] << (8 * i);
        id |= (uint64_t)p[24 + i] << (8 * i);
    }
    m->jobid_target = t;
    m->jobid_source = s;
    m->steamid = id;
    m->sessionid = (int32_t)(p[32] | p[33] << 8 | p[34] << 16 | (uint32_t)p[35] << 24);
    m->body = p + 36;
    m->length = n - 36;
    return true;
}

@implementation RSLink {
    NSURLSession *_session;
    NSURLSessionWebSocketTask *_task;
    NSMutableDictionary<NSNumber *, RecompSteamReply> *_jobs;
}
static uint64_t gNextJob = 1;

- (instancetype)init
{
    if ((self = [super init])) _jobs = [NSMutableDictionary dictionary];
    return self;
}

- (void)connect:(NSString *)endpoint
{
    self.endpoint = endpoint;
    NSOperationQueue *oq = [[NSOperationQueue alloc] init];
    oq.underlyingQueue = Q;
    oq.maxConcurrentOperationCount = 1;
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.timeoutIntervalForRequest = 30;
    _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:oq];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"wss://%@/cmsocket/", endpoint]];
    _task = [_session webSocketTaskWithURL:url];
    _task.maximumMessageSize = 64 << 20;
    [_task resume];
    // No answer within 10 s: give up on this CM.
    __weak RSLink *weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), Q, ^{
        RSLink *link = weak;
        if (link && !link.open && !link.closed) {
            RLOG("CM %s did not answer", endpoint.UTF8String);
            [gBadCMs addObject:endpoint];
            [link close];
        }
    });
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task
    didOpenWithProtocol:(NSString *)protocol
{
    if (task != _task || self.closed) return;
    self.open = YES;
    [self receive];
    if (self.onOpen) self.onOpen(self);
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task
    didCloseWithCode:(NSURLSessionWebSocketCloseCode)code reason:(NSData *)reason
{
    if (task == _task) [self close];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    if (task != _task) return;
    if (error && !self.closed) RLOG("connection to %s ended: %s", self.endpoint.UTF8String, error.localizedDescription.UTF8String);
    if (!self.open && self.endpoint) [gBadCMs addObject:self.endpoint];
    [self close];
}

- (void)receive
{
    __weak RSLink *weak = self;
    NSURLSessionWebSocketTask *task = _task;
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        dispatch_async(Q, ^{
            RSLink *link = weak;
            if (!link || link.closed) return;
            if (error || !message) {
                [link close];
                return;
            }
            if (message.type == NSURLSessionWebSocketMessageTypeData)
                [link handle:message.data.bytes length:message.data.length];
            [link receive];
        });
    }];
}

- (void)handle:(const uint8_t *)bytes length:(size_t)length
{
    RSParsed m;
    if (!ParseMessage(bytes, length, &m)) return;
    if (m.emsg == RS_Multi) {
        rs_pb_field f;
        uint64_t unzipped = rs_pb_get_varint(m.body, m.length, 1, 0);
        if (!rs_pb_get(m.body, m.length, 2, &f)) return;
        uint8_t *buf = NULL;
        size_t n = f.length;
        const uint8_t *p = f.data;
        if (unzipped) {
            if (!rs_gunzip(f.data, f.length, (size_t)unzipped, &buf, &n)) {
                RLOG("cannot unpack a message from Steam");
                return;
            }
            p = buf;
        }
        size_t off = 0;
        while (off + 4 <= n && !self.closed) {
            uint32_t sub = p[off] | p[off + 1] << 8 | p[off + 2] << 16 | (uint32_t)p[off + 3] << 24;
            if (sub > n - off - 4) break;
            [self handle:p + off + 4 length:sub];
            off += 4 + sub;
        }
        free(buf);
        return;
    }
    RecompSteamMessage msg = {
        .emsg = m.emsg, .eresult = m.eresult, .body = m.body, .length = m.length, .steamid = m.steamid,
        .jobid_source = m.jobid_source, .jobid_target = m.jobid_target,
        .target_job_name = m.has_job_name ? m.job_name : NULL, .routing_appid = m.routing_appid,
    };
    if (m.jobid_target != kNoJob) {
        RecompSteamReply reply = _jobs[@(m.jobid_target)];
        if (reply) {
            [_jobs removeObjectForKey:@(m.jobid_target)];
            reply(&msg);
            return;
        }
    }
    if (self.onMessage) self.onMessage(self, &msg);
}

- (void)send:(uint32_t)emsg body:(const void *)body length:(size_t)length jobName:(const char *)name
     routing:(uint32_t)routing timeout:(double)timeout reply:(RecompSteamReply)reply
{
    if (!self.open || self.closed) {
        if (reply) {
            RecompSteamMessage none = {.emsg = 0, .eresult = RecompSteamResultTimeout};
            reply(&none);
        }
        return;
    }
    uint64_t job = kNoJob;
    if (reply) {
        job = gNextJob++;
        _jobs[@(job)] = [reply copy];
        __weak RSLink *weak = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout > 0 ? timeout : 20) * NSEC_PER_SEC)), Q, ^{
            RSLink *link = weak;
            if (link) [link expire:job];
        });
    }
    bool anonymous = emsg == RS_ClientHello || emsg == RS_ServiceMethodCallFromClientNonAuthed;
    rs_pb_writer h = {0};
    rs_pb_fixed64(&h, 1, anonymous ? 0 : self.steamid);
    rs_pb_varint(&h, 2, (uint64_t)(int64_t)(anonymous ? 0 : self.sessionid));
    if (routing) rs_pb_varint(&h, 3, routing);
    rs_pb_fixed64(&h, 10, job);
    rs_pb_fixed64(&h, 11, kNoJob);
    if (name) rs_pb_string(&h, 12, name);
    NSMutableData *frame = [NSMutableData dataWithCapacity:8 + h.length + length];
    uint32_t words[2] = {CFSwapInt32HostToLittle(emsg | 0x80000000u), CFSwapInt32HostToLittle((uint32_t)h.length)};
    [frame appendBytes:words length:8];
    [frame appendBytes:h.data length:h.length];
    if (length) [frame appendBytes:body length:length];
    rs_pb_free(&h);
    NSURLSessionWebSocketMessage *m = [[NSURLSessionWebSocketMessage alloc] initWithData:frame];
    __weak RSLink *weak = self;
    [_task sendMessage:m completionHandler:^(NSError *error) {
        if (error) dispatch_async(Q, ^{ [weak close]; });
    }];
}

- (void)expire:(uint64_t)job
{
    RecompSteamReply reply = _jobs[@(job)];
    if (!reply) return;
    [_jobs removeObjectForKey:@(job)];
    RecompSteamMessage none = {.emsg = 0, .eresult = RecompSteamResultTimeout};
    reply(&none);
}

- (void)close
{
    if (self.closed) return;
    self.closed = YES;
    self.open = NO;
    [_task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    [_session invalidateAndCancel];
    NSArray *pending = _jobs.allValues;
    [_jobs removeAllObjects];
    for (RecompSteamReply reply in pending) {
        RecompSteamMessage none = {.emsg = 0, .eresult = RecompSteamResultTimeout};
        reply(&none);
    }
    if (self.onClose) self.onClose(self);
    self.onClose = nil;
    self.onOpen = nil;
    self.onMessage = nil;
}
@end

// --- the logged-on session ---------------------------------------------------------------------

static RSLink *gLink;
static NSString *gToken, *gMachineName;
static uint64_t gTokenSteamID;
static BOOL gStarted, gStopped, gDenied;
static int gBackoff;                 // seconds before the next reconnect
static uint64_t gConnectGen;         // bumps per connection attempt
static NSMutableArray<NSNumber *> *gPlaying;
static NSMutableDictionary<NSNumber *, void (^)(RecompSteamState)> *gObservers;
static NSMutableDictionary<NSNumber *, NSArray *> *gSubs;   // id -> @[emsg or name, handler]
static int gNextId = 1;
static double gConnectedAt;

static void Connect(void);
static void OnLoggedOn(const RecompSteamMessage *msg);
static void TicketsOnLogon(void);
static void TicketsOnDisconnect(void);
static void HandleTicketMessage(const RecompSteamMessage *msg);
void RS_SendAuthList(uint32_t force_app, void (^acked)(void));

static void SetState(RecompSteamState s)
{
    os_unfair_lock_lock(&gLock);
    RecompSteamState old = gState;
    gState = s;
    os_unfair_lock_unlock(&gLock);
    if (old == s) return;
    static const char *names[] = {"offline", "connecting", "logged on", "sign-in refused"};
    RLOG("%s", names[s]);
    for (NSNumber *k in gObservers.allKeys) {
        void (^h)(RecompSteamState) = gObservers[k];
        if (h) h(s);
    }
}

int RecompSteam_AddStateObserver(void (^handler)(RecompSteamState state))
{
    int ident = __atomic_fetch_add(&gNextId, 1, __ATOMIC_RELAXED);
    void (^h)(RecompSteamState) = [handler copy];
    dispatch_async(Q, ^{
        if (!gObservers) gObservers = [NSMutableDictionary dictionary];
        gObservers[@(ident)] = h;
        h(RecompSteam_State());
    });
    return ident;
}

void RecompSteam_RemoveObserver(int observer)
{
    dispatch_async(Q, ^{ [gObservers removeObjectForKey:@(observer)]; });
}

void RecompSteam_WhenLoggedOn(double timeout, void (^done)(bool loggedOn))
{
    void (^d)(bool) = [done copy];
    dispatch_async(Q, ^{
        RecompSteamState s = RecompSteam_State();
        if (s == RecompSteamLoggedOn || s == RecompSteamDenied || !gStarted || gStopped) {
            d(s == RecompSteamLoggedOn);
            return;
        }
        __block BOOL fired = NO;
        __block int obs = 0;
        void (^finish)(bool) = ^(bool ok) {
            if (fired) return;
            fired = YES;
            [gObservers removeObjectForKey:@(obs)];
            d(ok);
        };
        obs = __atomic_fetch_add(&gNextId, 1, __ATOMIC_RELAXED);
        if (!gObservers) gObservers = [NSMutableDictionary dictionary];
        gObservers[@(obs)] = ^(RecompSteamState st) {
            if (st == RecompSteamLoggedOn || st == RecompSteamDenied) finish(st == RecompSteamLoggedOn);
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), Q, ^{ finish(false); });
    });
}

int RecompSteam_Subscribe(uint32_t emsg, RecompSteamReply handler)
{
    int ident = __atomic_fetch_add(&gNextId, 1, __ATOMIC_RELAXED);
    RecompSteamReply h = [handler copy];
    dispatch_async(Q, ^{
        if (!gSubs) gSubs = [NSMutableDictionary dictionary];
        gSubs[@(ident)] = @[@(emsg), h];
    });
    return ident;
}

int RecompSteam_SubscribeService(const char *method, RecompSteamReply handler)
{
    int ident = __atomic_fetch_add(&gNextId, 1, __ATOMIC_RELAXED);
    RecompSteamReply h = [handler copy];
    NSString *name = @(method);
    dispatch_async(Q, ^{
        if (!gSubs) gSubs = [NSMutableDictionary dictionary];
        gSubs[@(ident)] = @[name, h];
    });
    return ident;
}

void RecompSteam_Unsubscribe(int subscription)
{
    dispatch_async(Q, ^{ [gSubs removeObjectForKey:@(subscription)]; });
}

static void Dispatch(const RecompSteamMessage *msg)
{
    NSString *name = msg->target_job_name ? @(msg->target_job_name) : nil;
    for (NSNumber *k in gSubs.allKeys) {
        NSArray *sub = gSubs[k];
        if (!sub) continue;
        id key = sub[0];
        bool hit = [key isKindOfClass:NSNumber.class] ? [key unsignedIntValue] == msg->emsg
                 : (name && msg->emsg == RS_ServiceMethod && [key isEqualToString:name]);
        if (hit) ((RecompSteamReply)sub[1])(msg);
    }
}

// machine_id: the binary KeyValues blob the Steam client sends, three SHA-1 hex strings
// derived from this device and account, so it stays the same across launches.
static NSData *MachineID(void)
{
    char host[256] = "";
    size_t n = sizeof host;
    sysctlbyname("kern.uuid", host, &n, NULL, 0);
    NSMutableData *d = [NSMutableData data];
    uint8_t zero = 0, one = 1, eight = 8;
    [d appendBytes:&zero length:1];
    [d appendBytes:"MessageObject" length:14];
    const char *keys[] = {"BB3", "FF2", "3B3"};
    for (int i = 0; i < 3; i++) {
        NSString *seed = [NSString stringWithFormat:@"recomp-%s-%llu-%d", host, gTokenSteamID, i];
        uint8_t sha[CC_SHA1_DIGEST_LENGTH];
        NSData *s = [seed dataUsingEncoding:NSUTF8StringEncoding];
        CC_SHA1(s.bytes, (CC_LONG)s.length, sha);
        char hex[41];
        for (int k = 0; k < 20; k++) snprintf(hex + 2 * k, 3, "%02x", sha[k]);
        [d appendBytes:&one length:1];
        [d appendBytes:keys[i] length:4];
        [d appendBytes:hex length:41];
    }
    [d appendBytes:&eight length:1];
    [d appendBytes:&eight length:1];
    return d;
}

static uint32_t ClientOSType(void)
{
#if TARGET_OS_IPHONE
    return (uint32_t)-600;   // k_EOSTypeIOSUnknown
#else
    return (uint32_t)-102;   // k_EOSTypeMacOSUnknown
#endif
}

static void SendLogon(RSLink *link)
{
    rs_pb_writer w = {0};
    rs_pb_varint(&w, 1, RS_PROTOCOL_VERSION);
    if (RecompSteam_CellID()) rs_pb_varint(&w, 3, RecompSteam_CellID());
    rs_pb_string(&w, 6, "english");
    rs_pb_varint(&w, 7, ClientOSType());
    rs_pb_bool(&w, 8, true);
    // The logon id (an obfuscated private IP): Steam replaces a session that logs on again
    // with the same token and id (LogonSessionReplaced), so each process takes its own.
    static uint32_t logon_id;
    if (!logon_id) logon_id = arc4random() | 1;
    rs_pb_writer ip = {0};
    rs_pb_fixed32(&ip, 1, logon_id);
    rs_pb_message(&w, 11, &ip);
    rs_pb_free(&ip);
    NSData *mid = MachineID();
    rs_pb_bytes(&w, 30, mid.bytes, mid.length);
    rs_pb_varint(&w, 33, 2);  // chat_mode: new chat
    rs_pb_string(&w, 96, gMachineName.UTF8String);
    rs_pb_bool(&w, 102, true);
    rs_pb_string(&w, 108, gToken.UTF8String);
    link.steamid = gTokenSteamID;
    link.sessionid = 0;
    [link send:RS_ClientLogon body:w.data length:w.length jobName:NULL routing:0 timeout:0 reply:nil];
    rs_pb_free(&w);
}

static void ScheduleReconnect(void)
{
    if (gStopped || gDenied) return;
    int delay = gBackoff ? gBackoff : 1;
    gBackoff = MIN(MAX(delay * 2, 2), 60);
    uint64_t gen = ++gConnectGen;
    RLOG("reconnecting in %d s", delay);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay * NSEC_PER_SEC), Q, ^{
        if (gen == gConnectGen && !gLink) Connect();
    });
}

static void Heartbeat(RSLink *link, int seconds)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)seconds * NSEC_PER_SEC), Q, ^{
        if (link != gLink || link.closed) return;
        [link send:RS_ClientHeartBeat body:NULL length:0 jobName:NULL routing:0 timeout:0 reply:nil];
        Heartbeat(link, seconds);
    });
}

static void SendGamesPlayed(void)
{
    if (RecompSteam_State() != RecompSteamLoggedOn) return;
    rs_pb_writer w = {0};
    for (NSNumber *app in gPlaying) {
        rs_pb_writer g = {0};
        rs_pb_fixed64(&g, 2, app.unsignedLongLongValue);   // game_id: the app id for a Steam game
        rs_pb_message(&w, 1, &g);
        rs_pb_free(&g);
    }
    rs_pb_varint(&w, 2, ClientOSType());
    [gLink send:RS_ClientGamesPlayed body:w.data length:w.length jobName:NULL routing:0 timeout:0 reply:nil];
    rs_pb_free(&w);
}

static void OnMessage(RSLink *link, const RecompSteamMessage *msg)
{
    if (link != gLink) return;
    switch (msg->emsg) {
    case RS_ClientLogOnResponse: OnLoggedOn(msg); return;
    case RS_ClientLoggedOff: {
        int32_t er = (int32_t)rs_pb_get_varint(msg->body, msg->length, 1, 2);
        RLOG("Steam logged the session off (EResult %d)", er);
        if (er == RecompSteamResultLoggedInElsewhere) gBackoff = 120;   // signed in elsewhere: retry slowly
        [link close];
        return;
    }
    case RS_ClientAccountInfo: {
        char name[128];
        rs_pb_get_string(msg->body, msg->length, 1, name, sizeof name);
        os_unfair_lock_lock(&gLock);
        strlcpy(gPersona, name, sizeof gPersona);
        os_unfair_lock_unlock(&gLock);
        break;
    }
    case RS_ClientPlayingSessionState: {
        bool blocked = rs_pb_get_varint(msg->body, msg->length, 2, 0);
        uint32_t app = (uint32_t)rs_pb_get_varint(msg->body, msg->length, 3, 0);
        os_unfair_lock_lock(&gLock);
        gPlayingBlocked = blocked;
        gPlayingApp = app;
        os_unfair_lock_unlock(&gLock);
        if (blocked) RLOG("the account is playing app %u on another device", app);
        break;
    }
    case RS_ClientGameConnectTokens:
    case RS_ClientTicketAuthComplete:
        HandleTicketMessage(msg);
        break;
    }
    Dispatch(msg);
}

static void OnLoggedOn(const RecompSteamMessage *msg)
{
    rs_pb_field f;
    int32_t er = (int32_t)rs_pb_get_varint(msg->body, msg->length, 1, 2);
    if (er != RecompSteamResultOK) {
        RLOG("logon refused (EResult %d)", er);
        switch (er) {
        case RecompSteamResultInvalidPassword: case RecompSteamResultAccessDenied: case RecompSteamResultRevoked:
        case RecompSteamResultExpired: case 43 /* AccountDisabled */: case 18 /* AccountNotFound */:
            gDenied = YES;
            [gLink close];
            SetState(RecompSteamDenied);
            return;
        }
        [gLink close];
        return;
    }
    gBackoff = 0;
    gLink.steamid = msg->steamid ? msg->steamid : rs_pb_get_varint(msg->body, msg->length, 20, gTokenSteamID);
    uint32_t ip = 0;
    if (rs_pb_get(msg->body, msg->length, 15, &f) && f.wire == RS_PB_BYTES)
        ip = (uint32_t)rs_pb_get_varint(f.data, f.length, 1, 0);
    if (!ip) ip = (uint32_t)rs_pb_get_varint(msg->body, msg->length, 4, 0);
    os_unfair_lock_lock(&gLock);
    gSteamID = gLink.steamid;
    gCellID = (uint32_t)rs_pb_get_varint(msg->body, msg->length, 7, gCellID);
    gPublicIP = ip;
    gServerTime = (uint32_t)rs_pb_get_varint(msg->body, msg->length, 5, 0);
    gServerTimeAt = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_unlock(&gLock);
    gConnectedAt = CFAbsoluteTimeGetCurrent();
    int beat = (int)rs_pb_get_varint(msg->body, msg->length, 3, 9);
    Heartbeat(gLink, beat > 0 ? beat : 9);
    SetState(RecompSteamLoggedOn);
    SendGamesPlayed();
    TicketsOnLogon();
}

static void Connect(void)
{
    if (gLink || gStopped || gDenied || !gToken) return;
    SetState(RecompSteamConnecting);
    uint64_t gen = ++gConnectGen;
    FetchCMs(^(NSString *endpoint) {
        if (gen != gConnectGen || gLink || gStopped) return;
        if (!endpoint) {
            SetState(RecompSteamOffline);
            ScheduleReconnect();
            return;
        }
        RSLink *link = [[RSLink alloc] init];
        gLink = link;
        link.onOpen = ^(RSLink *l) {
            RLOG("connected to %s, logging on", l.endpoint.UTF8String);
            SendLogon(l);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), Q, ^{
                if (l == gLink && RecompSteam_State() != RecompSteamLoggedOn && !l.closed) {
                    RLOG("no logon answer");
                    [l close];
                }
            });
        };
        link.onMessage = ^(RSLink *l, const RecompSteamMessage *m) { OnMessage(l, m); };
        link.onClose = ^(RSLink *l) {
            if (l != gLink) return;
            gLink = nil;
            TicketsOnDisconnect();
            if (!gDenied) SetState(RecompSteamOffline);
            ScheduleReconnect();
        };
        [link connect:endpoint];
    });
}

void RecompSteam_Start(const char *refresh_token, uint32_t app_id, const char *machine_name)
{
    if (!refresh_token || !*refresh_token) return;
    NSString *token = @(refresh_token);
    NSString *machine = machine_name ? @(machine_name) : @"Recomp";
    dispatch_async(Q, ^{
        BOOL same = gStarted && [token isEqualToString:gToken] && !gStopped;
        os_unfair_lock_lock(&gLock);
        gAppID = app_id;
        os_unfair_lock_unlock(&gLock);
        if (same) return;
        gToken = token;
        gMachineName = machine;
        gTokenSteamID = rs_token_steamid(token.UTF8String);
        if (!gTokenSteamID) RLOG("the refresh token names no account");
        gStarted = YES;
        gStopped = gDenied = NO;
        gBackoff = 0;
        if (gLink) {
            RSLink *old = gLink;
            gLink = nil;
            old.onClose = nil;
            [old close];
        }
        Connect();
    });
}

void RecompSteam_Stop(void)
{
    dispatch_async(Q, ^{
        gStopped = YES;
        ++gConnectGen;
        RSLink *link = gLink;
        if (!link) return;
        if (link.open && RecompSteam_State() == RecompSteamLoggedOn)
            [link send:RS_ClientLogOff body:NULL length:0 jobName:NULL routing:0 timeout:0 reply:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), Q, ^{ [link close]; });
    });
}

void RecompSteam_Send(uint32_t emsg, const void *body, size_t length)
{
    NSData *d = [NSData dataWithBytes:body length:length];
    dispatch_async(Q, ^{
        if (RecompSteam_State() != RecompSteamLoggedOn) return;
        [gLink send:emsg body:d.bytes length:d.length jobName:NULL routing:0 timeout:0 reply:nil];
    });
}

void RecompSteam_SendJob(uint32_t emsg, const void *body, size_t length, uint32_t routing_appid,
                         double timeout, RecompSteamReply reply)
{
    NSData *d = [NSData dataWithBytes:body length:length];
    RecompSteamReply r = [reply copy];
    dispatch_async(Q, ^{
        RSLink *link = RecompSteam_State() == RecompSteamLoggedOn ? gLink : nil;
        if (!link) {
            RecompSteamMessage none = {.emsg = 0, .eresult = RecompSteamResultTimeout};
            r(&none);
            return;
        }
        [link send:emsg body:d.bytes length:d.length jobName:NULL routing:routing_appid timeout:timeout reply:r];
    });
}

void RecompSteam_Call(const char *method, const void *request, size_t length, double timeout, RecompSteamReply reply)
{
    NSData *d = [NSData dataWithBytes:request length:length];
    NSString *name = @(method);
    RecompSteamReply r = [reply copy];
    double limit = timeout > 0 ? timeout : 20;
    double start = CFAbsoluteTimeGetCurrent();
    __block int tries = 0;
    __block void (^attempt)(void);
    attempt = ^{
        RecompSteam_WhenLoggedOn(limit - (CFAbsoluteTimeGetCurrent() - start), ^(bool ok) {
            double left = limit - (CFAbsoluteTimeGetCurrent() - start);
            if (!ok || !gLink || left <= 0) {
                RecompSteamMessage none = {.emsg = 0, .eresult = RecompSteamResultTimeout};
                attempt = nil;
                r(&none);
                return;
            }
            RSLink *link = gLink;
            [link send:RS_ServiceMethodCallFromClient body:d.bytes length:d.length jobName:name.UTF8String routing:0
                timeout:left reply:^(const RecompSteamMessage *m) {
                // The connection dropped under the call (a reconnect, a new token): send it
                // again once the session is back, within the same time limit.
                if (!m->emsg && link.closed && ++tries < 3 && limit - (CFAbsoluteTimeGetCurrent() - start) > 1) {
                    attempt();
                    return;
                }
                attempt = nil;
                r(m);
            }];
        });
    };
    attempt();
}

void RecompSteam_GamesPlayed(const uint32_t *app_ids, int count)
{
    NSMutableArray *apps = [NSMutableArray array];
    for (int i = 0; i < count; i++) [apps addObject:@(app_ids[i])];
    dispatch_async(Q, ^{
        if ([apps isEqualToArray:gPlaying ?: @[]] && gPlaying) return;
        gPlaying = apps;
        SendGamesPlayed();
    });
}

void RecompSteam_KickPlayingSession(void)
{
    rs_pb_writer w = {0};
    rs_pb_bool(&w, 1, true);  // only_stop_game
    RecompSteam_Send(RS_ClientKickPlayingSession, w.data, w.length);
    rs_pb_free(&w);
}

// --- unauthenticated calls (sign-in): a link of their own ---------------------------------------

static RSLink *gAnon;
static NSMutableArray *gAnonWaiting;   // blocks run once gAnon is open
static uint64_t gAnonUse;

static void AnonIdle(uint64_t use)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), Q, ^{
        if (use == gAnonUse && gAnon) [gAnon close];
    });
}

void RecompSteam_CallUnauthed(const char *method, const void *request, size_t length, double timeout,
                              RecompSteamReply reply)
{
    NSData *d = [NSData dataWithBytes:request length:length];
    NSString *name = @(method);
    RecompSteamReply r = [reply copy];
    dispatch_async(Q, ^{
        uint64_t use = ++gAnonUse;
        void (^go)(RSLink *) = ^(RSLink *link) {
            if (!link) {
                RecompSteamMessage none = {.emsg = 0, .eresult = RecompSteamResultTimeout};
                r(&none);
                return;
            }
            [link send:RS_ServiceMethodCallFromClientNonAuthed body:d.bytes length:d.length jobName:name.UTF8String
               routing:0 timeout:timeout reply:^(const RecompSteamMessage *m) {
                r(m);
                AnonIdle(use);
            }];
        };
        if (gAnon.open) {
            go(gAnon);
            return;
        }
        if (!gAnonWaiting) gAnonWaiting = [NSMutableArray array];
        [gAnonWaiting addObject:go];
        if (gAnon) return;
        FetchCMs(^(NSString *endpoint) {
            void (^flush)(RSLink *) = ^(RSLink *link) {
                NSArray *waiting = gAnonWaiting;
                gAnonWaiting = nil;
                for (void (^w)(RSLink *) in waiting) w(link);
            };
            if (!endpoint) {
                flush(nil);
                return;
            }
            RSLink *link = [[RSLink alloc] init];
            gAnon = link;
            link.onOpen = ^(RSLink *l) {
                rs_pb_writer w = {0};
                rs_pb_varint(&w, 1, RS_PROTOCOL_VERSION);
                [l send:RS_ClientHello body:w.data length:w.length jobName:NULL routing:0 timeout:0 reply:nil];
                rs_pb_free(&w);
                flush(l);
            };
            link.onClose = ^(RSLink *l) {
                if (gAnon == l) gAnon = nil;
                flush(nil);
            };
            [link connect:endpoint];
        });
    });
}

// --- ownership and auth session tickets ------------------------------------------------------------

static NSMutableArray<NSData *> *gGCTokens;
static NSMutableDictionary<NSNumber *, NSData *> *gOwnership;    // app -> ticket
static NSMutableArray<NSDictionary *> *gActiveTickets;           // {handle, app, crc, ticket(52 bytes)}
static uint32_t gAuthSeqMe, gAuthSeqThem, gConnectionCount, gNextHandle = 1;
static NSMutableArray *gTokenWaiters;

static uint32_t LE32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

static void TicketsOnLogon(void)
{
    // Tickets name the public IP; one fetched before a reconnect may no longer match.
    [gOwnership removeAllObjects];
    if (gActiveTickets.count) {
        // Re-announce the live tickets on the new connection.
        gAuthSeqMe = gAuthSeqThem = 0;
        RS_SendAuthList(0, nil);
    }
    uint32_t app = RecompSteam_AppID();
    if (app) RecompSteam_AppOwnershipTicket(app, ^(int32_t er, const uint8_t *t, size_t n) {
        RLOG("ownership ticket for app %u: EResult %d, %zu bytes", app, er, n);
    });
}

static void TicketsOnDisconnect(void)
{
    [gGCTokens removeAllObjects];
}

static void HandleTicketMessage(const RecompSteamMessage *msg)
{
    if (msg->emsg == RS_ClientGameConnectTokens) {
        if (!gGCTokens) gGCTokens = [NSMutableArray array];
        rs_pb_reader r = rs_pb_read(msg->body, msg->length);
        rs_pb_field f;
        while (rs_pb_next(&r, &f))
            if (f.number == 2 && f.wire == RS_PB_BYTES) [gGCTokens addObject:[NSData dataWithBytes:f.data length:f.length]];
        uint64_t keep = rs_pb_get_varint(msg->body, msg->length, 1, 10);
        while (gGCTokens.count > keep && keep) [gGCTokens removeObjectAtIndex:0];
        NSArray *waiters = gTokenWaiters;
        gTokenWaiters = nil;
        for (void (^w)(void) in waiters) w();
    } else if (msg->emsg == RS_ClientTicketAuthComplete) {
        uint32_t crc = (uint32_t)rs_pb_get_varint(msg->body, msg->length, 6, 0);
        uint32_t response = (uint32_t)rs_pb_get_varint(msg->body, msg->length, 4, 0);
        uint64_t owner = rs_pb_get_varint(msg->body, msg->length, 8, 0);
        RLOG("ticket %08x: auth state %llu, response %u", crc, rs_pb_get_varint(msg->body, msg->length, 3, 0), response);
        NSUInteger i = [gActiveTickets indexOfObjectPassingTest:^BOOL(NSDictionary *t, NSUInteger k, BOOL *stop) {
            return [t[@"crc"] unsignedIntValue] == crc;
        }];
        if (i == NSNotFound) return;
        NSDictionary *t = gActiveTickets[i];
        void (^done)(uint32_t, uint64_t) = t[@"done"];
        if (response != 0) [gActiveTickets removeObjectAtIndex:i];   // anything but OK ends it
        if (done) done(response, owner);
    }
}

void RecompSteam_AppOwnershipTicket(uint32_t app_id, void (^done)(int32_t, const uint8_t *, size_t))
{
    void (^d)(int32_t, const uint8_t *, size_t) = [done copy];
    dispatch_async(Q, ^{
        NSData *cached = gOwnership[@(app_id)];
        if (cached.length >= 40) {
            uint32_t expires = LE32((const uint8_t *)cached.bytes + 36);
            if (expires > RecompSteam_ServerTime() + 6 * 3600) {
                d(RecompSteamResultOK, cached.bytes, cached.length);
                return;
            }
        }
        rs_pb_writer w = {0};
        rs_pb_varint(&w, 1, app_id);
        RecompSteam_SendJob(RS_ClientGetAppOwnershipTicket, w.data, w.length, 0, 10, ^(const RecompSteamMessage *m) {
            if (m->eresult == RecompSteamResultTimeout && !m->length) {
                d(RecompSteamResultTimeout, NULL, 0);
                return;
            }
            int32_t er = (int32_t)rs_pb_get_varint(m->body, m->length, 1, 2);
            rs_pb_field t;
            if (er == RecompSteamResultOK && rs_pb_get(m->body, m->length, 3, &t) && t.length > 10) {
                if (!gOwnership) gOwnership = [NSMutableDictionary dictionary];
                gOwnership[@(app_id)] = [NSData dataWithBytes:t.data length:t.length];
                d(er, t.data, t.length);
            } else {
                d(er == RecompSteamResultOK ? RecompSteamResultFail : er, NULL, 0);
            }
        });
        rs_pb_free(&w);
    });
}

void RS_SendAuthList(uint32_t force_app, void (^acked)(void))
{
    void (^a)(void) = [acked copy];
    NSMutableOrderedSet *apps = [NSMutableOrderedSet orderedSet];
    rs_pb_writer w = {0};
    rs_pb_varint(&w, 1, gGCTokens.count);
    rs_pb_varint(&w, 2, gAuthSeqMe);
    rs_pb_varint(&w, 3, gAuthSeqThem);
    for (NSDictionary *t in gActiveTickets) {
        NSData *ticket = t[@"ticket"];
        rs_pb_writer e = {0};
        rs_pb_varint(&e, 1, [t[@"estate"] unsignedIntValue]);
        rs_pb_fixed64(&e, 3, [t[@"steamid"] unsignedLongLongValue]);
        rs_pb_fixed64(&e, 4, [t[@"app"] unsignedIntValue]);
        rs_pb_varint(&e, 5, 1);   // h_steam_pipe
        rs_pb_varint(&e, 6, [t[@"crc"] unsignedIntValue]);
        rs_pb_bytes(&e, 7, ticket.bytes, ticket.length);
        rs_pb_message(&w, 4, &e);
        rs_pb_free(&e);
        [apps addObject:t[@"app"]];
    }
    if (force_app) [apps addObject:@(force_app)];
    for (NSNumber *app in apps) rs_pb_varint(&w, 5, app.unsignedIntValue);
    rs_pb_varint(&w, 6, ++gAuthSeqMe);
    RecompSteam_SendJob(RS_ClientAuthList, w.data, w.length, 0, 10, ^(const RecompSteamMessage *m) {
        if (m->length) gAuthSeqThem = (uint32_t)rs_pb_get_varint(m->body, m->length, 3, gAuthSeqThem);
        if (a) a();
    });
    rs_pb_free(&w);
}

// Builds the ticket from a GC token and the ownership ticket; both must be at hand.
static NSData *BuildTicket(uint32_t app_id)
{
    NSData *own = gOwnership[@(app_id)];
    if (!own || !gGCTokens.count) return nil;
    NSData *gc = gGCTokens.firstObject;
    [gGCTokens removeObjectAtIndex:0];
    NSMutableData *t = [NSMutableData data];
    uint32_t v;
#define PUT32(x) (v = CFSwapInt32HostToLittle((uint32_t)(x)), [t appendBytes:&v length:4])
    PUT32(gc.length);
    [t appendData:gc];
    PUT32(24);
    PUT32(1);
    PUT32(2);
    PUT32(RecompSteam_PublicIP());
    PUT32(0);
    PUT32((uint32_t)((CFAbsoluteTimeGetCurrent() - gConnectedAt) * 1000));
    PUT32(++gConnectionCount);
    PUT32(own.length);
    [t appendData:own];
#undef PUT32
    return t;
}

void RecompSteam_AuthSessionTicket(uint32_t app_id, void (^done)(int32_t, uint32_t, const uint8_t *, size_t))
{
    void (^d)(int32_t, uint32_t, const uint8_t *, size_t) = [done copy];
    RecompSteam_AppOwnershipTicket(app_id, ^(int32_t er, const uint8_t *own, size_t n) {
        if (er != RecompSteamResultOK) {
            d(er, 0, NULL, 0);
            return;
        }
        __block BOOL fired = NO;
        void (^build)(void) = ^{
            if (fired) return;
            fired = YES;
            NSData *ticket = BuildTicket(app_id);
            if (!ticket) {
                d(RecompSteamResultTimeout, 0, NULL, 0);
                return;
            }
            uint32_t handle = gNextHandle++;
            uint32_t gclen = LE32(ticket.bytes);
            NSData *auth = [ticket subdataWithRange:NSMakeRange(0, 4 + gclen + 4 + 24)];
            if (!gActiveTickets) gActiveTickets = [NSMutableArray array];
            [gActiveTickets addObject:@{@"handle": @(handle), @"app": @(app_id), @"estate": @0, @"steamid": @0,
                                        @"crc": @(rs_crc32(auth.bytes, auth.length)), @"ticket": auth}];
            RS_SendAuthList(0, ^{ d(RecompSteamResultOK, handle, ticket.bytes, ticket.length); });
        };
        if (gGCTokens.count) {
            build();
            return;
        }
        if (!gTokenWaiters) gTokenWaiters = [NSMutableArray array];
        [gTokenWaiters addObject:build];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), Q, build);
    });
}

void RecompSteam_CancelTicket(uint32_t handle)
{
    dispatch_async(Q, ^{
        NSUInteger i = [gActiveTickets indexOfObjectPassingTest:^BOOL(NSDictionary *t, NSUInteger k, BOOL *stop) {
            return [t[@"handle"] unsignedIntValue] == handle;
        }];
        if (i == NSNotFound) return;
        uint32_t app = [gActiveTickets[i][@"app"] unsignedIntValue];
        [gActiveTickets removeObjectAtIndex:i];
        if (RecompSteam_State() == RecompSteamLoggedOn) RS_SendAuthList(app, nil);
    });
}

uint32_t RS_AuthSessionTicketNow(uint32_t app, uint8_t *out, size_t max, uint32_t *length,
                                 void (^activated)(int32_t eresult, uint32_t handle))
{
    __block uint32_t handle = 0;
    void (^a)(int32_t, uint32_t) = [activated copy];
    dispatch_sync(Q, ^{
        if (RecompSteam_State() != RecompSteamLoggedOn) return;
        NSData *ticket = BuildTicket(app);
        if (!ticket || ticket.length > max) return;
        memcpy(out, ticket.bytes, ticket.length);
        *length = (uint32_t)ticket.length;
        uint32_t h = gNextHandle++;
        uint32_t gclen = LE32(ticket.bytes);
        NSData *auth = [ticket subdataWithRange:NSMakeRange(0, 4 + gclen + 4 + 24)];
        if (!gActiveTickets) gActiveTickets = [NSMutableArray array];
        [gActiveTickets addObject:@{@"handle": @(h), @"app": @(app), @"estate": @0, @"steamid": @0,
                                    @"crc": @(rs_crc32(auth.bytes, auth.length)), @"ticket": auth}];
        handle = h;
        RS_SendAuthList(0, ^{ if (a) a(RecompSteamResultOK, h); });
    });
    if (!handle && a) dispatch_async(Q, ^{ a(RecompSteamResultNoConnection, 0); });
    // Running low on GC tokens, or no ownership ticket yet: fetch for the next one.
    RecompSteam_AppOwnershipTicket(app, ^(int32_t er, const uint8_t *t, size_t n) {});
    return handle;
}

int RS_BeginAuthSession(uint32_t app, const uint8_t *ticket, size_t length, uint64_t steamid,
                        void (^done)(uint32_t response, uint64_t owner))
{
    // GC token length (20), token, session header length (24), header, then the ownership ticket.
    if (length < 52 + 4 || LE32(ticket) != 20 || LE32(ticket + 24) != 24) return 1;   // invalid ticket
    if (LE32(ticket + 52) + 52 + 4 > length) return 1;
    const uint8_t *own = ticket + 56;
    if (length >= 56 + 20 && LE32(own + 16) != app) return 4;                         // game mismatch
    NSData *auth = [NSData dataWithBytes:ticket length:52];
    void (^d)(uint32_t, uint64_t) = [done copy];
    __block int result = 0;
    dispatch_sync(Q, ^{
        uint32_t crc = rs_crc32(auth.bytes, auth.length);
        for (NSDictionary *t in gActiveTickets)
            if ([t[@"steamid"] unsignedLongLongValue] == steamid && [t[@"crc"] unsignedIntValue] == crc) {
                result = 2;   // duplicate request
                return;
            }
        NSIndexSet *old = [gActiveTickets indexesOfObjectsPassingTest:^BOOL(NSDictionary *t, NSUInteger k, BOOL *stop) {
            return [t[@"steamid"] unsignedLongLongValue] == steamid && [t[@"app"] unsignedIntValue] == app;
        }];
        [gActiveTickets removeObjectsAtIndexes:old];
        if (!gActiveTickets) gActiveTickets = [NSMutableArray array];
        NSMutableDictionary *entry = [@{@"handle": @0, @"app": @(app), @"estate": @1, @"steamid": @(steamid),
                                        @"crc": @(crc), @"ticket": auth} mutableCopy];
        if (d) entry[@"done"] = d;
        [gActiveTickets addObject:entry];
        if (RecompSteam_State() == RecompSteamLoggedOn) RS_SendAuthList(0, nil);
    });
    return result;
}

void RS_EndAuthSession(uint64_t steamid)
{
    dispatch_async(Q, ^{
        NSIndexSet *gone = [gActiveTickets indexesOfObjectsPassingTest:^BOOL(NSDictionary *t, NSUInteger k, BOOL *stop) {
            return steamid && [t[@"steamid"] unsignedLongLongValue] == steamid;
        }];
        if (!gone.count) return;
        uint32_t app = [gActiveTickets[gone.firstIndex][@"app"] unsignedIntValue];
        [gActiveTickets removeObjectsAtIndexes:gone];
        if (RecompSteam_State() == RecompSteamLoggedOn) RS_SendAuthList(app, nil);
    });
}

void RS_SetAppID(uint32_t app)
{
    os_unfair_lock_lock(&gLock);
    if (!gAppID) gAppID = app;
    os_unfair_lock_unlock(&gLock);
}
