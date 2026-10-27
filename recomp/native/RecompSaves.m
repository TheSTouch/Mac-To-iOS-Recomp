// Saves that follow the player between the Mac game and its iOS port, through a
// folder in iCloud Drive that Files and Finder both show. Shared by both routes:
// the Unreal shim compiles it in (unreal_ios.py), Unity ports get it in
// Assets/Plugins/iOS with the other top-level files of recomp/native.
//
// Info.plist "RecompSaves" is the profile's saves block ({"ios": root relative
// to the app container, "include": top-level names under it}) and "RecompGame"
// the game's name. Without them this file does nothing, nor when "RecompSavesMode"
// (chosen at port time, recomp/steam_cloud.py) is not "icloud": "steam" ports sync
// with Steam Cloud instead (RecompSteam/cloud*.m), "off" ones not at all.
//
// The first launch asks for a folder through the document picker, so no iCloud
// entitlement is needed: the player picks "Recomp Saves" and the port syncs with
// "<picked>/<RecompGame>/", the folder `recomp.py saves --enable` moves the Mac
// game's saves to. A security-scoped bookmark remembers the choice. Each include
// entry is synced both ways at launch (before the game reads its saves), on
// entering the background, on termination and every 5 minutes:
//   - per file, the newest modification date wins;
//   - a version changed since the last sync is never overwritten: it is kept
//     next to the winner as "<name>.conflict-<device>-<yyyyMMdd-HHmm><ext>";
//   - nothing is deleted, on either side.
// Every read and write in the picked folder goes through NSFileCoordinator.
// Documents/Recomp Saves.txt says whether sync is on, the last sync and errors.
//
// Builds with and without ARC: Unity's plugin settings differ from the shim's.
#import <UIKit/UIKit.h>
#include <stdio.h>

#if __has_feature(objc_arc)
#define RS_RETAIN(x) (x)
#define RS_RELEASE(x) ((void)0)
#define RS_AUTORELEASE(x) (x)
#else
#define RS_RETAIN(x) [(x) retain]
#define RS_RELEASE(x) [(x) release]
#define RS_AUTORELEASE(x) [(x) autorelease]
#endif

#define SLOG(fmt, ...) NSLog(@"[recomp] saves: " fmt, ##__VA_ARGS__)

static NSString *const kBookmark = @"RecompSavesBookmark";
static const NSTimeInterval kLaunchWait = 15;   // the launch watchdog allows ~20 s
static const NSTimeInterval kPeriod = 300;
static const NSTimeInterval kSameTime = 1;     // file systems round modification dates
static const NSTimeInterval kSettling = 5;     // a file this fresh may be half written

static NSDictionary *gSaves;
static NSString *gGame, *gDevice, *gContainer;
static NSURL *gCloud;                          // <picked>/<RecompGame>/, nil when sync is off
static dispatch_queue_t gQueue;                // every sync runs here, one at a time
static dispatch_source_t gTimer;
static BOOL gAsk;

// --- paths -------------------------------------------------------------------------

static NSString *InContainer(NSString *rel) { return [gContainer stringByAppendingPathComponent:rel]; }
static NSString *LocalRoot(void) { return InContainer(gSaves[@"ios"]); }
static NSString *StatusPath(void) { return InContainer(@"Documents/Recomp Saves.txt"); }
static NSString *OffPath(void) { return InContainer(@"Documents/Recomp Saves off.txt"); }
static NSString *StatePath(void) { return InContainer(@"Library/Application Support/RecompSaves/state.plist"); }

static NSArray *Include(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (id n in gSaves[@"include"])
        if ([n isKindOfClass:NSString.class] && [n length] && ![n containsString:@"/"] && ![n hasPrefix:@"."])
            [out addObject:n];
    return out;
}

static NSURL *GameFolder(NSURL *picked) {
    if ([picked.lastPathComponent isEqualToString:gGame]) return picked;
    return [picked URLByAppendingPathComponent:gGame isDirectory:YES];
}

static NSString *Shown(NSURL *url) {
    NSString *p = url.path;
    NSRange r = [p rangeOfString:@"/com~apple~CloudDocs/"];
    if (r.location != NSNotFound) return [@"iCloud Drive/" stringByAppendingString:[p substringFromIndex:NSMaxRange(r)]];
    NSArray *c = p.pathComponents;
    return c.count > 2 ? [[c subarrayWithRange:NSMakeRange(c.count - 2, 2)] componentsJoinedByString:@"/"] : p;
}

static NSString *Stamp(NSDate *d, NSString *format) {
    NSDateFormatter *f = RS_AUTORELEASE([[NSDateFormatter alloc] init]);
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = format;
    return [f stringFromDate:d];
}

// --- status file -----------------------------------------------------------------

static void WriteStatus(NSString *text) {
    NSString *path = StatusPath();
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void WriteStatusOff(void) {
    WriteStatus([NSString stringWithFormat:
        @"Saves sync with iCloud Drive is off for %@ on this device.\n\n"
        @"Delete this file to be asked again the next time the game starts.\n", gGame]);
}

// --- one file's metadata ---------------------------------------------------------

@interface RecompSaveFile : NSObject
@property (nonatomic) NSTimeInterval mtime;    // 0 when not known yet (an iCloud placeholder)
@property (nonatomic) unsigned long long size;
@property (nonatomic) BOOL downloaded;
@end
@implementation RecompSaveFile
@end

static NSArray *Keys(void) {
    return @[NSURLIsDirectoryKey, NSURLContentModificationDateKey, NSURLFileSizeKey,
             NSURLUbiquitousItemDownloadingStatusKey];
}

static BOOL Skipped(NSString *name) {
    return [name isEqualToString:@".DS_Store"] || [name isEqualToString:@"steam_autocloud.vdf"] ||
           [name hasSuffix:@".recomp-tmp"];
}

static RecompSaveFile *Describe(NSDictionary *v) {
    RecompSaveFile *f = RS_AUTORELEASE([[RecompSaveFile alloc] init]);
    f.mtime = [v[NSURLContentModificationDateKey] timeIntervalSince1970];
    f.size = [v[NSURLFileSizeKey] unsignedLongLongValue];
    NSString *status = v[NSURLUbiquitousItemDownloadingStatusKey];
    f.downloaded = !status || ![status isEqualToString:NSURLUbiquitousItemDownloadingStatusNotDownloaded];
    return f;
}

// Every file under url, keyed by its path relative to the save root.
static void Collect(NSURL *url, NSString *rel, NSMutableDictionary *out) {
    NSDictionary *v = [url resourceValuesForKeys:Keys() error:nil];
    if (!v) return;
    if (![v[NSURLIsDirectoryKey] boolValue]) {
        out[rel] = Describe(v);
        return;
    }
    NSArray *children = [NSFileManager.defaultManager contentsOfDirectoryAtURL:url includingPropertiesForKeys:Keys()
                                                                       options:0 error:nil];
    for (NSURL *child in children) {
        NSString *name = child.lastPathComponent;
        if (Skipped(name)) continue;
        // Older iCloud Drive keeps a not-downloaded file as ".<name>.icloud".
        if ([name hasPrefix:@"."] && [name hasSuffix:@".icloud"] && name.length > 8) {
            RecompSaveFile *f = RS_AUTORELEASE([[RecompSaveFile alloc] init]);
            out[[rel stringByAppendingPathComponent:[name substringWithRange:NSMakeRange(1, name.length - 8)]]] = f;
            continue;
        }
        Collect(child, [rel stringByAppendingPathComponent:name], out);
    }
}

static NSMutableDictionary *CollectLocal(NSArray *rels) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSURL *root = [NSURL fileURLWithPath:LocalRoot() isDirectory:YES];
    for (NSString *rel in rels) Collect([root URLByAppendingPathComponent:rel], rel, out);
    return out;
}

// Metadata only: a coordinated read that does not wait for downloads.
static NSMutableDictionary *CollectCloud(NSArray *rels, NSMutableArray *errors) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSFileCoordinator *fc = RS_AUTORELEASE([[NSFileCoordinator alloc] initWithFilePresenter:nil]);
    NSError *err = nil;
    [fc coordinateReadingItemAtURL:gCloud options:NSFileCoordinatorReadingImmediatelyAvailableMetadataOnly error:&err
                        byAccessor:^(NSURL *root) {
        for (NSString *rel in rels) Collect([root URLByAppendingPathComponent:rel], rel, out);
    }];
    if (err) [errors addObject:[NSString stringWithFormat:@"reading %@: %@", Shown(gCloud), err.localizedDescription]];
    return out;
}

// --- copies ----------------------------------------------------------------------

// Copies src over dst through a temporary file next to dst, keeping src's
// modification date, so a reader sees the old file or the new one, never half.
// With fresh, a dst that appeared since the listing is left alone (next round).
static BOOL Place(NSURL *src, NSURL *dst, BOOL fresh, NSMutableArray *errors) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (fresh && [fm fileExistsAtPath:dst.path]) return NO;
    NSURL *dir = dst.URLByDeletingLastPathComponent;
    NSURL *tmp = [dir URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.recomp-tmp", dst.lastPathComponent]];
    NSError *err = nil;
    NSDate *mtime = nil;
    [src getResourceValue:&mtime forKey:NSURLContentModificationDateKey error:nil];
    [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtURL:tmp error:nil];
    if (![fm copyItemAtURL:src toURL:tmp error:&err]) {
        [errors addObject:[NSString stringWithFormat:@"copying %@: %@", Shown(dst), err.localizedDescription]];
        return NO;
    }
    if (mtime) [fm setAttributes:@{NSFileModificationDate: mtime} ofItemAtPath:tmp.path error:nil];
    if (rename(tmp.fileSystemRepresentation, dst.fileSystemRepresentation) != 0) {
        [errors addObject:[NSString stringWithFormat:@"replacing %@: %s", Shown(dst), strerror(errno)]];
        [fm removeItemAtURL:tmp error:nil];
        return NO;
    }
    return YES;
}

static NSURL *LocalURL(NSString *rel) { return [NSURL fileURLWithPath:[LocalRoot() stringByAppendingPathComponent:rel]]; }
static NSURL *CloudURL(NSString *rel) { return [gCloud URLByAppendingPathComponent:rel]; }

static BOOL ToCloud(NSString *fromRel, NSString *toRel, BOOL fresh, NSMutableArray *errors) {
    NSURL *dst = CloudURL(toRel);
    NSURL *tmp = [dst.URLByDeletingLastPathComponent URLByAppendingPathComponent:
                  [NSString stringWithFormat:@".%@.recomp-tmp", dst.lastPathComponent]];
    __block BOOL ok = NO;
    NSFileCoordinator *fc = RS_AUTORELEASE([[NSFileCoordinator alloc] initWithFilePresenter:nil]);
    NSError *err = nil;
    [fc coordinateWritingItemAtURL:tmp options:0 writingItemAtURL:dst options:NSFileCoordinatorWritingForReplacing
                             error:&err byAccessor:^(NSURL *t, NSURL *d) { ok = Place(LocalURL(fromRel), d, fresh, errors); }];
    if (err) [errors addObject:[NSString stringWithFormat:@"writing %@: %@", Shown(dst), err.localizedDescription]];
    return ok;
}

// A coordinated read without the metadata-only option downloads the file first.
static BOOL ToLocal(NSString *fromRel, NSString *toRel, BOOL fresh, NSMutableArray *errors) {
    __block BOOL ok = NO;
    NSFileCoordinator *fc = RS_AUTORELEASE([[NSFileCoordinator alloc] initWithFilePresenter:nil]);
    NSError *err = nil;
    [fc coordinateReadingItemAtURL:CloudURL(fromRel) options:0 error:&err
                        byAccessor:^(NSURL *src) { ok = Place(src, LocalURL(toRel), fresh, errors); }];
    if (err) [errors addObject:[NSString stringWithFormat:@"reading %@: %@", Shown(CloudURL(fromRel)),
                                err.localizedDescription]];
    return ok;
}

static BOOL SameBytes(NSString *rel) {
    __block BOOL same = NO;
    NSData *mine = [NSData dataWithContentsOfURL:LocalURL(rel) options:NSDataReadingMappedIfSafe error:nil];
    if (!mine) return NO;
    NSFileCoordinator *fc = RS_AUTORELEASE([[NSFileCoordinator alloc] initWithFilePresenter:nil]);
    [fc coordinateReadingItemAtURL:CloudURL(rel) options:0 error:nil byAccessor:^(NSURL *u) {
        same = [mine isEqualToData:[NSData dataWithContentsOfURL:u options:NSDataReadingMappedIfSafe error:nil]];
    }];
    return same;
}

static NSTimeInterval LocalTime(NSString *rel) {
    NSDate *d = nil;
    [LocalURL(rel) getResourceValue:&d forKey:NSURLContentModificationDateKey error:nil];
    return d.timeIntervalSince1970;
}

static NSTimeInterval CloudTime(NSString *rel) {
    __block NSTimeInterval t = 0;
    NSFileCoordinator *fc = RS_AUTORELEASE([[NSFileCoordinator alloc] initWithFilePresenter:nil]);
    [fc coordinateReadingItemAtURL:CloudURL(rel) options:NSFileCoordinatorReadingImmediatelyAvailableMetadataOnly
                             error:nil byAccessor:^(NSURL *u) {
        NSDate *d = nil;
        [u getResourceValue:&d forKey:NSURLContentModificationDateKey error:nil];
        t = d.timeIntervalSince1970;
    }];
    return t;
}

// "Saves/x/a.timber" -> "Saves/x/a.conflict-iPhone-20261025-1300.timber", unused on both sides; the
// device part is UIDevice.name, which since iOS 16 is only the kind of device (iPhone, iPad).
static NSString *ConflictName(NSString *rel, NSTimeInterval mtime, NSDictionary *local, NSDictionary *cloud) {
    NSString *dir = rel.stringByDeletingLastPathComponent, *name = rel.lastPathComponent;
    NSString *ext = name.pathExtension.length ? [@"." stringByAppendingString:name.pathExtension] : @"";
    NSString *stem = ext.length ? name.stringByDeletingPathExtension : name;
    NSString *base = [NSString stringWithFormat:@"%@.conflict-%@-%@", stem, gDevice,
                      Stamp([NSDate dateWithTimeIntervalSince1970:mtime], @"yyyyMMdd-HHmm")];
    for (int i = 1;; i++) {
        NSString *n = i == 1 ? base : [NSString stringWithFormat:@"%@-%d", base, i];
        NSString *candidate = [dir stringByAppendingPathComponent:[n stringByAppendingString:ext]];
        if (!local[candidate] && !cloud[candidate] &&
            ![NSFileManager.defaultManager fileExistsAtPath:LocalURL(candidate).path]) return candidate;
    }
}

// --- sync --------------------------------------------------------------------------

@interface RecompSyncReport : NSObject
@property (nonatomic) int toCloud, toLocal, conflicts, waiting;
@property (nonatomic, strong) NSMutableArray *errors;
@property (nonatomic) BOOL timedOut;
@end
@implementation RecompSyncReport
#if !__has_feature(objc_arc)
- (void)dealloc {
    [_errors release];
    [super dealloc];
}
#endif
@end

// One file present on at least one side. Returns NO when it has to wait for a download.
static BOOL SyncFile(NSString *rel, RecompSaveFile *l, RecompSaveFile *c, NSMutableDictionary *state,
                     NSDictionary *local, NSDictionary *cloud, BOOL settle, RecompSyncReport *r) {
    NSDictionary *s = state[rel];
    if (l && settle && NSDate.date.timeIntervalSince1970 - l.mtime < kSettling) return YES; // next round
    if (!c) {
        if (ToCloud(rel, rel, YES, r.errors)) r.toCloud++;
        else return YES;
    } else {
        BOOL lChanged = !s || fabs(l.mtime - [s[@"l"] doubleValue]) > kSameTime;
        BOOL cChanged = !s || fabs(c.mtime - [s[@"c"] doubleValue]) > kSameTime;
        if (l && !lChanged && !cChanged) return YES;
        if (l && c.mtime > 0 && l.size == c.size && fabs(l.mtime - c.mtime) <= kSameTime) {
            state[rel] = @{@"l": @(l.mtime), @"c": @(c.mtime)};
            return YES;
        }
        // The cloud copy's bytes are needed to copy it here or to keep it as a conflict copy.
        if (!c.downloaded && (!l || cChanged || c.mtime > l.mtime)) {
            [NSFileManager.defaultManager startDownloadingUbiquitousItemAtURL:CloudURL(rel) error:nil];
            return NO;
        }
        if (!l) {
            if (ToLocal(rel, rel, YES, r.errors)) r.toLocal++;
            else return YES;
        } else if (!(l.size == c.size && SameBytes(rel))) {
            BOOL localWins = l.mtime >= c.mtime;
            if (localWins ? cChanged : lChanged) {
                // The losing copy changed since the last sync: keep it under another name, on both sides.
                NSString *keep = ConflictName(rel, localWins ? c.mtime : l.mtime, local, cloud);
                BOOL kept = localWins ? ToLocal(rel, keep, YES, r.errors) && ToCloud(keep, keep, YES, r.errors)
                                      : Place(LocalURL(rel), LocalURL(keep), YES, r.errors) &&
                                        ToCloud(keep, keep, YES, r.errors);
                if (!kept) return YES; // never overwrite a copy that could not be kept
                SLOG(@"conflict: %@ changed on both sides, kept %@", rel, keep);
                r.conflicts++;
            }
            if (!(localWins ? ToCloud(rel, rel, NO, r.errors) : ToLocal(rel, rel, NO, r.errors))) return YES;
            if (localWins) r.toCloud++;
            else r.toLocal++;
        }
    }
    state[rel] = @{@"l": @(LocalTime(rel)), @"c": @(CloudTime(rel))};
    return YES;
}

static RecompSyncReport *Sync(NSString *why, NSTimeInterval budget) {
    RecompSyncReport *r = RS_AUTORELEASE([[RecompSyncReport alloc] init]);
    r.errors = [NSMutableArray array];
    if (!gCloud) return r;
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + budget;
    BOOL settle = [why isEqualToString:@"periodic"];
    NSMutableDictionary *state = [NSMutableDictionary dictionaryWithContentsOfFile:StatePath()] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *files = [NSMutableDictionary dictionaryWithDictionary:state[@"files"] ?: @{}];

    __block BOOL made = NO;
    NSFileCoordinator *fc = RS_AUTORELEASE([[NSFileCoordinator alloc] initWithFilePresenter:nil]);
    NSError *err = nil;
    [fc coordinateWritingItemAtURL:gCloud options:0 error:&err byAccessor:^(NSURL *u) {
        made = [NSFileManager.defaultManager createDirectoryAtURL:u withIntermediateDirectories:YES attributes:nil error:nil];
    }];
    if (!made) {
        [r.errors addObject:[NSString stringWithFormat:@"cannot open %@: %@", Shown(gCloud),
                             err.localizedDescription ?: @"folder not reachable"]];
        return r;
    }
    NSArray *rels = Include();
    for (int pass = 0; rels.count; pass++) {
        if (pass) [NSThread sleepForTimeInterval:0.5];
        NSUInteger failed = r.errors.count;
        NSMutableDictionary *local = CollectLocal(rels), *cloud = CollectCloud(rels, r.errors);
        if (r.errors.count > failed) break; // a folder that cannot be listed must not look empty
        NSMutableSet *all = [NSMutableSet setWithArray:local.allKeys];
        [all addObjectsFromArray:cloud.allKeys];
        NSMutableArray *waiting = [NSMutableArray array];
        for (NSString *rel in [all.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
            if (CFAbsoluteTimeGetCurrent() > deadline) { r.timedOut = YES; break; }
            @autoreleasepool {
                if (!SyncFile(rel, local[rel], cloud[rel], files, local, cloud, settle, r)) [waiting addObject:rel];
            }
        }
        r.waiting = (int)waiting.count;
        if (r.timedOut || !waiting.count || CFAbsoluteTimeGetCurrent() + 1 > deadline) break;
        rels = waiting; // only the files iCloud is still downloading
    }

    state[@"files"] = files;
    state[@"last"] = NSDate.date;
    [NSFileManager.defaultManager createDirectoryAtPath:StatePath().stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [state writeToFile:StatePath() atomically:YES];

    NSMutableString *text = [NSMutableString stringWithFormat:
        @"Saves sync with iCloud Drive is on for %@ on this device.\n\nFolder: %@\n"
        @"Last sync: %@ (%@): %d copied from iCloud Drive, %d copied to iCloud Drive, %d conflicts.\n",
        gGame, Shown(gCloud), Stamp(NSDate.date, @"yyyy-MM-dd HH:mm:ss"), why, r.toLocal, r.toCloud, r.conflicts];
    if (r.waiting) [text appendFormat:@"%d files are still downloading from iCloud Drive; they sync next time.\n", r.waiting];
    if (r.timedOut) [text appendString:@"The sync ran out of time; it continues next time.\n"];
    if (r.errors.count) [text appendFormat:@"\nErrors:\n  %@\n", [r.errors componentsJoinedByString:@"\n  "]];
    [text appendString:
        @"\nWhen a file changed on two devices, the newest version wins and the other one is kept next to it as "
        @"<name>.conflict-<device>-<date><ext>. Deleting a save does not delete it on other devices.\n\n"
        @"To stop syncing on this device, rename this file to \"Recomp Saves off.txt\".\n"];
    WriteStatus(text);
    SLOG(@"%@: %d from iCloud Drive, %d to iCloud Drive, %d conflicts, %d waiting, %lu errors%@", why, r.toLocal,
         r.toCloud, r.conflicts, r.waiting, (unsigned long)r.errors.count, r.timedOut ? @", out of time" : @"");
    for (NSString *e in r.errors) SLOG(@"  %@", e);
    return r;
}

// Runs a sync on the queue and waits at most `wait` seconds for it.
static void SyncAndWait(NSString *why, NSTimeInterval budget, NSTimeInterval wait) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(gQueue, ^{
        @autoreleasepool { Sync(why, budget); }
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC))))
        SLOG(@"%@: still running after %.0f s, the game goes on", why, wait);
#if !__has_feature(objc_arc)
    dispatch_release(done);
#endif
}

static void StartTimer(void) {
    if (gTimer) return;
    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
    dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPeriod * NSEC_PER_SEC)),
                              (uint64_t)(kPeriod * NSEC_PER_SEC), 30 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(gTimer, ^{ @autoreleasepool { Sync(@"periodic", 120); } });
    dispatch_resume(gTimer);
}

// --- first launch: ask for the folder ----------------------------------------------

// The game's window: windows above it (RecompLicense.m's sign-in cover) are skipped, so
// the picker waits under the cover until the license is checked.
static UIViewController *TopController(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows)
            if (w.rootViewController && w.windowLevel <= UIWindowLevelNormal && (!window || w.isKeyWindow)) window = w;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!window)
        for (UIWindow *w in UIApplication.sharedApplication.windows)
            if (w.rootViewController && w.windowLevel <= UIWindowLevelNormal && (!window || w.isKeyWindow)) window = w;
#pragma clang diagnostic pop
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void Tell(NSString *title, NSString *message) {
    UIViewController *vc = TopController();
    if (!vc) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}

@interface RecompSavesPicker : NSObject <UIDocumentPickerDelegate>
@end

static RecompSavesPicker *gPicker; // the picker's delegate is weak: kept for the process's life

@implementation RecompSavesPicker
- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    [url startAccessingSecurityScopedResource];
    NSError *err = nil;
    NSData *bookmark = [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:&err];
    if (!bookmark) {
        SLOG(@"cannot remember %@: %@", url.path, err.localizedDescription);
        Tell(@"Saves are not synced", [NSString stringWithFormat:@"The folder cannot be used: %@", err.localizedDescription]);
        return;
    }
    [NSUserDefaults.standardUserDefaults setObject:bookmark forKey:kBookmark];
    gAsk = NO;
    NSURL *game = RS_RETAIN(GameFolder(url));
    SLOG(@"syncing with %@", game.path);
    dispatch_async(gQueue, ^{
        @autoreleasepool {
            RS_RELEASE(gCloud);
            gCloud = game;
            RecompSyncReport *r = Sync(@"first sync", 60);
            StartTimer();
            NSString *msg = r.errors.count ? [NSString stringWithFormat:@"Some files did not sync:\n%@\n\nSee "
                                              @"\"Recomp Saves.txt\" in the game's folder in Files.",
                                              [r.errors componentsJoinedByString:@"\n"]]
                          : r.toLocal ? @"Saves from your other devices were copied. If the game does not list them "
                                        @"yet, close it and open it again."
                                      : nil;
            if (msg) dispatch_async(dispatch_get_main_queue(), ^{ Tell(@"Saves synced with iCloud Drive", msg); });
        }
    });
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)picker {
    // Asked again at the next launch.
}
@end

static void ShowPicker(void) {
    // UTType through the runtime: linking UniformTypeIdentifiers is not needed then.
    id folder = [NSClassFromString(@"UTType") performSelector:@selector(typeWithIdentifier:) withObject:@"public.folder"];
    UIViewController *vc = TopController();
    if (!folder || !vc) {
        SLOG(@"cannot show the folder picker (%@)", folder ? @"no window" : @"no UTType");
        return;
    }
    UIDocumentPickerViewController *p = RS_AUTORELEASE([[UIDocumentPickerViewController alloc]
                                                        initForOpeningContentTypes:@[folder]]);
    p.directoryURL = [NSURL fileURLWithPath:@"/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Recomp Saves"
                                isDirectory:YES];
    if (!gPicker) gPicker = [[RecompSavesPicker alloc] init];
    p.delegate = gPicker;
    [vc presentViewController:p animated:YES completion:nil];
}

static void Ask(int tries) {
    UIViewController *vc = TopController();
    if (!vc) {
        // The game's window is not up yet.
        if (tries == 59) SLOG(@"no window to ask from: asking at the next launch");
        if (tries < 60) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ Ask(tries + 1); });
        return;
    }
    NSString *message = [NSString stringWithFormat:
        @"Choose the \"Recomp Saves\" folder in iCloud Drive, or create it. %@ keeps its saves in the \"%@\" folder "
        @"inside, the same folder the Mac game uses once \"Sync saves with iCloud Drive\" is on in Recomp Helper.",
        gGame, gGame];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:
                            @"Sync saves with your other devices through iCloud Drive?"
                                                                message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Choose folder" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { ShowPicker(); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Not now" style:UIAlertActionStyleCancel
                                        handler:^(UIAlertAction *x) { SLOG(@"not now"); WriteStatusOff(); }]];
    SLOG(@"asking whether to sync (over %@)", NSStringFromClass(vc.class));
    [vc presentViewController:a animated:YES completion:nil];
}

// --- start-up ------------------------------------------------------------------------

static NSURL *Remembered(void) {
    NSData *bookmark = [NSUserDefaults.standardUserDefaults dataForKey:kBookmark];
    if (!bookmark) return nil;
    BOOL stale = NO;
    NSError *err = nil;
    NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil bookmarkDataIsStale:&stale
                                             error:&err];
    if (!url) {
        SLOG(@"the folder chosen earlier is gone (%@): asking again", err.localizedDescription);
        gAsk = YES;
        return nil;
    }
    [url startAccessingSecurityScopedResource];
    if (stale) {
        NSData *fresh = [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
        if (fresh) [NSUserDefaults.standardUserDefaults setObject:fresh forKey:kBookmark];
    }
    return GameFolder(url);
}

static void Background(NSString *why, NSTimeInterval budget) {
    if (!gCloud) return;
    UIApplication *app = UIApplication.sharedApplication;
    __block UIBackgroundTaskIdentifier task = [app beginBackgroundTaskWithName:@"RecompSaves" expirationHandler:^{
        [app endBackgroundTask:task];
        task = UIBackgroundTaskInvalid;
    }];
    dispatch_async(gQueue, ^{
        @autoreleasepool { Sync(why, budget); }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (task != UIBackgroundTaskInvalid) [app endBackgroundTask:task];
            task = UIBackgroundTaskInvalid;
        });
    });
}

__attribute__((constructor)) static void RecompSavesInit(void) {
    @autoreleasepool {
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        NSDictionary *saves = info[@"RecompSaves"];
        NSString *game = info[@"RecompGame"];
        NSString *mode = info[@"RecompSavesMode"];
        if (mode && ![mode isEqual:@"icloud"]) {
            SLOG(@"saves sync with %@: iCloud Drive not used", [mode isEqual:@"steam"] ? @"Steam Cloud" : @"nothing");
            return;
        }
        if (![saves isKindOfClass:NSDictionary.class] || ![game isKindOfClass:NSString.class] || !game.length ||
            ![saves[@"ios"] isKindOfClass:NSString.class])
            return;
        gSaves = RS_RETAIN(saves);
        gGame = RS_RETAIN(game);
        // recomp_runtime.c may already have moved $HOME to Documents; it pins the container first.
        const char *home = getenv("CFFIXED_USER_HOME");
        gContainer = RS_RETAIN(home ? [NSString stringWithUTF8String:home] : NSHomeDirectory());
        NSString *device = [[UIDevice.currentDevice.name componentsSeparatedByCharactersInSet:
                             [NSCharacterSet characterSetWithCharactersInString:@"/:\\."]] componentsJoinedByString:@"-"];
        gDevice = RS_RETAIN(device.length ? device : @"iOS");
        gQueue = dispatch_queue_create("recomp.saves", DISPATCH_QUEUE_SERIAL);

        NSFileManager *fm = NSFileManager.defaultManager;
        if ([fm fileExistsAtPath:OffPath()]) {
            SLOG(@"turned off from Files");
            [NSUserDefaults.standardUserDefaults removeObjectForKey:kBookmark];
            [fm removeItemAtPath:OffPath() error:nil];
            WriteStatusOff();
        }
        gCloud = RS_RETAIN(Remembered());
        if (gCloud) {
            SyncAndWait(@"launch", kLaunchWait - 2, kLaunchWait);
            StartTimer();
        } else if (![fm fileExistsAtPath:StatusPath()]) {
            gAsk = YES;
        }

        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *n) {
            if (gAsk) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ Ask(0); });
        }];
        [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *n) { Background(@"background", 25); }];
        [nc addObserverForName:UIApplicationWillTerminateNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *n) { if (gCloud) SyncAndWait(@"quit", 4, 4.5); }];
        SLOG(@"%@: %@ <-> %@", gGame, gSaves[@"ios"], gCloud ? Shown(gCloud) : @"(sync off)");
    }
}
