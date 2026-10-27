// Starting the session in a port: the game's app id and how the sign-in is labelled,
// then a logon with the stored token as the app loads, so it is up before the game asks.
// ARC.
#import <Foundation/Foundation.h>
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif
#include "RecompSteamAuth.h"
#include "RecompSteamFlat.h"
#include "RecompSteamInternal.h"

// iOS: Info.plist "RecompSteamAppId". macOS: $SteamAppId, then steam_appid.txt beside the
// app (where Steam installs it) or in the working folder, then Info.plist.
static uint32_t FindAppID(void)
{
    id plist = NSBundle.mainBundle.infoDictionary[@"RecompSteamAppId"];
    uint32_t fromPlist = [plist respondsToSelector:@selector(unsignedIntValue)] ? [plist unsignedIntValue] : 0;
#if TARGET_OS_IPHONE
    return fromPlist;
#else
    const char *env = getenv("SteamAppId");
    if (env && atoi(env) > 0) return (uint32_t)atoi(env);
    NSString *bundle = NSBundle.mainBundle.bundlePath;
    for (NSString *dir in @[bundle.stringByDeletingLastPathComponent, NSFileManager.defaultManager.currentDirectoryPath]) {
        NSString *txt = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"steam_appid.txt"]
                                                  encoding:NSUTF8StringEncoding error:nil];
        if (txt.intValue > 0) return (uint32_t)txt.intValue;
    }
    return fromPlist;
#endif
}

// "Recomp: <game> on <device>", as Steam lists the sign-in.
static NSString *MachineName(void)
{
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *game = info[@"RecompGame"] ?: info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: @"game";
#if TARGET_OS_IPHONE
    NSString *device = UIDevice.currentDevice.model;   // "iPad": the device's own name needs the main thread
#else
    NSString *device = NSProcessInfo.processInfo.hostName;
    if ([device hasSuffix:@".local"]) device = [device substringToIndex:device.length - 6];
#endif
    return [NSString stringWithFormat:@"Recomp: %@ on %@", game, device];
}

static BOOL gTried;

uint32_t RS_GameAppID(void)
{
    static uint32_t app;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ app = FindAppID(); });
    return app;
}

bool RecompSteam_StartStored(void)
{
    static dispatch_once_t once;
    static bool found;
    dispatch_once(&once, ^{
        gTried = YES;
        uint32_t app = RS_GameAppID();
        if (!app) return;
        RS_SetAppID(app);
#if TARGET_OS_IPHONE
        // Deleting Documents/Recomp Steam license.txt in Files is how the player signs out
        // (RecompLicense.m): without it the stored token is not used.
        const char *home = getenv("CFFIXED_USER_HOME");
        NSString *container = home ? @(home) : NSHomeDirectory();
        NSString *status = [container stringByAppendingPathComponent:@"Documents/Recomp Steam license.txt"];
        if (![NSFileManager.defaultManager fileExistsAtPath:status]) {
            RecompSteam_Log("signed out (no Recomp Steam license.txt): not logging on");
            return;
        }
#endif
        char *token = RecompSteamAuth_StoredToken(app);
        if (!token) {
            RecompSteam_Log("no Steam sign-in stored for app %u", app);
            return;
        }
        found = true;
        RecompSteam_Start(token, app, MachineName().UTF8String);
        free(token);
        RS_PresenceStart();   // playing from launch, as when Steam starts a game
    });
    return found;
}

// As the app loads; recomp-steam-cli has no app id and starts the session itself.
__attribute__((constructor)) static void RecompSteamAutoStart(void)
{
    if (getenv("RECOMP_STEAM_NO_AUTOSTART")) return;
    @autoreleasepool {
        if (RS_GameAppID()) RecompSteam_StartStored();
    }
}
