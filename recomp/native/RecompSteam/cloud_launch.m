// Steam Cloud saves around the game's life, as the Steam client syncs them around a game:
//   - at launch, before the game reads its saves (a constructor, like RecompSaves.m's),
//     the session logs on and Steam Cloud's changes come down; at most kLaunchWait;
//   - this device's changes go up right after, every kPeriod while it plays, when it
//     goes to the background and when it quits;
//   - while the game runs, Steam Cloud's changes wait for the next launch; when the
//     launch could not sync (no network yet, the first sign-in), the first sync that
//     brings files down asks the player to reopen the game so it reads them;
//   - a save changed both here and in Steam Cloud stays as it is until the player
//     chooses, Steam-style: "Steam Cloud" (then the game closes, to read it at the next
//     launch) or "This iPad" (it goes up). The version not chosen goes to the
//     backup folder. On a Mac test clone there is no prompt: conflicts stay, unless
//     RECOMP_STEAM_CLOUD_KEEP=cloud|local says which side to keep.
//
// Only in steam mode: Info.plist RecompSavesMode "steam" and RecompSteamCloud. Offline
// (no session, Steam not reachable) nothing syncs and the status file says so.
// Documents/Recomp Steam Cloud.txt (on a Mac: ~/Library/Application Support/RecompSteam/
// <appid>/) tells what the last sync did.
#import "cloud.h"
#import "RecompSteamSession.h"
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

static const NSTimeInterval kLaunchWait = 15;   // the launch watchdog allows ~20 s
static const NSTimeInterval kPeriod = 300;

static dispatch_queue_t gQueue;                 // every pass runs here, one at a time
static dispatch_source_t gTimer;
static NSString *gGame, *gDevice;
static BOOL gLaunchSynced, gAsking, gQuitting;

#if TARGET_OS_IPHONE
// --- asking the player (iOS) --------------------------------------------------------------

static UIWindow *gPromptWindow;

static NSString *Shown(NSTimeInterval t) {
    if (t <= 0) return @"deleted";
    return [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:t]
                                          dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle];
}

// A window of its own over the game (and over its input) for the prompt.
static UIViewController *PromptController(void) {
    if (gPromptWindow) return gPromptWindow.rootViewController;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        gPromptWindow = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
        gPromptWindow.windowLevel = UIWindowLevelAlert;
        gPromptWindow.rootViewController = [[UIViewController alloc] init];
        gPromptWindow.rootViewController.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
        gPromptWindow.hidden = NO;
        return gPromptWindow.rootViewController;
    }
    return nil;
}

static void ClosePrompt(void) {
    gPromptWindow.hidden = YES;
    gPromptWindow = nil;
}

static void Alert(NSString *title, NSString *message, NSArray<UIAlertAction *> *actions, int tries) {
    UIViewController *vc = PromptController();
    if (!vc) {
        if (tries < 60)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                Alert(title, message, actions, tries + 1);
            });
        return;
    }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message
                                                         preferredStyle:UIAlertControllerStyleAlert];
    for (UIAlertAction *x in actions) [a addAction:x];
    [vc presentViewController:a animated:YES completion:nil];
}

static void AskToReopen(NSString *why) {
    gQuitting = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *msg = [NSString stringWithFormat:@"%@ %@ closes now so it reads them; open it again to play.", why, gGame];
        Alert(@"Steam Cloud saves", msg, @[[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault
                                                                   handler:^(UIAlertAction *x) { exit(0); }]], 0);
    });
}

static void Resolve(NSArray<RSCloudConflict *> *conflicts, BOOL keepCloud) {
    dispatch_async(gQueue, ^{
        @autoreleasepool {
            RSCloudReport *r = RSCloudResolve(conflicts, keepCloud);
            gAsking = NO;
            if (keepCloud && r.downloaded + r.deletedHere > 0) {
                AskToReopen(@"Your saves from Steam Cloud are in place.");
            } else if (r.errors.count) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    Alert(@"Steam Cloud saves", [NSString stringWithFormat:@"Some saves did not sync:\n%@\n\nSee \"Recomp "
                                                                           @"Steam Cloud.txt\" in the game's folder in Files.",
                                                 [r.errors componentsJoinedByString:@"\n"]],
                          @[[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction *x) { ClosePrompt(); }]], 0);
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{ ClosePrompt(); });
            }
        }
    });
}

static void AskConflict(NSArray<RSCloudConflict *> *conflicts) {
    if (gAsking || gQuitting || !conflicts.count) return;
    gAsking = YES;
    NSTimeInterval cloudTime = 0, localTime = 0;
    NSString *machine = nil;
    for (RSCloudConflict *c in conflicts) {
        if (c.cloud.time > cloudTime) cloudTime = c.cloud.time, machine = c.cloud.machine;
        localTime = MAX(localTime, c.localTime);
    }
    NSString *here = [@"This " stringByAppendingString:gDevice];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *msg = [NSString stringWithFormat:
            @"Your saves of %@ changed both in Steam Cloud and on this %@ since they last synced.\n\n"
            @"Steam Cloud: %@%@\n%@: %@\n\nThe version you do not keep goes to the \"%@\" folder in Files.",
            gGame, gDevice, Shown(cloudTime), machine.length && ![machine isEqualToString:@"<unknown>"]
                ? [NSString stringWithFormat:@" (%@)", machine] : @"", here, Shown(localTime), RSCloudBackupShown()];
        Alert(@"Steam Cloud conflict", msg, @[
            [UIAlertAction actionWithTitle:@"Steam Cloud" style:UIAlertActionStyleDefault
                                   handler:^(UIAlertAction *x) { Resolve(conflicts, YES); }],
            [UIAlertAction actionWithTitle:here style:UIAlertActionStyleDefault
                                   handler:^(UIAlertAction *x) { Resolve(conflicts, NO); }],
        ], 0);
    });
}
#else
// --- a Mac test clone: no prompt ---------------------------------------------------------

static void AskToReopen(NSString *why) {
    CLOG(@"%@ Quit %@ and open it again to read them.", why, gGame);
}

static void AskConflict(NSArray<RSCloudConflict *> *conflicts) {
    const char *keep = getenv("RECOMP_STEAM_CLOUD_KEEP");
    if (gAsking || !conflicts.count) return;
    if (!keep || (strcmp(keep, "cloud") && strcmp(keep, "local"))) {
        CLOG(@"%lu conflicts left as they are; set RECOMP_STEAM_CLOUD_KEEP=cloud or local to choose",
             (unsigned long)conflicts.count);
        return;
    }
    gAsking = YES;
    BOOL keepCloud = !strcmp(keep, "cloud");
    dispatch_async(gQueue, ^{
        @autoreleasepool {
            RSCloudReport *r = RSCloudResolve(conflicts, keepCloud);
            gAsking = NO;
            if (keepCloud && r.downloaded + r.deletedHere > 0) AskToReopen(@"Your saves from Steam Cloud are in place.");
        }
    });
}
#endif

// --- passes ----------------------------------------------------------------------------

static void After(RSCloudReport *r) {
    if (r.conflicts.count) AskConflict(r.conflicts);
}

// On the queue: a pass with what this moment allows.
static RSCloudReport *Pass(NSString *why, BOOL settle, NSTimeInterval budget) {
    if (gQuitting) return nil;
    if (RecompSteam_State() != RecompSteamLoggedOn) {
        RSCloudWriteOffline(@"Steam is not reachable");
        return nil;
    }
    RSCloudSetAccount(RecompSteam_SteamID());
    // A launch that could not sync: the first pass brings Steam Cloud down, then asks to reopen.
    BOOL late = !gLaunchSynced;
    RSCloudReport *r = RSCloudSync(why, late, settle, budget);
    if (late && !r.offline) {
        gLaunchSynced = YES;
        if (r.downloaded + r.deletedHere > 0) AskToReopen(@"Your saves from Steam Cloud were copied to this device.");
    }
    After(r);
    return r;
}

#if TARGET_OS_IPHONE
static void Background(NSString *why, NSTimeInterval budget) {
    UIApplication *app = UIApplication.sharedApplication;
    __block UIBackgroundTaskIdentifier task = [app beginBackgroundTaskWithName:@"RecompSteamCloud" expirationHandler:^{
        [app endBackgroundTask:task];
        task = UIBackgroundTaskInvalid;
    }];
    dispatch_async(gQueue, ^{
        @autoreleasepool { Pass(why, NO, budget); }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (task != UIBackgroundTaskInvalid) [app endBackgroundTask:task];
            task = UIBackgroundTaskInvalid;
        });
    });
}
#endif

static void PassAndWait(NSString *why, NSTimeInterval wait) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(gQueue, ^{
        @autoreleasepool { Pass(why, NO, wait - 0.5); }
        dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)));
}

static void Passes(void) {
    if (gTimer) return;
    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
    dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPeriod * NSEC_PER_SEC)),
                              (uint64_t)(kPeriod * NSEC_PER_SEC), 30 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(gTimer, ^{ @autoreleasepool { Pass(@"periodic", YES, 120); } });
    dispatch_resume(gTimer);
    // A session that comes up later (the network, the first sign-in) syncs then.
    RecompSteam_AddStateObserver(^(RecompSteamState state) {
        if (state == RecompSteamLoggedOn && !gLaunchSynced)
            dispatch_async(gQueue, ^{ @autoreleasepool { Pass(@"signed in", NO, 120); } });
    });
}

#if !TARGET_OS_IPHONE
static void AtExit(void) { PassAndWait(@"quit", 10); }
#endif

// --- start-up ------------------------------------------------------------------------------

__attribute__((constructor)) static void RecompSteamCloudInit(void) {
    @autoreleasepool {
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        NSDictionary *config = info[@"RecompSteamCloud"];
        if (![info[@"RecompSavesMode"] isEqual:@"steam"] || ![config isKindOfClass:NSDictionary.class]) return;
        gGame = info[@"RecompGame"] ?: info[@"CFBundleName"] ?: @"The game";
#if TARGET_OS_IPHONE
        // recomp_runtime.c may already have moved $HOME to Documents; it pins the container first.
        const char *home = getenv("CFFIXED_USER_HOME");
        NSString *container = home ? [NSString stringWithUTF8String:home] : NSHomeDirectory();
        NSString *status = [container stringByAppendingPathComponent:@"Documents"];
        NSString *state = [container stringByAppendingPathComponent:@"Library/Application Support/RecompSteam"];
        gDevice = UIDevice.currentDevice.model.length ? UIDevice.currentDevice.model : @"device"; // "iPad", "iPhone"
#else
        NSString *container = NSHomeDirectory();
        NSString *status = [container stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"Library/Application Support/RecompSteam/%@", config[@"appid"]]];
        NSString *state = status;
        gDevice = @"Mac";
#endif
        if (!RSCloudConfigure(config, container, status, state, gDevice)) {
            CLOG(@"Info.plist RecompSteamCloud is not usable: no sync");
            return;
        }
        gQueue = dispatch_queue_create("recomp.steam.cloud", DISPATCH_QUEUE_SERIAL);

        // Down before the game reads its saves; this thread waits, the session does not need it.
        BOOL stored = RecompSteam_StartStored();
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block RSCloudReport *launch = nil;
        RecompSteam_WhenLoggedOn(stored ? kLaunchWait - 3 : 0, ^(bool loggedOn) {
            dispatch_async(gQueue, ^{
                @autoreleasepool {
                    if (loggedOn) {
                        RSCloudSetAccount(RecompSteam_SteamID());
                        launch = RSCloudSync(@"launch", YES, NO, 10);
                        gLaunchSynced = !launch.offline;
                    } else {
                        RSCloudWriteOffline(stored ? @"Steam did not answer in time" : @"not signed in to Steam yet");
                    }
                }
                dispatch_semaphore_signal(done);
            });
        });
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLaunchWait * NSEC_PER_SEC))))
            CLOG(@"launch: still syncing after %.0f s, the game goes on", kLaunchWait);
        // Conflicts are asked once the game's window is up; this device's changes go up now.
        dispatch_async(gQueue, ^{
            if (launch) After(launch);
            if (gLaunchSynced) Pass(@"after launch", NO, 120);
        });
        Passes();

#if TARGET_OS_IPHONE
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *n) { Background(@"background", 25); }];
        [nc addObserverForName:UIApplicationWillTerminateNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *n) { PassAndWait(@"quit", 4.5); }];
#else
        atexit(AtExit);
#endif
        CLOG(@"%@: app %u, %@", gGame, RSCloudAppID(), stored ? @"signed in" : @"not signed in yet");
    }
}
