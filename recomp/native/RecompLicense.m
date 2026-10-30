// The Steam license check: a port of a Steam game plays only for someone who owns
// it on Steam. Shared by both routes: the Unreal shim compiles it in
// (unreal_ios.py), Unity ports get it in Assets/Plugins/iOS with the other
// top-level files of recomp/native. The Mac side is recomp/steam_license.py.
//
// Info.plist "RecompSteamAppId" is the game's Steam app id and "RecompGame" its
// name. Without an app id this file does nothing.
//
// The first launch covers the game with a sign-in screen. The player signs in to
// Steam as a Steam client would, with a QR code scanned in the Steam Mobile app or
// with account name, password and Steam Guard (Kettle's RecompSteamAuth.h, over a
// connection to Steam's connection managers). That one sign-in is the port's Steam
// session (Kettle's RecompSteamSession.h), which also carries saves, achievements
// and online play. The license is the session's: logged on, and Steam signs an
// ownership ticket for the app (it does for a game the account owns or borrows
// through Steam Family Sharing, and refuses one otherwise).
//
// An account that owns the game lifts the cover. The refresh token, the Steam ID
// and the time of the last check are kept in the Keychain, on this device only
// (they do not travel in backups or with a copy of the app). Each launch checks
// again behind a "Checking your Steam license" screen, which lifts after kLaunchWait
// at most while the last successful check is under kGrace old (the check goes on in
// the background); past that, the game stays covered until it can check again. A refunded
// game or a sign-in revoked in Steam brings the cover back. A sign-in kept by an older
// port (a Steam Mobile app token, which cannot log on as a client) asks once to sign in
// again, saying why.
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
#include <dlfcn.h>
#include <os/log.h>
#include "RecompSteamAuth.h"
#include "RecompSteamSession.h"

#if __has_feature(objc_arc)
#define RL_AUTORELEASE(x) (x)
#define RL_RETAIN(x) (x)
#else
#define RL_AUTORELEASE(x) [(x) autorelease]
#define RL_RETAIN(x) [(x) retain]
#endif

// os_log, public: NSLog's arguments show as <private> in a device's log.
// Also to the port's log file (RecompLog.m), where there is one.
#define LLOG(fmt, ...) do { \
    const char *line_ = [NSString stringWithFormat:@"[recomp] license: " fmt, ##__VA_ARGS__].UTF8String; \
    os_log(OS_LOG_DEFAULT, "%{public}s", line_); \
    RecompLog_Line(line_); \
} while (0)

static const NSTimeInterval kGrace = 30 * 86400;
static const NSTimeInterval kLaunchWait = 6;   // within the grace period, the check holds the game this long at most
static const double kLogonWait = 25;           // how long a check waits for the session to log on
static NSString *const kService = @"Recomp Steam license";

// EResult values Steam answers with.
enum {
    kOK = 1, kInvalidPassword = 5, kInvalidParam = 8, kFileNotFound = 9, kTimeout = 16, kAccessDenied = 15,
    kRevoked = 26, kExpired = 27, kDuplicateRequest = 29, kInvalidLoginAuthCode = 65, kRateLimitExceeded = 84,
    kTwoFactorCodeMismatch = 88,
};
// EAuthSessionGuardType
enum { kGuardNone = 1, kGuardEmailCode = 2, kGuardDeviceCode = 3, kGuardDeviceConfirmation = 4, kGuardEmailConfirmation = 5 };

static uint32_t gAppId;
static NSString *gGame, *gContainer;

static NSString *Str(id v) { return [v isKindOfClass:NSString.class] && [v length] ? v : nil; }

static NSString *Why(NSInteger eresult) {
    if (eresult == kTimeout) return @"Steam did not answer";
    return [NSString stringWithFormat:@"Steam answered error %ld", (long)eresult];
}

// Runs block on the main queue (the runtime's callbacks come on its own queue).
static void Main(dispatch_block_t block) { dispatch_async(dispatch_get_main_queue(), block); }

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

// Forgetting the sign-in also ends the session that logged on with it.
static void Forget(void) {
    SecItemDelete((__bridge CFDictionaryRef)KeychainQuery());
    RecompSteam_Stop();
}

// How Steam lists the sign-in under Authorized devices.
static NSString *DeviceName(void) {
    return [NSString stringWithFormat:@"Recomp: %@ on %@", gGame, UIDevice.currentDevice.name];
}

static NSString *StatusPath(void) {
    return [gContainer stringByAppendingPathComponent:@"Documents/Recomp Steam license.txt"];
}

// Replaces the stored sign-in; the session goes on (each passed check saves the time of it).
static void SaveState(NSDictionary *state) {
    SecItemDelete((__bridge CFDictionaryRef)KeychainQuery());
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

// The game's window, whatever its root view controller is (Unity's, Unreal's, AIR's
// CTStandaloneViewController): the key window, else one in the foreground scene, at the
// normal level (the cover's own window is above it).
static UIWindow *GameWindow(void) {
    NSMutableArray *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:UIWindowScene.class]) [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!windows.count) [windows addObjectsFromArray:UIApplication.sharedApplication.windows];
#pragma clang diagnostic pop
    UIWindow *best = nil;
    for (UIWindow *w in windows) {
        if (!w.rootViewController || w.windowLevel > UIWindowLevelNormal) continue;
        if (w.isKeyWindow) return w;
        if (!best || w.windowScene.activationState == UISceneActivationStateForegroundActive) best = w;
    }
    return best;
}

// --- the cover ------------------------------------------------------------------------

typedef NS_ENUM(NSInteger, RLMode) { RLChecking, RLQR, RLPassword, RLGuard, RLNotOwned, RLOffline, RLElsewhere };

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
@property (nonatomic, strong) UIButton *hereButton, *awayButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSDictionary *pending;   // tokens signed in with, until the license is checked
@property (nonatomic) RLMode mode;
@property (nonatomic) NSInteger gen;                   // bumped by every new flow: stale replies are dropped
@property (nonatomic) int flow;                        // the sign-in flow in progress (RecompSteamAuth), 0 for none
@property (nonatomic) int codeType;
@property (nonatomic) BOOL launchCheck;                // the launch check within the grace period is on screen
@property (nonatomic, strong) NSDictionary *elsewhereTokens;   // the sign-in "Play here" logs on with
@property (nonatomic) BOOL elsewhereVerified;          // the license was checked within the grace period
@property (nonatomic) BOOL elsewhereDismissed;         // "without Steam" chosen: not asked again until Steam is back
@property (nonatomic) BOOL watching;                   // watchPlaying runs
@property (nonatomic) BOOL wasLoggedOn;                // the session was logged on at watchPlaying's last look
@property (nonatomic, strong) UIWindow *noteWindow;    // the note shown by -note:, while it shows
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
    if (!RecompSteamAuth_IsClientToken([state[@"refresh"] UTF8String])) {
        // Kept by an older port: a Steam Mobile app sign-in, which cannot log on as a client.
        LLOG(@"the stored sign-in is not a Steam client one: asking again");
        [self cover];
        [self beginQR:@"One Steam sign-in now covers saves, achievements and online play. Sign in again once to "
                      @"keep playing."];
        return;
    }
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
    [self checkLicense:state quiet:fresh];
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

// tokens: {refresh, steamid, account}. The session logs on with the token, then Steam
// signs (or refuses) the app's ownership ticket. quiet: within the grace period, so only
// a definite "no" keeps the game covered.
- (void)checkLicense:(NSDictionary *)tokens quiet:(BOOL)quiet {
    NSInteger gen = ++self.gen;
    RecompSteam_Start([tokens[@"refresh"] UTF8String], gAppId, DeviceName().UTF8String);
    [self watchElsewhere:tokens quiet:quiet gen:gen left:kLogonWait + 5];
    RecompSteam_WhenLoggedOn(kLogonWait, ^(bool loggedOn) {
        if (!loggedOn) {
            BOOL refused = RecompSteam_State() == RecompSteamDenied;
            Main(^{
                if (gen != self.gen) return;
                if (refused) {
                    LLOG(@"Steam refused the stored sign-in");
                    Forget();
                    self.pending = nil;
                    [self cover];
                    [self beginQR:@"Your Steam sign-in on this device has ended. Sign in again."];
                } else {
                    self.pending = quiet ? nil : tokens;
                    [self unreachable:@"Steam did not answer" quiet:quiet];
                }
            });
            return;
        }
        RecompSteam_AppOwnershipTicket(gAppId, ^(int32_t er, const uint8_t *ticket, size_t length) {
            uint32_t elsewhere = 0;
            BOOL blocked = RecompSteam_PlayingBlocked(&elsewhere);
            Main(^{
                if (gen != self.gen) return;
                if (er != kOK && blocked && RecompSteam_ConcurrentPlay() != RecompSteamConcurrentPlayAllow) {
                    // Steam logs a session off as soon as it claims the game while the account plays on
                    // another device, often before the ticket comes: the player still chooses.
                    LLOG(@"no ownership ticket (error %d): the account plays on another device", er);
                    self.pending = nil;
                    [self elsewhere:elsewhere tokens:tokens verified:quiet];
                    return;
                }
                if (er == kTimeout) {
                    self.pending = quiet ? nil : tokens;
                    [self unreachable:Why(er) quiet:quiet];
                    return;
                }
                self.pending = nil;
                if (er != kOK) {
                    LLOG(@"%@ does not own app %u (error %d)", tokens[@"account"], gAppId, er);
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
                // With concurrent play allowed (the profile's steam_concurrent_play), the game goes on with Steam.
                if (blocked && RecompSteam_ConcurrentPlay() != RecompSteamConcurrentPlayAllow)
                    [self elsewhere:elsewhere tokens:tokens verified:YES];
                else [self afterCloudSync];
            });
        });
    });
}

// While the player signs in, a Unity game is paused (UnityPause, which the trampoline uses
// for the background): the game would otherwise read its saves under the cover, before the
// sync after the sign-in brings them (Valheim lists its characters as its menu starts). It
// resumes when the cover lifts. Unreal and AIR ports have no such switch and run on under the
// cover; what they ask Steam for waits for the logon (RecompSteam's RequestEncryptedAppTicket,
// which Brawlhalla's login needs).
static void PauseGame(BOOL pause) {
    static BOOL paused;
    typedef void (*UnityPauseFn)(int);
    static UnityPauseFn unityPause;
    static dispatch_once_t once;
    // RecompUnityPause.c, in Unity ports only: UnityFramework does not export UnityPause itself.
    dispatch_once(&once, ^{ unityPause = (UnityPauseFn)dlsym(RTLD_DEFAULT, "RecompUnityPause"); });
    if (!unityPause || paused == pause) return;
    paused = pause;
    LLOG(@"%@ the game under the cover", pause ? @"pausing" : @"resuming");
    unityPause(pause ? 1 : 0);
}

// With Steam Cloud saves (RecompSteam/cloud*.m), the cover stays until the sync that follows
// the sign-in is done, so the game finds the player's saves without a restart. Looked up by
// name: ports without the cloud files lift it at once.
- (void)afterCloudSync {
    typedef void (*WhenSynced)(void (^)(void));
    WhenSynced whenSynced = (WhenSynced)dlsym(RTLD_DEFAULT, "RSCloudWhenSynced");
    if (!whenSynced || !self.window) {
        [self uncover];
        return;
    }
    NSInteger gen = self.gen;
    [self show:RLChecking status:nil];
    self.titleLabel.text = @"Getting your saves from Steam Cloud…";
    __block BOOL done = NO;
    void (^lift)(void) = ^{
        if (done || gen != self.gen) return;
        done = YES;
        [self uncover];
    };
    whenSynced(^{ Main(lift); });
    // The sync gives up on its own; this is only a backstop.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC), dispatch_get_main_queue(), lift);
}

// Steam logs a session off as soon as it claims the game while the account plays on another
// device (Deny claims it at logon), often before the check below has a ticket, or has even begun.
// So while a check runs: Steam said the account plays elsewhere and the session is not logged on,
// and the player chooses at once instead of waiting for the check to give up.
- (void)watchElsewhere:(NSDictionary *)tokens quiet:(BOOL)quiet gen:(NSInteger)gen left:(double)left {
    if (gen != self.gen || left <= 0) return;
    uint32_t app = 0;
    if (RecompSteam_PlayingBlocked(&app) && RecompSteam_State() != RecompSteamLoggedOn &&
        RecompSteam_ConcurrentPlay() != RecompSteamConcurrentPlayAllow) {
        ++self.gen;   // the check's own answer, when it comes, is dropped
        self.pending = nil;
        [self elsewhere:app tokens:tokens verified:quiet];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        [self watchElsewhere:tokens quiet:quiet gen:gen left:left - 0.5];
    });
}

// Steam plays one game per account at a time: the account plays on another device. verified:
// the license was checked within the grace period, so the game may also play without Steam.
- (void)elsewhere:(uint32_t)app tokens:(NSDictionary *)tokens verified:(BOOL)verified {
    LLOG(@"the account is playing app %u on another device", app);
    self.elsewhereTokens = tokens;
    self.elsewhereVerified = verified;
    [self cover];
    [self show:RLElsewhere status:nil];
    self.awayButton.hidden = !verified;
    self.titleLabel.text = @"Your Steam account is playing on another device";
    self.bodyLabel.text = verified ? [NSString stringWithFormat:
        @"Steam plays one game per account at a time. Play here to end the game on the other device; or play "
        @"%@ without Steam for now (no online play, achievements or cloud saves until you choose Play here).", gGame]
        : @"Steam plays one game per account at a time. Play here to end the game on the other device; the "
          @"license check then goes on.";
}

// Calls done once Steam no longer says the account plays elsewhere, or after seconds.
static void WhenUnblocked(double seconds, dispatch_block_t done) {
    if (seconds <= 0 || !RecompSteam_PlayingBlocked(NULL)) {
        done();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        WhenUnblocked(seconds - 0.5, done);
    });
}

- (void)tapHere {
    if (RecompSteam_State() == RecompSteamLoggedOn) {
        RecompSteam_KickPlayingSession();
        [self uncover];
        return;
    }
    // Steam logged the session off, and a kick needs a logon. Under Deny every logon claims the
    // game, which gets it logged off again, so this one logs on with concurrent play allowed (no
    // claim while the account plays elsewhere), ends the other game, then goes back to Deny,
    // which claims the game here, and checks the license again.
    NSDictionary *tokens = self.elsewhereTokens;
    BOOL verified = self.elsewhereVerified;
    NSInteger gen = ++self.gen;
    [self show:RLChecking status:nil];
    self.titleLabel.text = @"Ending the game on the other device…";
    LLOG(@"play here: logging on again to end the game on the other device");
    RecompSteam_SetConcurrentPlay(RecompSteamConcurrentPlayAllow);
    RecompSteam_Stop();
    RecompSteam_Start([tokens[@"refresh"] UTF8String], gAppId, DeviceName().UTF8String);
    RecompSteam_WhenLoggedOn(kLogonWait, ^(bool loggedOn) {
        if (loggedOn) RecompSteam_KickPlayingSession();
        Main(^{
            WhenUnblocked(loggedOn ? 10 : 0, ^{
                LLOG(@"play here: %@", RecompSteam_PlayingBlocked(NULL) ? @"Steam still says the other device plays"
                                                                        : @"the other device stopped");
                RecompSteam_SetConcurrentPlay(RecompSteamConcurrentPlayDeny);
                if (gen != self.gen) return;
                [self checkLicense:tokens quiet:verified];
            });
        });
    });
}

// A short note at the top of the screen over the game, gone after a few seconds; touches go
// through it to the game.
- (void)note:(NSString *)text {
    UIWindowScene *scene = GameWindow().windowScene;
    UIWindow *w = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    w.windowLevel = UIWindowLevelAlert + 5;
    w.userInteractionEnabled = NO;
    w.backgroundColor = UIColor.clearColor;
    UIViewController *vc = RL_AUTORELEASE([[UIViewController alloc] init]);
    vc.view.backgroundColor = UIColor.clearColor;
    vc.view.userInteractionEnabled = NO;
    w.rootViewController = vc;
    UILabel *label = RL_AUTORELEASE([[UILabel alloc] init]);
    label.text = [NSString stringWithFormat:@"   %@   ", text];   // room around the text inside the rounded label
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    label.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.85];
    label.layer.cornerRadius = 12;
    label.layer.masksToBounds = YES;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:label];
    UILayoutGuide *safe = vc.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [label.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [label.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor multiplier:0.9],
        [label.widthAnchor constraintLessThanOrEqualToConstant:560],
        [label.heightAnchor constraintGreaterThanOrEqualToConstant:44],
    ]];
    self.noteWindow = RL_AUTORELEASE(w);
    w.hidden = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        w.hidden = YES;
        if (self.noteWindow == w) self.noteWindow = nil;
    });
}

- (void)tapAway {
    self.elsewhereDismissed = YES;
    [self uncover];
}

// While the game runs: another device started playing (or took the game with its own Play
// here), so Steam logged this session off and says the account plays elsewhere. The player
// chooses again, as at launch; after "without Steam" only once Steam is back here and the
// other device plays again. Deny's retries keep the session trying every two minutes, and it
// gets Steam back on its own once the other game ends.
//
// Steam logs the session off (LoggedInElsewhere) without saying the account plays elsewhere,
// and Kettle does not tell why a session ended; the next logon would, two minutes later. So a
// session lost while the game runs logs on again at once: Steam then says whether the account
// plays elsewhere (and logs it off again for claiming the game). After a network loss that
// logon just fails, as the retry would have.
- (void)watchPlaying {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self watchPlaying]; });
    uint32_t app = 0;
    BOOL blocked = RecompSteam_PlayingBlocked(&app);
    BOOL loggedOn = RecompSteam_State() == RecompSteamLoggedOn;
    BOOL lost = self.wasLoggedOn && !loggedOn;
    self.wasLoggedOn = loggedOn;
    if (loggedOn && !blocked && self.elsewhereDismissed) {
        self.elsewhereDismissed = NO;
        LLOG(@"back on Steam: the other device stopped playing");
        [self note:@"Back on Steam: the other device stopped playing. Online play, achievements and cloud "
                   @"saves work again."];
    }
    if (lost && !self.window && !self.elsewhereDismissed &&
        RecompSteam_ConcurrentPlay() != RecompSteamConcurrentPlayAllow) {
        NSDictionary *state = LoadState();
        if (state) {
            LLOG(@"the Steam session ended while playing: logging on again to ask Steam why");
            RecompSteam_Stop();
            RecompSteam_Start([state[@"refresh"] UTF8String], gAppId, DeviceName().UTF8String);
        }
        return;
    }
    if (self.window || self.elsewhereDismissed || loggedOn || !blocked ||
        RecompSteam_ConcurrentPlay() == RecompSteamConcurrentPlayAllow)
        return;
    NSDictionary *state = LoadState();
    if (!state) return;
    NSTimeInterval age = NSDate.date.timeIntervalSince1970 - [state[@"verified"] doubleValue];
    ++self.gen;
    PauseGame(YES);
    [self elsewhere:app tokens:state verified:age > -86400 && age < kGrace];
    self.titleLabel.text = @"Your Steam account is now playing on another device";
}

// --- sign-in ---

- (void)endFlow {
    if (self.flow) RecompSteamAuth_Cancel(self.flow);
    self.flow = 0;
    ++self.gen;
}

- (void)beginQR:(NSString *)status {
    PauseGame(YES);
    [self endFlow];
    NSInteger gen = self.gen;
    [self show:RLQR status:status];
    self.qrView.image = nil;
    [self.spinner startAnimating];
    __block BOOL shown = NO;
    self.flow = RecompSteamAuth_BeginQR(DeviceName().UTF8String, 0, ^(const char *url) {
        NSString *u = @(url);
        Main(^{
            if (gen != self.gen) return;
            shown = YES;
            [self.spinner stopAnimating];
            self.qrView.image = QRImage(u);
        });
    }, ^{
        Main(^{
            if (gen != self.gen || self.mode != RLQR) return;
            self.statusLabel.text = @"Approve the sign-in in the Steam Mobile app.";
            self.statusLabel.hidden = NO;
        });
    }, ^(int32_t er, const char *refresh, const char *access, const char *account) {
        NSDictionary *tokens = er == kOK ? @{@"refresh": @(refresh), @"account": @(account ?: "")} : nil;
        Main(^{
            if (gen != self.gen) return;
            self.flow = 0;
            [self.spinner stopAnimating];
            if (tokens) {
                [self signedIn:tokens];
            } else if (er == kTimeout && !shown) {
                self.statusLabel.text = [NSString stringWithFormat:@"Cannot reach Steam: %@.", Why(er)];
                self.statusLabel.hidden = NO;
                self.retryButton.hidden = NO;
            } else if (er == kTimeout) {
                [self beginQR:nil];   // waited too long: a new code
            } else {
                self.statusLabel.text = [NSString stringWithFormat:@"Steam refused the sign-in (error %d).", er];
                self.statusLabel.hidden = NO;
                self.retryButton.hidden = NO;
            }
        });
    });
}

- (void)signedIn:(NSDictionary *)tokens {
    uint64_t steamid = RecompSteamAuth_TokenSteamID([tokens[@"refresh"] UTF8String]);
    if (!steamid) {
        [self show:RLQR status:@"Steam did not say which account signed in. Try again."];
        return;
    }
    NSMutableDictionary *t = [NSMutableDictionary dictionaryWithDictionary:tokens];
    t[@"steamid"] = [NSString stringWithFormat:@"%llu", steamid];
    LLOG(@"signed in as %@", tokens[@"account"]);
    [self show:RLChecking status:nil];
    [self checkLicense:t quiet:NO];
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
    [self endFlow];
    NSInteger gen = self.gen;
    [self busy:YES];
    self.flow = RecompSteamAuth_BeginPassword(DeviceName().UTF8String, account.UTF8String, password.UTF8String,
                                              ^(const int *types, int count, const char *domain) {
        NSMutableArray *list = [NSMutableArray array];
        for (int i = 0; i < count; i++) [list addObject:@(types[i])];
        NSString *email = domain && *domain ? @(domain) : nil;
        Main(^{
            if (gen != self.gen) return;
            [self busy:NO];
            self.passwordField.text = @"";
            [self guard:list email:email];
        });
    }, ^(int32_t er, const char *refresh, const char *access, const char *acct) {
        NSDictionary *tokens = er == kOK ? @{@"refresh": @(refresh), @"account": @(acct ?: "")} : nil;
        Main(^{
            if (gen != self.gen) return;
            self.flow = 0;
            [self busy:NO];
            if (tokens) {
                [self signedIn:tokens];
                return;
            }
            NSString *why = er == kInvalidPassword ? @"Wrong account name or password."
                          : er == kRateLimitExceeded ? @"Too many sign-in attempts. Wait a while, then try again."
                          : er == kFileNotFound || er == kExpired ? @"The sign-in timed out. Sign in again."
                          : [NSString stringWithFormat:@"Steam refused the sign-in: %@.", Why(er)];
            [self show:RLPassword status:why];
        });
    });
}

// What Steam Guard asks for, from the session's allowed confirmations.
- (void)guard:(NSArray *)confirmations email:(NSString *)email {
    NSMutableArray *lines = [NSMutableArray array];
    self.codeType = 0;
    for (NSNumber *c in confirmations) {
        int type = c.intValue;
        if (type == kGuardDeviceConfirmation) [lines addObject:@"Approve the sign-in in the Steam Mobile app"];
        if (type == kGuardEmailConfirmation) [lines addObject:@"Confirm the sign-in from the email Steam sent you"];
        if (type == kGuardDeviceCode) self.codeType = kGuardDeviceCode;
        if (type == kGuardEmailCode && self.codeType != kGuardDeviceCode) self.codeType = kGuardEmailCode;
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
    if (!code.length || !self.flow) return;
    NSInteger gen = self.gen;
    self.codeButton.enabled = NO;
    RecompSteamAuth_SubmitCode(self.flow, code.UTF8String, self.codeType, ^(int32_t er) {
        Main(^{
            if (gen != self.gen) return;
            self.codeButton.enabled = YES;
            if (er == kOK || er == kDuplicateRequest) {
                self.statusLabel.text = @"Code accepted, signing in…";
            } else if (er == kInvalidLoginAuthCode || er == kTwoFactorCodeMismatch) {
                self.statusLabel.text = @"That code is not right. Check it and try again.";
                self.codeField.text = @"";
            } else {
                self.statusLabel.text = [NSString stringWithFormat:@"The code was not sent: %@.", Why(er)];
            }
            self.statusLabel.hidden = NO;
        });
    });
}

// --- buttons ---

- (void)tapSwitch {
    if (self.mode == RLQR) {
        [self endFlow];  // stop polling the QR session
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
        [self checkLicense:state quiet:NO];
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
    self.hereButton.hidden = self.awayButton.hidden = mode != RLElsewhere;
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
    self.hereButton = [self button:@"Play here" action:@selector(tapHere) primary:YES];
    self.awayButton = [self button:@"Play without Steam for now" action:@selector(tapAway) primary:NO];

    for (UIView *v in @[self.titleLabel, self.bodyLabel, self.qrBox, self.qrHint, self.accountField, self.passwordField,
                        self.signInButton, self.guardLabel, self.codeField, self.codeButton, self.spinner,
                        self.statusLabel, self.retryButton, self.hereButton, self.awayButton, self.storeButton,
                        self.otherButton, self.switchButton])
        [stack addArrangedSubview:v];
    [stack setCustomSpacing:22 afterView:self.bodyLabel];
}

- (void)cover {
    if (self.window) return;
    if (!self.controller) [self build];
    // Over the game's own scene (AIR's CTAIRSceneDelegate, Unity's and Unreal's implicit one).
    UIWindowScene *scene = GameWindow().windowScene;
    if (!scene) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
            if ([s isKindOfClass:UIWindowScene.class] && (!scene || s.activationState == UISceneActivationStateForegroundActive))
                scene = (UIWindowScene *)s;
    }
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
    PauseGame(NO);
    if (!self.watching) {
        self.watching = YES;
        [self watchPlaying];
    }
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
