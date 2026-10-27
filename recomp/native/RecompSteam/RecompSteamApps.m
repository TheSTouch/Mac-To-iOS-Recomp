// Ownership and presence for the flat API: the game's ownership ticket (owned DLC,
// family sharing) and "playing" on Steam. ARC.
#import <Foundation/Foundation.h>
#include <TargetConditionals.h>
#include <os/lock.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif
#include "RecompSteamFlat.h"
#include "RecompSteamInternal.h"

#define RLOG(...) RecompSteam_Log(__VA_ARGS__)

// --- the ownership ticket -------------------------------------------------------------------

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static NSMutableSet<NSNumber *> *gOwnedDLC;
static NSArray<NSNumber *> *gLicenses;     // packages that grant the game
static BOOL gHaveTicket;

static uint32_t LE32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t LE16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }

// The ownership ticket: length, version, SteamID, app, external IP, internal IP, flags,
// generated, expires, license count (16-bit) and licenses, DLC count and for each DLC
// its app and licenses, reserved, then the signature (steam3_appticket in SteamKit2).
static void ParseTicket(const uint8_t *t, size_t n)
{
    if (n < 42) return;
    const uint8_t *p = t + 40, *end = t + MIN(n, (size_t)LE32(t));
    NSMutableArray *licenses = [NSMutableArray array];
    NSMutableSet *dlc = [NSMutableSet set];
    if (p + 2 > end) return;
    uint16_t count = LE16(p);
    p += 2;
    for (int i = 0; i < count && p + 4 <= end; i++, p += 4) [licenses addObject:@(LE32(p))];
    if (p + 2 <= end) {
        uint16_t dlcs = LE16(p);
        p += 2;
        for (int i = 0; i < dlcs && p + 6 <= end; i++) {
            [dlc addObject:@(LE32(p))];
            uint16_t lic = LE16(p + 4);
            p += 6 + 4 * lic;
        }
    }
    os_unfair_lock_lock(&gLock);
    gLicenses = licenses;
    gOwnedDLC = dlc;
    gHaveTicket = YES;
    os_unfair_lock_unlock(&gLock);
    RLOG("app %u: owned, %lu DLC in the ownership ticket", LE32(t + 16), (unsigned long)dlc.count);
}

static void FetchTicket(void)
{
    uint32_t app = RecompSteam_AppID();
    if (!app) return;
    RecompSteam_AppOwnershipTicket(app, ^(int32_t er, const uint8_t *ticket, size_t n) {
        if (er == RecompSteamResultOK) ParseTicket(ticket, n);
        else RLOG("no ownership ticket for app %u (EResult %d)", app, er);
    });
}

bool RS_OwnsApp(uint32_t app)
{
    // The game itself: the port's license check stands for it (also offline).
    if (app == RecompSteam_AppID()) return true;
    os_unfair_lock_lock(&gLock);
    bool owned = [gOwnedDLC containsObject:@(app)];
    os_unfair_lock_unlock(&gLock);
    return owned;
}

uint64_t RS_AppOwner(void) { return RS_SteamID(); }

// --- presence -------------------------------------------------------------------------------------

static BOOL gPlaying, gWatching;

static void SetPlaying(BOOL on)
{
    uint32_t app = RecompSteam_AppID() ?: RS_GameAppID();
    if (!app) return;
    RecompSteam_GamesPlayed(on ? &app : NULL, on ? 1 : 0);
}

static void Watch(void)
{
    if (gWatching) return;
    gWatching = YES;
    RecompSteam_AddStateObserver(^(RecompSteamState s) {
        if (s != RecompSteamLoggedOn) return;
        FetchTicket();
        if (gPlaying) SetPlaying(YES);   // the session may have started after the game did
    });
    atexit_b(^{ SetPlaying(NO); });
#if TARGET_OS_IPHONE
    // Leaving the game is leaving it: iOS suspends a backgrounded app within seconds, and
    // Steam would go on counting it as played (and refuse the game on another device) until
    // its connection timed out. A background task lets the message go out first.
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        if (!gPlaying) return;
        UIApplication *app = UIApplication.sharedApplication;
        __block UIBackgroundTaskIdentifier task = [app beginBackgroundTaskWithName:@"Steam presence" expirationHandler:^{
            [app endBackgroundTask:task];
            task = UIBackgroundTaskInvalid;
        }];
        SetPlaying(NO);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (task != UIBackgroundTaskInvalid) [app endBackgroundTask:task];
            task = UIBackgroundTaskInvalid;
        });
    }];
    [nc addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        if (gPlaying) SetPlaying(YES);
    }];
    [nc addObserverForName:UIApplicationWillTerminateNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        SetPlaying(NO);
    }];
#endif
}

void RS_PresenceStart(void)
{
    Watch();
    gPlaying = YES;
    SetPlaying(YES);
}

void RS_PresenceStop(void)
{
    gPlaying = NO;
    SetPlaying(NO);
}
