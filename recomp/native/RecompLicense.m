// The Steam license check: a port of a Steam game plays only for someone who owns
// it on Steam. Shared by both routes: the Unreal shim compiles it in
// (unreal_ios.py), Unity ports get it in Assets/Plugins/iOS with the other
// top-level files of recomp/native. The Mac side is recomp/steam_license.py.
//
// Info.plist "RecompSteamAppId" is the game's Steam app id and "RecompGame" its
// name. Without an app id this file does nothing.
//
// The first launch covers the game with a sign-in screen. The player signs in to
// Steam with a QR code scanned in the Steam Mobile app, or with account name,
// password and Steam Guard. Everything goes straight to api.steampowered.com:
//   - IAuthenticationService (the service Steam's own apps sign in with) gives a
//     refresh token for this device; the password is RSA-encrypted with the key
//     Steam hands out for it;
//   - IPlayerService/GetOwnedGames, called with the account's own access token,
//     says whether the account owns the app.
// An account that owns the game lifts the cover. The refresh token, the Steam ID
// and the time of the last check are kept in the Keychain, on this device only
// (they do not travel in backups or with a copy of the app). Each launch checks
// again behind a "Checking your Steam license" screen, which lifts after kLaunchWait
// at most while the last successful check is under kGrace old (the check goes on in
// the background); past that, the game stays covered until it can check again. A refunded
// game or a sign-in revoked in Steam brings the cover back.
//
// Documents/Recomp Steam license.txt says which account was checked and when;
// deleting it signs out (the next launch asks to sign in again). Steam lists the
// sign-in as "Recomp: <game> on <device>" under Authorized devices.
//
// This is a check made in good faith, not DRM: the source is public.
//
// Builds with and without ARC: Unity's plugin settings differ from the shim's.
#import <UIKit/UIKit.h>
#import <CoreImage/CoreImage.h>
#import <Security/Security.h>

#if __has_feature(objc_arc)
#define RL_AUTORELEASE(x) (x)
#define RL_RETAIN(x) (x)
#else
#define RL_AUTORELEASE(x) [(x) autorelease]
#define RL_RETAIN(x) [(x) retain]
#endif

#define LLOG(fmt, ...) NSLog(@"[recomp] license: " fmt, ##__VA_ARGS__)

static const NSTimeInterval kGrace = 30 * 86400;
static const NSTimeInterval kLaunchWait = 6;   // within the grace period, the check holds the game this long at most
static NSString *const kAPI = @"https://api.steampowered.com/";
static NSString *const kService = @"Recomp Steam license";

// EResult values Steam answers with (x-eresult header).
enum {
    kOK = 1, kInvalidPassword = 5, kInvalidParam = 8, kFileNotFound = 9, kAccessDenied = 15, kRevoked = 26,
    kExpired = 27, kDuplicateRequest = 29, kInvalidLoginAuthCode = 65, kRateLimitExceeded = 84,
    kTwoFactorCodeMismatch = 88,
};
// EAuthSessionGuardType
enum { kGuardNone = 1, kGuardEmailCode = 2, kGuardDeviceCode = 3, kGuardDeviceConfirmation = 4, kGuardEmailConfirmation = 5 };
static const int kPlatformMobileApp = 3;

static uint32_t gAppId;
static NSString *gGame, *gContainer;

// --- Steam Web API ------------------------------------------------------------------

typedef void (^SteamReply)(NSInteger http, NSInteger eresult, NSDictionary *response, NSError *error);

static NSString *Escape(id value) {
    static NSCharacterSet *allowed;
    if (!allowed) allowed = RL_RETAIN([NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"]);
    return [[value description] stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

// reply runs on the main queue; http is 0 and error set when Steam was not reached.
static void Steam(NSString *method, NSDictionary *params, BOOL post, SteamReply reply) {
    NSMutableArray *pairs = [NSMutableArray array];
    for (NSString *k in params) [pairs addObject:[NSString stringWithFormat:@"%@=%@", Escape(k), Escape(params[k])]];
    NSString *query = [pairs componentsJoinedByString:@"&"];
    NSString *url = [kAPI stringByAppendingString:method];
    if (!post) url = [url stringByAppendingFormat:@"?%@", query];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:20];
    if (post) {
        req.HTTPMethod = @"POST";
        [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
        req.HTTPBody = [query dataUsingEncoding:NSUTF8StringEncoding];
    }
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp,
                                                                              NSError *error) {
        NSHTTPURLResponse *h = [resp isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)resp : nil;
        NSInteger eresult = [[h valueForHTTPHeaderField:@"x-eresult"] integerValue];
        NSDictionary *response = nil;
        if (data.length) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:NSDictionary.class] && [json[@"response"] isKindOfClass:NSDictionary.class])
                response = json[@"response"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ reply(h.statusCode, eresult, response, error); });
    }] resume];
}

static NSString *Str(id v) { return [v isKindOfClass:NSString.class] && [v length] ? v : nil; }

static NSString *Why(NSInteger http, NSInteger eresult, NSError *error) {
    if (error) return error.localizedDescription;
    if (http != 200) return [NSString stringWithFormat:@"Steam answered HTTP %ld", (long)http];
    return [NSString stringWithFormat:@"Steam answered error %ld", (long)eresult];
}

// The Steam ID a token was issued to: the "sub" claim of the JWT.
static NSString *TokenSteamID(NSString *jwt) {
    NSArray *parts = [jwt componentsSeparatedByString:@"."];
    if (parts.count < 2) return nil;
    NSMutableString *b64 = [NSMutableString stringWithString:parts[1]];
    [b64 replaceOccurrencesOfString:@"-" withString:@"+" options:0 range:NSMakeRange(0, b64.length)];
    [b64 replaceOccurrencesOfString:@"_" withString:@"/" options:0 range:NSMakeRange(0, b64.length)];
    while (b64.length % 4) [b64 appendString:@"="];
    NSData *d = RL_AUTORELEASE([[NSData alloc] initWithBase64EncodedString:b64 options:0]);
    id claims = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    return [claims isKindOfClass:NSDictionary.class] ? Str(claims[@"sub"]) : nil;
}

// --- password encryption: RSA PKCS#1 v1.5 with the key Steam gives for the account ---

static NSData *HexData(NSString *hex) {
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

static void DerLength(NSMutableData *d, NSUInteger n) {
    uint8_t b[3];
    if (n < 0x80) { b[0] = (uint8_t)n; [d appendBytes:b length:1]; }
    else if (n < 0x100) { b[0] = 0x81; b[1] = (uint8_t)n; [d appendBytes:b length:2]; }
    else { b[0] = 0x82; b[1] = (uint8_t)(n >> 8); b[2] = (uint8_t)n; [d appendBytes:b length:3]; }
}

static void DerInteger(NSMutableData *d, NSData *bytes) {
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

static NSString *EncryptPassword(NSString *password, NSString *modHex, NSString *expHex) {
    NSData *mod = HexData(modHex);
    NSMutableData *ints = [NSMutableData data];
    DerInteger(ints, mod);
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
    NSData *out = CFBridgingRelease(enc);
    return [out base64EncodedStringWithOptions:0];
}

// --- what is remembered: Keychain (this device only) and the status file -------------

static NSMutableDictionary *KeychainQuery(void) {
    return [NSMutableDictionary dictionaryWithDictionary:@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kService,
        (__bridge id)kSecAttrAccount: [NSString stringWithFormat:@"%u", gAppId]}];
}

// {refresh, steamid, account, verified (seconds since 1970)}, or nil.
static NSDictionary *LoadState(void) {
    NSMutableDictionary *q = KeychainQuery();
    q[(__bridge id)kSecReturnData] = @YES;
    q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef out = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &out) != errSecSuccess || !out) return nil;
    NSData *data = CFBridgingRelease(out);
    id state = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![state isKindOfClass:NSDictionary.class] || !Str(state[@"refresh"]) || !Str(state[@"steamid"])) return nil;
    return state;
}

static void Forget(void) { SecItemDelete((__bridge CFDictionaryRef)KeychainQuery()); }

// How Steam lists the sign-in under Authorized devices.
static NSString *DeviceName(void) {
    return [NSString stringWithFormat:@"Recomp: %@ on %@", gGame, UIDevice.currentDevice.name];
}

static NSString *StatusPath(void) {
    return [gContainer stringByAppendingPathComponent:@"Documents/Recomp Steam license.txt"];
}

static void SaveState(NSDictionary *state) {
    Forget();
    NSMutableDictionary *q = KeychainQuery();
    q[(__bridge id)kSecValueData] = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
    q[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    OSStatus st = SecItemAdd((__bridge CFDictionaryRef)q, NULL);
    if (st != errSecSuccess) LLOG(@"cannot keep the sign-in in the Keychain (%d)", (int)st);

    NSDateFormatter *f = RL_AUTORELEASE([[NSDateFormatter alloc] init]);
    f.dateStyle = NSDateFormatterLongStyle;
    f.timeStyle = NSDateFormatterShortStyle;
    NSDate *when = [NSDate dateWithTimeIntervalSince1970:[state[@"verified"] doubleValue]];
    NSString *text = [NSString stringWithFormat:
        @"%@ checks that the Steam account it is played with owns the game (Steam app %u).\n\n"
        @"Signed in as: %@\nLast checked: %@\n\n"
        @"The game checks again at each launch and plays offline for %d days after the last check.\n"
        @"Delete this file to sign out: the next launch asks to sign in again. Steam lists this sign-in as\n"
        @"\"%@\" under Settings > Security > Authorized devices, where it can be removed too.\n",
        gGame, gAppId, state[@"account"] ?: @"?", [f stringFromDate:when], (int)(kGrace / 86400), DeviceName()];
    NSString *path = StatusPath();
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// CoreImage classes are looked up by name: UIKit loads CoreImage, and Unity's Xcode project
// does not link it (nor link frameworks automatically).
static UIImage *QRImage(NSString *text) {
    static CIContext *context;
    if (!context) context = RL_RETAIN([NSClassFromString(@"CIContext") contextWithOptions:nil]);
    CIFilter *f = [NSClassFromString(@"CIFilter") filterWithName:@"CIQRCodeGenerator"];
    [f setValue:[text dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    [f setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *img = [f.outputImage imageByApplyingTransform:CGAffineTransformMakeScale(8, 8)];
    if (!img) return nil;
    CGImageRef cg = [context createCGImage:img fromRect:img.extent];
    UIImage *out = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return out;
}

static UIWindow *GameWindow(void) {
    NSMutableArray *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:UIWindowScene.class]) [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!windows.count) [windows addObjectsFromArray:UIApplication.sharedApplication.windows];
#pragma clang diagnostic pop
    UIWindow *best = nil;
    for (UIWindow *w in windows)
        if (w.rootViewController && w.windowLevel <= UIWindowLevelNormal && (!best || w.isKeyWindow)) best = w;
    return best;
}

// --- the cover ------------------------------------------------------------------------

typedef NS_ENUM(NSInteger, RLMode) { RLChecking, RLQR, RLPassword, RLGuard, RLNotOwned, RLOffline };

@interface RecompLicenseController : UIViewController
@property (nonatomic, strong) UIScrollView *scroll;
@end

@implementation RecompLicenseController
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    UIViewController *game = GameWindow().rootViewController;
    return game ? game.supportedInterfaceOrientations : UIInterfaceOrientationMaskLandscape;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboard:)
                                               name:UIKeyboardWillChangeFrameNotification object:nil];
}
- (void)keyboard:(NSNotification *)n {
    CGRect end = [self.view convertRect:[n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue] fromView:nil];
    CGFloat overlap = MAX(0, CGRectGetMaxY(self.scroll.frame) - CGRectGetMinY(end));
    UIEdgeInsets inset = self.scroll.contentInset;
    inset.bottom = overlap;
    self.scroll.contentInset = inset;
    self.scroll.verticalScrollIndicatorInsets = inset;
}
@end

@interface RecompLicenseGate : NSObject <UITextFieldDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) RecompLicenseController *controller;
@property (nonatomic, strong) UILabel *titleLabel, *bodyLabel, *qrHint, *guardLabel, *statusLabel;
@property (nonatomic, strong) UIView *qrBox;
@property (nonatomic, strong) UIImageView *qrView;
@property (nonatomic, strong) UITextField *accountField, *passwordField, *codeField;
@property (nonatomic, strong) UIButton *signInButton, *codeButton, *switchButton, *retryButton, *otherButton, *storeButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSString *clientId, *requestId, *steamId;
@property (nonatomic, strong) NSDictionary *pending;   // tokens signed in with, until the license is checked
@property (nonatomic) RLMode mode;
@property (nonatomic) NSInteger gen;                   // bumped by every new flow: stale replies are dropped
@property (nonatomic) NSTimeInterval interval;
@property (nonatomic) int codeType;
@property (nonatomic) BOOL launchCheck;                // the launch check within the grace period is on screen
@end

static RecompLicenseGate *gGate;

@implementation RecompLicenseGate

// --- launch ---

- (void)start {
    NSDictionary *state = LoadState();
    if (state && ![NSFileManager.defaultManager fileExistsAtPath:StatusPath()]) {
        LLOG(@"signed out from Files");
        Forget();
        state = nil;
    }
    if (!state) {
        [self cover];
        [self beginQR:nil];
        return;
    }
    NSTimeInterval age = NSDate.date.timeIntervalSince1970 - [state[@"verified"] doubleValue];
    BOOL fresh = age > -86400 && age < kGrace;  // a clock set back by more than a day does not count
    LLOG(@"app %u, %@, last checked %.1f days ago", gAppId, state[@"account"], age / 86400);
    [self cover];
    [self show:RLChecking status:nil];
    if ([state[@"account"] length])
        self.bodyLabel.text = [NSString stringWithFormat:@"Signed in to Steam as %@.", state[@"account"]];
    if (fresh) {
        // The game loads behind the cover; a slow answer from Steam does not hold it longer
        // than kLaunchWait, and the check goes on in the background.
        self.launchCheck = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLaunchWait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.launchCheck) [self uncover];
        });
    }
    [self verify:state quiet:fresh];
}

// A stored sign-in: a new access token from the refresh token, then ownership. quiet: within
// the grace period, so only a definite "no" keeps the game covered.
- (void)verify:(NSDictionary *)state quiet:(BOOL)quiet {
    NSInteger gen = ++self.gen;
    Steam(@"IAuthenticationService/GenerateAccessTokenForApp/v1/",
          @{@"refresh_token": state[@"refresh"], @"steamid": state[@"steamid"]}, YES,
          ^(NSInteger http, NSInteger er, NSDictionary *resp, NSError *error) {
        if (gen != self.gen) return;
        NSString *token = Str(resp[@"access_token"]);
        if (er == kOK && token) {
            NSDictionary *tokens = @{@"refresh": state[@"refresh"], @"access": token, @"steamid": state[@"steamid"],
                                     @"account": state[@"account"] ?: @""};
            [self checkLicense:tokens quiet:quiet];
            return;
        }
        if (!error && http == 200 && (er == kAccessDenied || er == kRevoked || er == kExpired || er == kInvalidParam)) {
            LLOG(@"the stored sign-in was refused (error %ld)", (long)er);
            Forget();
            [self cover];
            [self beginQR:@"Your Steam sign-in on this device has ended. Sign in again."];
            return;
        }
        [self unreachable:Why(http, er, error) quiet:quiet];
    });
}

- (void)unreachable:(NSString *)why quiet:(BOOL)quiet {
    LLOG(@"cannot check the license: %@", why);
    if (quiet) {
        [self uncover];
        return;
    }
    [self cover];
    NSDictionary *state = LoadState();
    NSString *status = [NSString stringWithFormat:@"Connect to the internet so %@ can check your Steam license (%@).",
                        gGame, why];
    if (state) {
        double days = (NSDate.date.timeIntervalSince1970 - [state[@"verified"] doubleValue]) / 86400;
        status = [status stringByAppendingFormat:@" The last check was %.0f days ago; the game plays offline for "
                  @"%d days after a check.", MAX(days, 0), (int)(kGrace / 86400)];
    }
    [self show:RLOffline status:status];
}

// tokens: {refresh, access, steamid, account}
- (void)checkLicense:(NSDictionary *)tokens quiet:(BOOL)quiet {
    NSInteger gen = ++self.gen;
    Steam(@"IPlayerService/GetOwnedGames/v1/",
          @{@"access_token": tokens[@"access"], @"steamid": tokens[@"steamid"], @"include_played_free_games": @1,
            @"include_free_sub": @1, @"skip_unvetted_apps": @0, @"appids_filter[0]": @(gAppId)}, NO,
          ^(NSInteger http, NSInteger er, NSDictionary *resp, NSError *error) {
        if (gen != self.gen) return;
        if (error || http != 200 || !resp || (er && er != kOK)) {
            self.pending = quiet ? nil : tokens;
            [self unreachable:Why(http, er, error) quiet:quiet];
            return;
        }
        BOOL owned = NO;
        id games = resp[@"games"];
        if ([games isKindOfClass:NSArray.class])
            for (id g in games)
                if ([g isKindOfClass:NSDictionary.class] && [g[@"appid"] longLongValue] == gAppId) owned = YES;
        self.pending = nil;
        if (!owned) {
            LLOG(@"%@ does not own app %u", tokens[@"account"], gAppId);
            Forget();
            [self cover];
            [self show:RLNotOwned status:nil];
            self.bodyLabel.text = [NSString stringWithFormat:
                @"The Steam account %@ does not own %@. This port plays only with a Steam account that owns the "
                @"game, so its developers are paid for it.", tokens[@"account"], gGame];
            return;
        }
        LLOG(@"%@ owns app %u", tokens[@"account"], gAppId);
        SaveState(@{@"refresh": tokens[@"refresh"], @"steamid": tokens[@"steamid"], @"account": tokens[@"account"],
                    @"verified": @(NSDate.date.timeIntervalSince1970)});
        [self uncover];
    });
}

// --- sign-in: QR code ---

- (void)beginQR:(NSString *)status {
    NSInteger gen = ++self.gen;
    [self show:RLQR status:status];
    self.qrView.image = nil;
    [self.spinner startAnimating];
    Steam(@"IAuthenticationService/BeginAuthSessionViaQR/v1/",
          @{@"device_friendly_name": DeviceName(), @"platform_type": @(kPlatformMobileApp)}, YES,
          ^(NSInteger http, NSInteger er, NSDictionary *resp, NSError *error) {
        if (gen != self.gen) return;
        [self.spinner stopAnimating];
        NSString *url = Str(resp[@"challenge_url"]);
        if (er != kOK || !url || !Str(resp[@"client_id"]) || !Str(resp[@"request_id"])) {
            self.statusLabel.text = [NSString stringWithFormat:@"Cannot reach Steam: %@.", Why(http, er, error)];
            self.statusLabel.hidden = NO;
            self.retryButton.hidden = NO;
            return;
        }
        self.clientId = resp[@"client_id"];
        self.requestId = resp[@"request_id"];
        self.interval = MAX(1, [resp[@"interval"] doubleValue] ?: 5);
        self.qrView.image = QRImage(url);
        [self poll:gen];
    });
}

// Shared by both sign-ins: Steam answers with tokens once the player approved.
- (void)poll:(NSInteger)gen {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.interval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen != self.gen) return;
        Steam(@"IAuthenticationService/PollAuthSessionStatus/v1/",
              @{@"client_id": self.clientId, @"request_id": self.requestId}, YES,
              ^(NSInteger http, NSInteger er, NSDictionary *resp, NSError *error) {
            if (gen != self.gen) return;
            if (er == kOK && resp) {
                if (Str(resp[@"new_challenge_url"])) {
                    if (Str(resp[@"new_client_id"])) self.clientId = resp[@"new_client_id"];
                    self.qrView.image = QRImage(resp[@"new_challenge_url"]);
                }
                NSString *refresh = Str(resp[@"refresh_token"]), *access = Str(resp[@"access_token"]);
                if (refresh && access) {
                    NSString *steamid = TokenSteamID(refresh) ?: self.steamId;
                    [self signedIn:@{@"refresh": refresh, @"access": access, @"steamid": steamid ?: @"",
                                     @"account": Str(resp[@"account_name"]) ?: @""}];
                    return;
                }
                if ([resp[@"had_remote_interaction"] boolValue] && self.mode == RLQR) {
                    self.statusLabel.text = @"Approve the sign-in in the Steam Mobile app.";
                    self.statusLabel.hidden = NO;
                }
                [self poll:gen];
            } else if (!error && http == 200 && (er == kFileNotFound || er == kExpired)) {
                if (self.mode == RLQR) [self beginQR:nil];  // the code timed out: a new one
                else [self show:RLPassword status:@"The sign-in timed out. Sign in again."];
            } else if (error || http != 200) {
                [self poll:gen];  // a network hiccup: keep waiting
            } else {
                [self show:self.mode == RLQR ? RLQR : RLPassword
                    status:[NSString stringWithFormat:@"Steam refused the sign-in (error %ld).", (long)er]];
                self.retryButton.hidden = self.mode != RLQR;
            }
        });
    });
}

- (void)signedIn:(NSDictionary *)tokens {
    if (![tokens[@"steamid"] length]) {
        [self show:RLQR status:@"Steam did not say which account signed in. Try again."];
        return;
    }
    LLOG(@"signed in as %@", tokens[@"account"]);
    [self show:RLChecking status:nil];
    [self checkLicense:tokens quiet:NO];
}

// --- sign-in: account name and password ---

- (void)signInWithPassword {
    NSString *account = [self.accountField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *password = self.passwordField.text;
    if (!account.length || !password.length) {
        self.statusLabel.text = @"Enter your Steam account name and password.";
        self.statusLabel.hidden = NO;
        return;
    }
    [self.window endEditing:YES];
    NSInteger gen = ++self.gen;
    [self busy:YES];
    Steam(@"IAuthenticationService/GetPasswordRSAPublicKey/v1/", @{@"account_name": account}, NO,
          ^(NSInteger http, NSInteger er, NSDictionary *resp, NSError *error) {
        if (gen != self.gen) return;
        NSString *mod = Str(resp[@"publickey_mod"]), *exp = Str(resp[@"publickey_exp"]);
        NSString *encrypted = mod && exp ? EncryptPassword(password, mod, exp) : nil;
        if (er != kOK || !encrypted || !resp[@"timestamp"]) {
            [self busy:NO];
            [self show:RLPassword status:[NSString stringWithFormat:@"Cannot reach Steam: %@.", Why(http, er, error)]];
            return;
        }
        Steam(@"IAuthenticationService/BeginAuthSessionViaCredentials/v1/",
              @{@"account_name": account, @"encrypted_password": encrypted, @"encryption_timestamp": resp[@"timestamp"],
                @"remember_login": @"true", @"persistence": @1, @"platform_type": @(kPlatformMobileApp),
                @"website_id": @"Mobile", @"device_friendly_name": DeviceName()}, YES,
              ^(NSInteger http2, NSInteger er2, NSDictionary *r, NSError *error2) {
            if (gen != self.gen) return;
            [self busy:NO];
            if (er2 != kOK || !Str(r[@"client_id"]) || !Str(r[@"request_id"])) {
                NSString *why = er2 == kInvalidPassword ? @"Wrong account name or password."
                              : er2 == kRateLimitExceeded ? @"Too many sign-in attempts. Wait a while, then try again."
                              : [NSString stringWithFormat:@"Steam refused the sign-in: %@.", Why(http2, er2, error2)];
                [self show:RLPassword status:why];
                return;
            }
            self.passwordField.text = @"";
            self.clientId = r[@"client_id"];
            self.requestId = r[@"request_id"];
            self.steamId = Str(r[@"steamid"]) ?: [r[@"steamid"] description];
            self.interval = MAX(1, [r[@"interval"] doubleValue] ?: 5);
            [self guard:r[@"allowed_confirmations"]];
            [self poll:gen];
        });
    });
}

// What Steam Guard asks for, from the session's allowed confirmations.
- (void)guard:(id)confirmations {
    NSMutableArray *lines = [NSMutableArray array];
    self.codeType = 0;
    NSString *email = nil;
    for (id c in [confirmations isKindOfClass:NSArray.class] ? confirmations : @[]) {
        if (![c isKindOfClass:NSDictionary.class]) continue;
        int type = [c[@"confirmation_type"] intValue];
        if (type == kGuardDeviceConfirmation) [lines addObject:@"Approve the sign-in in the Steam Mobile app"];
        if (type == kGuardEmailConfirmation) [lines addObject:@"Confirm the sign-in from the email Steam sent you"];
        if (type == kGuardDeviceCode) self.codeType = kGuardDeviceCode;
        if (type == kGuardEmailCode && self.codeType != kGuardDeviceCode) {
            self.codeType = kGuardEmailCode;
            email = Str(c[@"associated_message"]);
        }
    }
    if (self.codeType == kGuardDeviceCode) [lines addObject:@"enter the Steam Guard code from the Steam Mobile app"];
    if (self.codeType == kGuardEmailCode)
        [lines addObject:email ? [NSString stringWithFormat:@"enter the code Steam emailed to your %@ address", email]
                               : @"enter the code Steam emailed you"];
    [self show:RLGuard status:nil];
    self.codeField.hidden = self.codeButton.hidden = !self.codeType;
    if (!lines.count) {
        self.guardLabel.text = @"Signing in…";
        return;
    }
    NSString *text = [lines componentsJoinedByString:@", or "];
    self.guardLabel.text = [[[text substringToIndex:1] uppercaseString] stringByAppendingFormat:@"%@.", [text substringFromIndex:1]];
    if (self.codeType) [self.codeField becomeFirstResponder];
}

- (void)submitCode {
    NSString *code = [self.codeField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!code.length || !self.clientId) return;
    NSInteger gen = self.gen;
    self.codeButton.enabled = NO;
    Steam(@"IAuthenticationService/UpdateAuthSessionWithSteamGuardCode/v1/",
          @{@"client_id": self.clientId, @"steamid": self.steamId ?: @"", @"code": code, @"code_type": @(self.codeType)},
          YES, ^(NSInteger http, NSInteger er, NSDictionary *resp, NSError *error) {
        if (gen != self.gen) return;
        self.codeButton.enabled = YES;
        if (er == kOK || er == kDuplicateRequest) {
            self.statusLabel.text = @"Code accepted, signing in…";
        } else if (er == kInvalidLoginAuthCode || er == kTwoFactorCodeMismatch) {
            self.statusLabel.text = @"That code is not right. Check it and try again.";
            self.codeField.text = @"";
        } else {
            self.statusLabel.text = [NSString stringWithFormat:@"The code was not sent: %@.", Why(http, er, error)];
        }
        self.statusLabel.hidden = NO;
    });
}

// --- buttons ---

- (void)tapSwitch {
    if (self.mode == RLQR) {
        ++self.gen;  // stop polling the QR session
        [self show:RLPassword status:nil];
        [self.accountField becomeFirstResponder];
    } else {
        [self beginQR:nil];
    }
}

- (void)tapRetry {
    if (self.pending) {
        [self show:RLChecking status:nil];
        [self checkLicense:self.pending quiet:NO];
        return;
    }
    NSDictionary *state = LoadState();
    if (state && self.mode == RLOffline) {
        [self show:RLChecking status:nil];
        [self verify:state quiet:NO];
    } else {
        [self beginQR:nil];
    }
}

- (void)tapOther {
    Forget();
    self.pending = nil;
    [self beginQR:nil];
}

- (void)tapStore {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://store.steampowered.com/app/%u/", gAppId]];
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    if (field == self.accountField) [self.passwordField becomeFirstResponder];
    else if (field == self.passwordField) [self signInWithPassword];
    else if (field == self.codeField) [self submitCode];
    return NO;
}

// --- views ---

- (void)busy:(BOOL)busy {
    self.signInButton.enabled = !busy;
    if (busy) [self.spinner startAnimating];
    else [self.spinner stopAnimating];
}

- (void)show:(RLMode)mode status:(NSString *)status {
    if (mode != RLChecking) self.launchCheck = NO;
    self.mode = mode;
    [self busy:mode == RLChecking];
    self.titleLabel.text = mode == RLNotOwned ? [NSString stringWithFormat:@"This account does not own %@", gGame]
                         : mode == RLOffline ? @"Steam license not checked"
                         : mode == RLChecking ? @"Checking your Steam license…"
                         : [NSString stringWithFormat:@"Sign in to Steam to play %@", gGame];
    self.bodyLabel.text = [NSString stringWithFormat:
        @"This port of %@ plays only with a Steam account that owns the game, so its developers are paid for it. "
        @"Your sign-in goes straight to Steam and stays on this device.", gGame];
    self.qrBox.hidden = self.qrHint.hidden = mode != RLQR;
    self.accountField.hidden = self.passwordField.hidden = self.signInButton.hidden = mode != RLPassword;
    self.guardLabel.hidden = mode != RLGuard;
    self.codeField.hidden = self.codeButton.hidden = YES;
    self.codeField.text = @"";
    self.switchButton.hidden = mode != RLQR && mode != RLPassword && mode != RLGuard;
    [self.switchButton setTitle:mode == RLQR ? @"Sign in with account name and password instead"
                                             : @"Sign in with a QR code instead" forState:UIControlStateNormal];
    self.retryButton.hidden = mode != RLOffline;
    self.otherButton.hidden = mode != RLNotOwned && mode != RLOffline;
    self.storeButton.hidden = mode != RLNotOwned;
    self.statusLabel.text = status;
    self.statusLabel.hidden = !status.length;
}

static UILabel *Label(CGFloat size, UIFontWeight weight, UIColor *color) {
    UILabel *l = RL_AUTORELEASE([[UILabel alloc] init]);
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.numberOfLines = 0;
    l.textAlignment = NSTextAlignmentCenter;
    return l;
}

- (UIButton *)button:(NSString *)title action:(SEL)action primary:(BOOL)primary {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:17 weight:primary ? UIFontWeightSemibold : UIFontWeightRegular];
    b.titleLabel.numberOfLines = 0;
    b.titleLabel.textAlignment = NSTextAlignmentCenter;
    if (primary) {
        b.backgroundColor = [UIColor colorWithRed:0.10 green:0.62 blue:1.0 alpha:1];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        b.layer.cornerRadius = 10;
    }
    [b.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UITextField *)field:(NSString *)placeholder {
    UITextField *f = RL_AUTORELEASE([[UITextField alloc] init]);
    f.placeholder = placeholder;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.spellCheckingType = UITextSpellCheckingTypeNo;
    f.font = [UIFont systemFontOfSize:17];
    f.delegate = self;
    [f.heightAnchor constraintEqualToConstant:44].active = YES;
    return f;
}

- (void)build {
    self.controller = RL_AUTORELEASE([[RecompLicenseController alloc] init]);
    UIView *root = self.controller.view;
    root.backgroundColor = [UIColor colorWithWhite:0.05 alpha:1];

    UIScrollView *scroll = RL_AUTORELEASE([[UIScrollView alloc] init]);
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [root addSubview:scroll];
    self.controller.scroll = scroll;
    UILayoutGuide *safe = root.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor], [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor]]];

    UIView *card = RL_AUTORELEASE([[UIView alloc] init]);
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor colorWithWhite:0.13 alpha:1];
    card.layer.cornerRadius = 18;
    [scroll addSubview:card];
    UILayoutGuide *content = scroll.contentLayoutGuide, *frame = scroll.frameLayoutGuide;
    NSLayoutConstraint *minHeight = [content.heightAnchor constraintEqualToAnchor:frame.heightAnchor];
    minHeight.priority = 200;
    NSLayoutConstraint *wide = [card.widthAnchor constraintEqualToAnchor:frame.widthAnchor constant:-32];
    wide.priority = 750;
    [NSLayoutConstraint activateConstraints:@[
        [content.widthAnchor constraintEqualToAnchor:frame.widthAnchor],
        [content.heightAnchor constraintGreaterThanOrEqualToAnchor:frame.heightAnchor], minHeight,
        [card.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [card.topAnchor constraintGreaterThanOrEqualToAnchor:content.topAnchor constant:16],
        [card.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-16],
        [card.widthAnchor constraintLessThanOrEqualToConstant:520], wide]];

    UIStackView *stack = RL_AUTORELEASE([[UIStackView alloc] init]);
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:28],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-28],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:28],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-28]]];

    UIColor *secondary = [UIColor colorWithWhite:1 alpha:0.7];
    self.titleLabel = Label(24, UIFontWeightBold, UIColor.whiteColor);
    self.bodyLabel = Label(15, UIFontWeightRegular, secondary);

    self.qrView = RL_AUTORELEASE([[UIImageView alloc] init]);
    self.qrView.contentMode = UIViewContentModeScaleAspectFit;
    self.qrView.layer.magnificationFilter = kCAFilterNearest;
    self.qrView.translatesAutoresizingMaskIntoConstraints = NO;
    self.qrBox = RL_AUTORELEASE([[UIView alloc] init]);
    UIView *white = RL_AUTORELEASE([[UIView alloc] init]);
    white.backgroundColor = UIColor.whiteColor;
    white.layer.cornerRadius = 12;
    white.translatesAutoresizingMaskIntoConstraints = NO;
    [self.qrBox addSubview:white];
    [white addSubview:self.qrView];
    [NSLayoutConstraint activateConstraints:@[
        [white.centerXAnchor constraintEqualToAnchor:self.qrBox.centerXAnchor],
        [white.topAnchor constraintEqualToAnchor:self.qrBox.topAnchor], [white.bottomAnchor constraintEqualToAnchor:self.qrBox.bottomAnchor],
        [self.qrView.widthAnchor constraintEqualToConstant:220], [self.qrView.heightAnchor constraintEqualToConstant:220],
        [self.qrView.centerXAnchor constraintEqualToAnchor:white.centerXAnchor],
        [self.qrView.centerYAnchor constraintEqualToAnchor:white.centerYAnchor],
        [white.widthAnchor constraintEqualToConstant:252], [white.heightAnchor constraintEqualToConstant:252]]];
    self.qrHint = Label(15, UIFontWeightRegular, UIColor.whiteColor);
    self.qrHint.text = @"In the Steam Mobile app, open Steam Guard and scan this code with the QR scanner.";

    self.accountField = [self field:@"Steam account name"];
    self.accountField.textContentType = UITextContentTypeUsername;
    self.accountField.returnKeyType = UIReturnKeyNext;
    self.passwordField = [self field:@"Password"];
    self.passwordField.textContentType = UITextContentTypePassword;
    self.passwordField.secureTextEntry = YES;
    self.passwordField.returnKeyType = UIReturnKeyGo;
    self.signInButton = [self button:@"Sign in" action:@selector(signInWithPassword) primary:YES];

    self.guardLabel = Label(17, UIFontWeightRegular, UIColor.whiteColor);
    self.codeField = [self field:@"Steam Guard code"];
    self.codeField.textContentType = UITextContentTypeOneTimeCode;
    self.codeField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    self.codeField.textAlignment = NSTextAlignmentCenter;
    self.codeField.returnKeyType = UIReturnKeyDone;
    self.codeButton = [self button:@"Send code" action:@selector(submitCode) primary:YES];

    self.spinner = RL_AUTORELEASE([[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge]);
    self.spinner.color = UIColor.whiteColor;
    self.spinner.hidesWhenStopped = YES;
    self.statusLabel = Label(15, UIFontWeightMedium, [UIColor colorWithRed:1 green:0.75 blue:0.35 alpha:1]);

    self.retryButton = [self button:@"Try again" action:@selector(tapRetry) primary:YES];
    self.storeButton = [self button:@"Open the Steam store page" action:@selector(tapStore) primary:YES];
    self.otherButton = [self button:@"Sign in with another Steam account" action:@selector(tapOther) primary:NO];
    self.switchButton = [self button:@"" action:@selector(tapSwitch) primary:NO];

    for (UIView *v in @[self.titleLabel, self.bodyLabel, self.qrBox, self.qrHint, self.accountField, self.passwordField,
                        self.signInButton, self.guardLabel, self.codeField, self.codeButton, self.spinner,
                        self.statusLabel, self.retryButton, self.storeButton, self.otherButton, self.switchButton])
        [stack addArrangedSubview:v];
    [stack setCustomSpacing:22 afterView:self.bodyLabel];
}

- (void)cover {
    if (self.window) return;
    if (!self.controller) [self build];
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:UIWindowScene.class] && (!scene || s.activationState == UISceneActivationStateForegroundActive))
            scene = (UIWindowScene *)s;
    UIWindow *w = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window = RL_AUTORELEASE(w);
    self.window.windowLevel = UIWindowLevelAlert + 10;
    self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.window.rootViewController = self.controller;
    [self.window makeKeyAndVisible];
    LLOG(@"covering the game until the license is checked");
}

- (void)uncover {
    self.launchCheck = NO;
    if (!self.window) return;
    [self.window endEditing:YES];
    self.window.hidden = YES;
    self.window = nil;
    [GameWindow() makeKeyWindow];
    LLOG(@"license checked, playing");
}

@end

__attribute__((constructor)) static void RecompLicenseInit(void) {
    @autoreleasepool {
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        id appid = info[@"RecompSteamAppId"];
        if (![appid respondsToSelector:@selector(unsignedIntValue)] || ![appid unsignedIntValue]) return;
        gAppId = [appid unsignedIntValue];
        NSString *game = Str(info[@"RecompGame"]) ?: Str(info[@"CFBundleDisplayName"]) ?: Str(info[@"CFBundleName"]);
        gGame = RL_RETAIN(game ?: @"this game");
        // recomp_runtime.c may already have moved $HOME to Documents; it pins the container first.
        const char *home = getenv("CFFIXED_USER_HOME");
        gContainer = RL_RETAIN(home ? [NSString stringWithUTF8String:home] : NSHomeDirectory());
        gGate = [[RecompLicenseGate alloc] init];
        // Once active, the scene and the game's window exist and the cover can go over them.
        __block id observer = [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *n) {
            [NSNotificationCenter.defaultCenter removeObserver:observer];
            [gGate start];
        }];
    }
}
