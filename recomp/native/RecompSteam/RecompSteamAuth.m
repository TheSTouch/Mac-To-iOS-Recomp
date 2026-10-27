// See RecompSteamAuth.h. ARC.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <TargetConditionals.h>
#include "RecompSteamAuth.h"
#include "RecompSteamInternal.h"

#define RLOG(...) RecompSteam_Log(__VA_ARGS__)

static const int kPlatformSteamClient = 1;   // EAuthTokenPlatformType

bool RecompSteamAuth_IsClientToken(const char *refresh_token)
{
    return refresh_token && rs_token_has_audience(refresh_token, "client");
}

uint64_t RecompSteamAuth_TokenSteamID(const char *refresh_token) { return rs_token_steamid(refresh_token); }

// --- stored token --------------------------------------------------------------------

static NSData *KeychainRead(NSString *service, NSString *account)
{
    NSDictionary *q = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                        (__bridge id)kSecAttrService: service, (__bridge id)kSecAttrAccount: account,
                        (__bridge id)kSecReturnData: @YES, (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne};
    CFTypeRef out = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &out) != errSecSuccess || !out) return nil;
    return CFBridgingRelease(out);
}

#if !TARGET_OS_IPHONE
// macOS: the item is made and read by /usr/bin/security, which the item's access list then
// trusts. recomp-steam-cli and the clones are signed ad hoc and change at every build, so an
// item they made themselves would ask for the login password each time a new build read it.
static NSString *const kMacService = @"Recomp Steam", *const kMacAccount = @"steam-client-token";

static NSString *Security(NSArray<NSString *> *args, int *status)
{
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/security"];
    task.arguments = args;
    NSPipe *out = [NSPipe pipe];
    task.standardOutput = out;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:nil]) return nil;
    NSData *d = [out.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (status) *status = task.terminationStatus;
    return [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
#endif

char *RecompSteamAuth_StoredToken(uint32_t app_id)
{
    NSString *token = nil;
#if TARGET_OS_IPHONE
    NSData *d = KeychainRead(@"Recomp Steam license", [NSString stringWithFormat:@"%u", app_id]);
    id state = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if ([state isKindOfClass:NSDictionary.class] && [state[@"refresh"] isKindOfClass:NSString.class])
        token = state[@"refresh"];
#else
    (void)app_id;
    const char *env = getenv("RECOMP_STEAM_TOKEN");
    if (env && *env) token = @(env);
    if (!token) {
        int status = 1;
        NSString *t = Security(@[@"find-generic-password", @"-s", kMacService, @"-a", kMacAccount, @"-w"], &status);
        if (status == 0) token = t;
    }
#endif
    if (!token.length || !RecompSteamAuth_IsClientToken(token.UTF8String)) return NULL;
    return strdup(token.UTF8String);
}

bool RecompSteamAuth_StoreToken(const char *refresh_token)
{
#if TARGET_OS_IPHONE
    (void)refresh_token;
    return false;   // RecompLicense.m keeps the sign-in on iOS
#else
    int status = 1;
    Security(@[@"add-generic-password", @"-U", @"-s", kMacService, @"-a", kMacAccount, @"-l", @"Recomp Steam sign-in",
               @"-T", @"/usr/bin/security", @"-w", @(refresh_token)], &status);
    return status == 0;
#endif
}

// --- flows ------------------------------------------------------------------------------

@interface RSAuthFlow : NSObject
@property (nonatomic) int ident;
@property (nonatomic) uint64_t clientID, steamID;
@property (nonatomic, strong) NSData *requestID;
@property (nonatomic) double interval, deadline;
@property (nonatomic, copy) NSString *deviceName;
@property (nonatomic, copy) void (^challenge)(const char *url);
@property (nonatomic, copy) void (^scanned)(void);
@property (nonatomic, copy) RecompSteamSignedIn done;
@property (nonatomic) BOOL qr, sawScan;
@end
@implementation RSAuthFlow
@end

static NSMutableDictionary<NSNumber *, RSAuthFlow *> *gFlows;
static int gNextFlow = 1;

static void DeviceDetails(rs_pb_writer *w, uint32_t field, const char *name)
{
    rs_pb_writer d = {0};
    rs_pb_string(&d, 1, name);
    rs_pb_varint(&d, 2, kPlatformSteamClient);
#if TARGET_OS_IPHONE
    rs_pb_varint(&d, 3, (uint64_t)(int64_t)-600);   // EOSType iOS
#else
    rs_pb_varint(&d, 3, (uint64_t)(int64_t)-102);   // EOSType macOS
#endif
    rs_pb_varint(&d, 4, 1);                          // EGamingDeviceType: a computer
    rs_pb_message(w, field, &d);
    rs_pb_free(&d);
}

static void Finish(RSAuthFlow *f, int32_t er, const char *refresh, const char *access, const char *account)
{
    if (gFlows[@(f.ident)] != f) return;
    [gFlows removeObjectForKey:@(f.ident)];
    f.done(er, refresh, access, account);
}

static void BeginQR(RSAuthFlow *f);

static void Poll(RSAuthFlow *f)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(f.interval * NSEC_PER_SEC)), RecompSteam_Queue(), ^{
        if (gFlows[@(f.ident)] != f) return;
        if (CFAbsoluteTimeGetCurrent() > f.deadline) {
            Finish(f, RecompSteamResultTimeout, NULL, NULL, NULL);
            return;
        }
        rs_pb_writer w = {0};
        rs_pb_varint(&w, 1, f.clientID);
        rs_pb_bytes(&w, 2, f.requestID.bytes, f.requestID.length);
        RecompSteam_CallUnauthed("Authentication.PollAuthSessionStatus#1", w.data, w.length, 20,
                                 ^(const RecompSteamMessage *m) {
            if (gFlows[@(f.ident)] != f) return;
            if (m->eresult == RecompSteamResultTimeout && !m->emsg) {
                Poll(f);   // a network hiccup: keep waiting
                return;
            }
            if (m->eresult == 9 /* FileNotFound */ || m->eresult == RecompSteamResultExpired) {
                if (f.qr) BeginQR(f);   // the code timed out: a new one
                else Finish(f, m->eresult, NULL, NULL, NULL);
                return;
            }
            if (m->eresult != RecompSteamResultOK) {
                Finish(f, m->eresult, NULL, NULL, NULL);
                return;
            }
            char refresh[2048], access[2048], account[128], url[512];
            rs_pb_get_string(m->body, m->length, 3, refresh, sizeof refresh);
            rs_pb_get_string(m->body, m->length, 4, access, sizeof access);
            rs_pb_get_string(m->body, m->length, 6, account, sizeof account);
            uint64_t newClient = rs_pb_get_varint(m->body, m->length, 1, 0);
            if (newClient) f.clientID = newClient;
            if (rs_pb_get_string(m->body, m->length, 2, url, sizeof url) && f.challenge) f.challenge(url);
            if (*refresh) {
                Finish(f, RecompSteamResultOK, refresh, access, account);
                return;
            }
            if (rs_pb_get_varint(m->body, m->length, 5, 0) && !f.sawScan) {
                f.sawScan = YES;
                if (f.scanned) f.scanned();
            }
            Poll(f);
        });
        rs_pb_free(&w);
    });
}

static void BeginQR(RSAuthFlow *f)
{
    rs_pb_writer w = {0};
    rs_pb_string(&w, 1, f.deviceName.UTF8String);
    rs_pb_varint(&w, 2, kPlatformSteamClient);
    DeviceDetails(&w, 3, f.deviceName.UTF8String);
    RecompSteam_CallUnauthed("Authentication.BeginAuthSessionViaQR#1", w.data, w.length, 20,
                             ^(const RecompSteamMessage *m) {
        if (gFlows[@(f.ident)] != f) return;
        rs_pb_field rid, interval;
        char url[512];
        if (m->eresult != RecompSteamResultOK || !rs_pb_get(m->body, m->length, 3, &rid) ||
            !rs_pb_get_string(m->body, m->length, 2, url, sizeof url)) {
            RLOG("QR sign-in refused (EResult %d)", m->eresult);
            Finish(f, m->eresult == RecompSteamResultOK ? RecompSteamResultFail : m->eresult, NULL, NULL, NULL);
            return;
        }
        f.clientID = rs_pb_get_varint(m->body, m->length, 1, 0);
        f.requestID = [NSData dataWithBytes:rid.data length:rid.length];
        f.interval = rs_pb_get(m->body, m->length, 4, &interval) ? MAX(1, rs_pb_float_of(&interval)) : 5;
        f.sawScan = NO;
        if (f.challenge) f.challenge(url);
        Poll(f);
    });
    rs_pb_free(&w);
}

int RecompSteamAuth_BeginQR(const char *device_name, double timeout, void (^challenge)(const char *url),
                            void (^scanned)(void), RecompSteamSignedIn done)
{
    RSAuthFlow *f = [[RSAuthFlow alloc] init];
    f.ident = __atomic_fetch_add(&gNextFlow, 1, __ATOMIC_RELAXED);
    f.deviceName = @(device_name ?: "Recomp");
    f.challenge = challenge;
    f.scanned = scanned;
    f.done = done;
    f.qr = YES;
    f.deadline = CFAbsoluteTimeGetCurrent() + (timeout > 0 ? timeout : 600);
    dispatch_async(RecompSteam_Queue(), ^{
        if (!gFlows) gFlows = [NSMutableDictionary dictionary];
        gFlows[@(f.ident)] = f;
        BeginQR(f);
    });
    return f.ident;
}

// --- account name and password -------------------------------------------------------------

static NSData *HexData(NSString *hex)
{
    NSMutableData *d = [NSMutableData data];
    if (hex.length % 2) hex = [@"0" stringByAppendingString:hex];
    for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
        unsigned v = 0;
        [[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(i, 2)]] scanHexInt:&v];
        uint8_t byte = (uint8_t)v;
        [d appendBytes:&byte length:1];
    }
    return d;
}

static void DerLength(NSMutableData *d, NSUInteger n)
{
    uint8_t b[3];
    if (n < 0x80) { b[0] = (uint8_t)n; [d appendBytes:b length:1]; }
    else if (n < 0x100) { b[0] = 0x81; b[1] = (uint8_t)n; [d appendBytes:b length:2]; }
    else { b[0] = 0x82; b[1] = (uint8_t)(n >> 8); b[2] = (uint8_t)n; [d appendBytes:b length:3]; }
}

static void DerInteger(NSMutableData *d, NSData *bytes)
{
    const uint8_t *p = bytes.bytes;
    NSUInteger n = bytes.length;
    while (n > 1 && !p[0]) { p++; n--; }
    BOOL pad = n && (p[0] & 0x80);
    uint8_t tag = 0x02, zero = 0;
    [d appendBytes:&tag length:1];
    DerLength(d, n + pad);
    if (pad) [d appendBytes:&zero length:1];
    [d appendBytes:p length:n];
}

// RSA PKCS#1 v1.5 with the key Steam hands out for the account, base64.
static NSString *EncryptPassword(NSString *password, NSString *modHex, NSString *expHex)
{
    NSMutableData *ints = [NSMutableData data];
    DerInteger(ints, HexData(modHex));
    DerInteger(ints, HexData(expHex));
    NSMutableData *der = [NSMutableData data];
    uint8_t seq = 0x30;
    [der appendBytes:&seq length:1];
    DerLength(der, ints.length);
    [der appendData:ints];
    NSDictionary *attrs = @{(__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
                            (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic};
    SecKeyRef key = SecKeyCreateWithData((__bridge CFDataRef)der, (__bridge CFDictionaryRef)attrs, NULL);
    if (!key) return nil;
    CFDataRef enc = SecKeyCreateEncryptedData(key, kSecKeyAlgorithmRSAEncryptionPKCS1,
                                              (__bridge CFDataRef)[password dataUsingEncoding:NSUTF8StringEncoding], NULL);
    CFRelease(key);
    if (!enc) return nil;
    return [(NSData *)CFBridgingRelease(enc) base64EncodedStringWithOptions:0];
}

int RecompSteamAuth_BeginPassword(const char *device_name, const char *account, const char *password,
                                  void (^guard)(const int *types, int count, const char *email_domain),
                                  RecompSteamSignedIn done)
{
    RSAuthFlow *f = [[RSAuthFlow alloc] init];
    f.ident = __atomic_fetch_add(&gNextFlow, 1, __ATOMIC_RELAXED);
    f.deviceName = @(device_name ?: "Recomp");
    f.done = done;
    f.deadline = CFAbsoluteTimeGetCurrent() + 600;
    NSString *acct = @(account ?: ""), *pass = @(password ?: "");
    void (^g)(const int *, int, const char *) = [guard copy];
    dispatch_async(RecompSteam_Queue(), ^{
        if (!gFlows) gFlows = [NSMutableDictionary dictionary];
        gFlows[@(f.ident)] = f;
        rs_pb_writer w = {0};
        rs_pb_string(&w, 1, acct.UTF8String);
        RecompSteam_CallUnauthed("Authentication.GetPasswordRSAPublicKey#1", w.data, w.length, 20,
                                 ^(const RecompSteamMessage *m) {
            if (gFlows[@(f.ident)] != f) return;
            char mod[1100], exp[64];
            rs_pb_get_string(m->body, m->length, 1, mod, sizeof mod);
            rs_pb_get_string(m->body, m->length, 2, exp, sizeof exp);
            uint64_t stamp = rs_pb_get_varint(m->body, m->length, 3, 0);
            NSString *enc = *mod && *exp ? EncryptPassword(pass, @(mod), @(exp)) : nil;
            if (m->eresult != RecompSteamResultOK || !enc) {
                Finish(f, m->eresult == RecompSteamResultOK ? RecompSteamResultFail : m->eresult, NULL, NULL, NULL);
                return;
            }
            rs_pb_writer c = {0};
            rs_pb_string(&c, 1, f.deviceName.UTF8String);
            rs_pb_string(&c, 2, acct.UTF8String);
            rs_pb_string(&c, 3, enc.UTF8String);
            rs_pb_varint(&c, 4, stamp);
            rs_pb_bool(&c, 5, true);
            rs_pb_varint(&c, 6, kPlatformSteamClient);
            rs_pb_varint(&c, 7, 1);           // persistent
            rs_pb_string(&c, 8, "Client");
            DeviceDetails(&c, 9, f.deviceName.UTF8String);
            RecompSteam_CallUnauthed("Authentication.BeginAuthSessionViaCredentials#1", c.data, c.length, 20,
                                     ^(const RecompSteamMessage *r) {
                if (gFlows[@(f.ident)] != f) return;
                rs_pb_field rid, interval;
                if (r->eresult != RecompSteamResultOK || !rs_pb_get(r->body, r->length, 2, &rid)) {
                    Finish(f, r->eresult == RecompSteamResultOK ? RecompSteamResultFail : r->eresult, NULL, NULL, NULL);
                    return;
                }
                f.clientID = rs_pb_get_varint(r->body, r->length, 1, 0);
                f.steamID = rs_pb_get_varint(r->body, r->length, 5, 0);
                f.requestID = [NSData dataWithBytes:rid.data length:rid.length];
                f.interval = rs_pb_get(r->body, r->length, 3, &interval) ? MAX(1, rs_pb_float_of(&interval)) : 5;
                int types[8], n = 0;
                char domain[128] = "";
                rs_pb_reader rr = rs_pb_read(r->body, r->length);
                rs_pb_field fl;
                while (rs_pb_next(&rr, &fl) && n < 8)
                    if (fl.number == 4 && fl.wire == RS_PB_BYTES) {
                        types[n] = (int)rs_pb_get_varint(fl.data, fl.length, 1, 0);
                        if (types[n] == RecompSteamGuardEmailCode)
                            rs_pb_get_string(fl.data, fl.length, 2, domain, sizeof domain);
                        n++;
                    }
                if (g) g(types, n, domain);
                Poll(f);
            });
            rs_pb_free(&c);
        });
        rs_pb_free(&w);
    });
    return f.ident;
}

void RecompSteamAuth_SubmitCode(int flow, const char *code, int code_type, void (^done)(int32_t eresult))
{
    NSString *c = @(code ?: "");
    void (^d)(int32_t) = [done copy];
    dispatch_async(RecompSteam_Queue(), ^{
        RSAuthFlow *f = gFlows[@(flow)];
        if (!f) return;
        rs_pb_writer w = {0};
        rs_pb_varint(&w, 1, f.clientID);
        rs_pb_fixed64(&w, 2, f.steamID);
        rs_pb_string(&w, 3, c.UTF8String);
        rs_pb_varint(&w, 4, code_type);
        RecompSteam_CallUnauthed("Authentication.UpdateAuthSessionWithSteamGuardCode#1", w.data, w.length, 20,
                                 ^(const RecompSteamMessage *m) {
            if (gFlows[@(flow)] == f && d) d(m->eresult);
        });
        rs_pb_free(&w);
    });
}

void RecompSteamAuth_Cancel(int flow)
{
    dispatch_async(RecompSteam_Queue(), ^{ [gFlows removeObjectForKey:@(flow)]; });
}
