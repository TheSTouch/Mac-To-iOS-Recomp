// Steam Cloud sync with local folders, the way the Steam client does it around a game.
//
// Info.plist "RecompSteamCloud" (written at port time by recomp/steam_cloud.py) holds the
// app id, the quota and the rules: each is a cloud name prefix ("%WinMyDocuments%
// Timberborn/Saves/", "" for ISteamRemoteStorage's files), a local folder, a file pattern
// and whether sub-folders count. "{64BitSteamID}" in either is the signed-in account's.
//
// A file is known by its cloud name. The state (cloud-state.plist) holds, per file, the
// SHA-1, size and time both sides had at the last sync. A pass:
//   - lists Steam Cloud and the local folders;
//   - before the first sync of this app (or of another account), backs up both sides;
//   - per file: changed only in Steam Cloud -> downloaded (with download) or, deleted
//     there, the local copy moves to the backup folder; changed only here -> uploaded,
//     or, deleted here, deleted in Steam Cloud; changed on both sides with different
//     bytes -> a conflict, left as it is for the player to choose (RSCloudResolve);
//   - a pass that would delete most of the cloud files at once holds the deletes (a
//     wiped folder must not wipe Steam Cloud) and says so.
// Nothing is ever deleted or overwritten without its last version in the backup folder or
// Steam Cloud. Status goes to "Recomp Steam Cloud.txt".
#import "cloud.h"
#import "RecompSteamSession.h"
#include <fnmatch.h>
#include <stdio.h>

static const NSTimeInterval kSettling = 5;

@implementation RSCloudConflict
@end
@implementation RSCloudReport
@end

@interface RSRule : NSObject
@property (nonatomic, copy) NSString *cloud, *local, *pattern;
@property (nonatomic) BOOL recursive;
@end
@implementation RSRule
@end

@interface RSLocal : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic) NSTimeInterval mtime;
@property (nonatomic) uint64_t size;
@end
@implementation RSLocal
@end

static NSDictionary *gConfig;
static NSString *gContainer, *gStatusDir, *gStateDir, *gDevice;
static NSArray<RSRule *> *gRules;
static uint64_t gSteamID;
static NSString *gBackup;          // this run's backup folder, made when first needed

uint32_t RSCloudAppID(void) { return [gConfig[@"appid"] unsignedIntValue]; }
uint64_t RSCloudQuota(void) { return [gConfig[@"quota"] unsignedLongLongValue]; }

static NSString *Expand(NSString *local) {
    if ([local hasPrefix:@"~/"]) return [NSHomeDirectory() stringByAppendingPathComponent:[local substringFromIndex:2]];
    return [gContainer stringByAppendingPathComponent:local];
}

static NSString *WithAccount(NSString *s) {
    return [s stringByReplacingOccurrencesOfString:@"{64BitSteamID}"
                                        withString:[NSString stringWithFormat:@"%llu", (unsigned long long)gSteamID]];
}

static NSString *StatePath(void) { return [gStateDir stringByAppendingPathComponent:@"cloud-state.plist"]; }
static NSString *StatusPath(void) { return [gStatusDir stringByAppendingPathComponent:@"Recomp Steam Cloud.txt"]; }
static NSString *BackupRoot(void) { return [gStatusDir stringByAppendingPathComponent:@"Recomp Steam Cloud backup"]; }

NSString *RSCloudBackupShown(void) { return @"Recomp Steam Cloud backup"; }

NSString *RSCloudRemoteFolder(void) {
    for (NSDictionary *r in gConfig[@"rules"])
        if ([r[@"cloud"] length] == 0) return Expand(r[@"local"]);
    return nil;
}

static NSArray<RSRule *> *Rules(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *r in gConfig[@"rules"]) {
        if (![r isKindOfClass:NSDictionary.class] || ![r[@"local"] isKindOfClass:NSString.class]) continue;
        RSRule *rule = [[RSRule alloc] init];
        rule.cloud = WithAccount(r[@"cloud"] ?: @"");
        rule.local = WithAccount(Expand(r[@"local"]));
        rule.pattern = r[@"pattern"] ?: @"*";
        rule.recursive = [r[@"recursive"] boolValue];
        [out addObject:rule];
    }
    // Longest prefix first; the root-less ISteamRemoteStorage rule last.
    [out sortUsingComparator:^NSComparisonResult(RSRule *a, RSRule *b) {
        return a.cloud.length == b.cloud.length ? NSOrderedSame : a.cloud.length > b.cloud.length ? NSOrderedAscending
                                                                                                  : NSOrderedDescending;
    }];
    return out;
}

BOOL RSCloudConfigure(NSDictionary *config, NSString *container, NSString *statusDir, NSString *stateDir, NSString *device) {
    if (![config isKindOfClass:NSDictionary.class] || ![config[@"appid"] respondsToSelector:@selector(unsignedIntValue)] ||
        ![config[@"rules"] isKindOfClass:NSArray.class])
        return NO;
    gConfig = config;
    gContainer = container;
    gStatusDir = statusDir;
    gStateDir = stateDir;
    gDevice = device;
    gRules = Rules();
    return YES;
}

void RSCloudSetAccount(uint64_t steamid) {
    gSteamID = steamid;
    gRules = Rules();
}

static BOOL Skipped(NSString *name) {
    return [name hasPrefix:@"."] || [name isEqualToString:@"steam_autocloud.vdf"] || [name hasSuffix:@".recomp-tmp"];
}

static BOOL Matches(RSRule *rule, NSString *rest) {
    if (!rest.length || (!rule.recursive && [rest containsString:@"/"])) return NO;
    for (NSString *part in [rest componentsSeparatedByString:@"/"])
        if (!part.length || [part isEqualToString:@".."] || Skipped(part)) return NO;
    return fnmatch(rule.pattern.UTF8String, rest.lastPathComponent.UTF8String, 0) == 0;
}

// The local path of a cloud name, nil when no rule takes it (another platform's root).
static NSString *LocalPath(NSString *name) {
    for (RSRule *rule in gRules) {
        if (rule.cloud.length) {
            if (name.length <= rule.cloud.length ||
                [name compare:rule.cloud options:NSCaseInsensitiveSearch range:NSMakeRange(0, rule.cloud.length)] != NSOrderedSame)
                continue;
            NSString *rest = [name substringFromIndex:rule.cloud.length];
            if (Matches(rule, rest)) return [rule.local stringByAppendingPathComponent:rest];
        } else if (![name hasPrefix:@"%"] && Matches(rule, name)) {
            return [rule.local stringByAppendingPathComponent:name];
        }
    }
    return nil;
}

static NSMutableDictionary<NSString *, RSLocal *> *ScanLocal(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (RSRule *rule in gRules) {
        NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtPath:rule.local];
        for (NSString *rest in e) {
            NSDictionary *a = e.fileAttributes;
            if ([a.fileType isEqualToString:NSFileTypeDirectory]) {
                if (!rule.recursive || Skipped(rest.lastPathComponent)) [e skipDescendants];
                continue;
            }
            if (![a.fileType isEqualToString:NSFileTypeRegular] || !Matches(rule, rest)) continue;
            NSString *name = [rule.cloud stringByAppendingString:rest];
            NSString *path = [rule.local stringByAppendingPathComponent:rest];
            if (out[name] || ![LocalPath(name) isEqualToString:path]) continue; // a longer rule owns it
            RSLocal *l = [[RSLocal alloc] init];
            l.path = path;
            l.mtime = a.fileModificationDate.timeIntervalSince1970;
            l.size = a.fileSize;
            out[name] = l;
        }
    }
    return out;
}

static NSString *Stamp(NSDate *d, NSString *format) {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = format;
    return [f stringFromDate:d];
}

// "<backup>/<date>/<side>/<name without the % of its root>"
static NSString *BackupPath(NSString *side, NSString *name) {
    if (!gBackup) gBackup = [BackupRoot() stringByAppendingPathComponent:Stamp(NSDate.date, @"yyyy-MM-dd HH.mm.ss")];
    return [[gBackup stringByAppendingPathComponent:side]
            stringByAppendingPathComponent:[name stringByReplacingOccurrencesOfString:@"%" withString:@""]];
}

// Writes data (or copies the file at src) to dst through a temporary file next to it, with mtime.
static BOOL Place(NSData *data, NSString *src, NSString *dst, NSTimeInterval mtime, NSMutableArray *errors) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = dst.stringByDeletingLastPathComponent;
    NSString *tmp = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.recomp-tmp", dst.lastPathComponent]];
    NSError *err = nil;
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtPath:tmp error:nil];
    BOOL ok = data ? [data writeToFile:tmp options:0 error:&err] : [fm copyItemAtPath:src toPath:tmp error:&err];
    if (!ok) {
        [errors addObject:[NSString stringWithFormat:@"writing %@: %@", dst.lastPathComponent, err.localizedDescription]];
        return NO;
    }
    if (mtime > 0) [fm setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSince1970:mtime]} ofItemAtPath:tmp error:nil];
    if (rename(tmp.fileSystemRepresentation, dst.fileSystemRepresentation) != 0) {
        [errors addObject:[NSString stringWithFormat:@"replacing %@: %s", dst.lastPathComponent, strerror(errno)]];
        [fm removeItemAtPath:tmp error:nil];
        return NO;
    }
    return YES;
}

// Moves a local file into the backup folder (instead of deleting or overwriting it).
static BOOL Keep(NSString *name, RSLocal *l, NSMutableArray *errors) {
    NSString *dst = BackupPath(gDevice, name);
    [NSFileManager.defaultManager createDirectoryAtPath:dst.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    NSError *err = nil;
    if (![NSFileManager.defaultManager copyItemAtPath:l.path toPath:dst error:&err]) {
        [errors addObject:[NSString stringWithFormat:@"backing up %@: %@", name.lastPathComponent, err.localizedDescription]];
        return NO;
    }
    return YES;
}

static NSDictionary *Record(RSCloudFile *c, NSString *path) {
    NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    return @{@"sha": RSCloudHex(c.sha), @"size": @(c.size), @"time": @(c.time),
             @"lm": @([a.fileModificationDate timeIntervalSince1970]), @"ls": @(a.fileSize)};
}

static NSMutableDictionary *LoadState(void) {
    NSMutableDictionary *s = [NSMutableDictionary dictionaryWithContentsOfFile:StatePath()] ?: [NSMutableDictionary dictionary];
    if ([s[@"steamid"] unsignedLongLongValue] != gSteamID) {
        if (s[@"steamid"]) CLOG(@"another Steam account than at the last sync: syncing as a first time");
        s = [NSMutableDictionary dictionaryWithDictionary:@{@"steamid": @(gSteamID)}];
    }
    s[@"files"] = [NSMutableDictionary dictionaryWithDictionary:s[@"files"] ?: @{}];
    return s;
}

static void SaveState(NSMutableDictionary *s) {
    [NSFileManager.defaultManager createDirectoryAtPath:gStateDir withIntermediateDirectories:YES attributes:nil error:nil];
    [s writeToFile:StatePath() atomically:YES];
}

static void WriteStatus(NSString *text) {
    [NSFileManager.defaultManager createDirectoryAtPath:gStatusDir withIntermediateDirectories:YES attributes:nil error:nil];
    [text writeToFile:StatusPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static NSString *const kHelp =
    @"\nSaves sync with Steam Cloud like the Steam client: before the game starts, Steam Cloud's newer saves come "
    @"here; while it runs and when it goes to the background, its saves go up. When a save changed both here and "
    @"in Steam Cloud since the last sync, the game asks which to keep; the other one is kept in the \"%@\" folder. "
    @"That folder also holds both sides as they were before the first sync.\n";

void RSCloudWriteOffline(NSString *why) {
    WriteStatus([NSString stringWithFormat:@"Steam Cloud saves: not synced at %@ (%@).\n\nSaves sync at the next launch "
                                           @"that reaches Steam; until then this device keeps playing with its own.\n%@",
                 Stamp(NSDate.date, @"yyyy-MM-dd HH:mm:ss"), why, [NSString stringWithFormat:kHelp, RSCloudBackupShown()]]);
}

static void WriteReport(NSString *why, RSCloudReport *r) {
    NSMutableString *t = [NSMutableString stringWithFormat:
        @"Steam Cloud saves: on (app %u).\n\nLast sync: %@ (%@): %d from Steam Cloud, %d to Steam Cloud, "
        @"%d deleted here, %d deleted in Steam Cloud.\n", RSCloudAppID(), Stamp(NSDate.date, @"yyyy-MM-dd HH:mm:ss"), why,
        r.downloaded, r.uploaded, r.deletedHere, r.deletedThere];
    if (r.waiting) [t appendFormat:@"%d changes in Steam Cloud come here at the next launch.\n", r.waiting];
    if (r.conflicts.count) {
        [t appendFormat:@"%lu saves changed both here and in Steam Cloud; they stay as they are until you choose:\n",
         (unsigned long)r.conflicts.count];
        for (RSCloudConflict *c in r.conflicts) [t appendFormat:@"  %@\n", c.name];
    }
    if (r.heldDeletes)
        [t appendString:@"Most saves are gone from this device: they were not deleted in Steam Cloud. Delete them in the "
                        @"game, a few at a time, to delete them there too.\n"];
    if (r.errors.count) [t appendFormat:@"\nErrors:\n  %@\n", [r.errors componentsJoinedByString:@"\n  "]];
    [t appendFormat:kHelp, RSCloudBackupShown()];
    WriteStatus(t);
}

static BOOL ChangedHere(RSLocal *l, NSDictionary *s, NSString **sha) {
    if (!s) return YES;
    if (fabs(l.mtime - [s[@"lm"] doubleValue]) < 0.001 && l.size == [s[@"ls"] unsignedLongLongValue]) return NO;
    NSData *d = [NSData dataWithContentsOfFile:l.path options:NSDataReadingMappedIfSafe error:nil];
    *sha = d ? RSCloudHex(RSCloudSHA1(d)) : nil;
    return ![*sha isEqualToString:s[@"sha"]];
}

RSCloudReport *RSCloudSync(NSString *why, BOOL download, BOOL settle, NSTimeInterval budget) {
    RSCloudReport *r = [[RSCloudReport alloc] init];
    r.errors = [NSMutableArray array];
    if (!gSteamID) {
        r.offline = YES;
        return r;
    }
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + budget;
    uint32_t appid = RSCloudAppID();
    NSString *err = nil;
    uint64_t change = 0;
    NSArray<RSCloudFile *> *list = RSCloudList(appid, &change, &err);
    if (!list) {
        [r.errors addObject:err];
        r.offline = YES;
        WriteReport(why, r);
        CLOG(@"%@: cannot list Steam Cloud: %@", why, err);
        return r;
    }
    NSMutableDictionary<NSString *, RSCloudFile *> *cloud = [NSMutableDictionary dictionary];
    for (RSCloudFile *c in list)
        if (LocalPath(c.name)) cloud[c.name] = c;
    NSMutableDictionary<NSString *, RSLocal *> *local = ScanLocal();
    NSMutableDictionary *state = LoadState();
    NSMutableDictionary *files = state[@"files"];
    BOOL first = !state[@"change"];
    gBackup = nil;

    // Both sides as they are, before anything moves the first time.
    NSMutableDictionary<NSString *, NSString *> *fetched = [NSMutableDictionary dictionary];
    if (first && download && (cloud.count || local.count)) {
        for (NSString *name in cloud) {
            NSData *d = RSCloudDownload(appid, name, &err);
            if (!d) {
                [r.errors addObject:err];
                err = nil;
                continue;
            }
            NSString *dst = BackupPath(@"Steam Cloud", name);
            if (Place(d, nil, dst, cloud[name].time, r.errors)) fetched[name] = dst;
        }
        for (NSString *name in local) Keep(name, local[name], r.errors);
        if (r.errors.count) {
            WriteReport(why, r);
            CLOG(@"%@: the first sync's backup failed, nothing synced", why);
            return r;
        }
        CLOG(@"%@: first sync, both sides backed up in %@", why, gBackup.lastPathComponent);
    }

    NSMutableSet *all = [NSMutableSet setWithArray:cloud.allKeys];
    [all addObjectsFromArray:local.allKeys];
    [all addObjectsFromArray:[files.allKeys filteredArrayUsingPredicate:
                              [NSPredicate predicateWithBlock:^BOOL(NSString *n, NSDictionary *b) { return LocalPath(n) != nil; }]]];
    NSMutableDictionary *uploads = [NSMutableDictionary dictionary], *times = [NSMutableDictionary dictionary];
    NSMutableArray *deletes = [NSMutableArray array], *conflicts = [NSMutableArray array];
    for (NSString *name in [all.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
        if (CFAbsoluteTimeGetCurrent() > deadline) {
            r.waiting++;
            continue;
        }
        @autoreleasepool {
            RSCloudFile *c = cloud[name];
            RSLocal *l = local[name];
            NSDictionary *s = files[name];
            NSString *sha = nil;
            if (l && settle && NSDate.date.timeIntervalSince1970 - l.mtime < kSettling) continue; // next round
            BOOL lChanged = l ? ChangedHere(l, s, &sha) : s != nil;
            BOOL cChanged = c ? !s || ![RSCloudHex(c.sha) isEqualToString:s[@"sha"]] : s != nil;
            if (c && l && !sha) {
                // Not hashed yet: unchanged since the last sync, or never synced.
                NSData *d = lChanged ? [NSData dataWithContentsOfFile:l.path options:NSDataReadingMappedIfSafe error:nil] : nil;
                sha = lChanged ? (d ? RSCloudHex(RSCloudSHA1(d)) : nil) : s[@"sha"];
            }
            if (c && l && [sha isEqualToString:RSCloudHex(c.sha)]) {
                files[name] = Record(c, l.path); // the same bytes on both sides
                continue;
            }
            if (!c && !l) {
                [files removeObjectForKey:name];
                continue;
            }
            if (!lChanged && !cChanged) continue;
            if (lChanged && cChanged) {
                RSCloudConflict *k = [[RSCloudConflict alloc] init];
                k.name = name;
                k.cloud = c;
                k.localTime = l ? l.mtime : 0;
                [conflicts addObject:k];
                continue;
            }
            if (cChanged) {
                if (!download) {
                    r.waiting++;
                } else if (c) {
                    NSString *path = LocalPath(name);
                    NSData *d = fetched[name] ? nil : RSCloudDownload(appid, name, &err);
                    if (!d && !fetched[name]) {
                        [r.errors addObject:err];
                        err = nil;
                    } else if (Place(d, fetched[name], path, c.time, r.errors)) {
                        files[name] = Record(c, path);
                        r.downloaded++;
                    }
                } else if (Keep(name, l, r.errors)) { // deleted in Steam Cloud
                    [NSFileManager.defaultManager removeItemAtPath:l.path error:nil];
                    [files removeObjectForKey:name];
                    r.deletedHere++;
                }
            } else if (l) {
                uploads[name] = l.path;
                times[name] = @((uint64_t)l.mtime);
            } else {
                [deletes addObject:name]; // deleted here
            }
        }
    }

    if (deletes.count > 3 && deletes.count * 2 > cloud.count) {
        CLOG(@"%@: %lu of %lu cloud files are gone here: not deleting them in Steam Cloud", why,
             (unsigned long)deletes.count, (unsigned long)cloud.count);
        r.heldDeletes = YES;
        [deletes removeAllObjects];
    }
    if (uploads.count || deletes.count) {
        if (RSCloudCommit(appid, gDevice, uploads, times, deletes, &err)) {
            for (NSString *name in uploads) {
                RSCloudFile *c = [[RSCloudFile alloc] init];
                NSData *d = [NSData dataWithContentsOfFile:uploads[name] options:NSDataReadingMappedIfSafe error:nil];
                c.sha = RSCloudSHA1(d ?: [NSData data]);
                c.size = d.length;
                c.time = [times[name] unsignedLongLongValue];
                files[name] = Record(c, uploads[name]);
            }
            for (NSString *name in deletes) [files removeObjectForKey:name];
            r.uploaded = (int)uploads.count;
            r.deletedThere = (int)deletes.count;
        } else {
            [r.errors addObject:err];
        }
    }
    r.conflicts = conflicts;
    if (download || !first) state[@"change"] = @(change); // the first download pass still backs up
    state[@"last"] = NSDate.date;
    SaveState(state);
    WriteReport(why, r);
    CLOG(@"%@: %d from Steam Cloud, %d to Steam Cloud, %d deleted here, %d deleted there, %lu conflicts, %d waiting, %lu errors",
         why, r.downloaded, r.uploaded, r.deletedHere, r.deletedThere, (unsigned long)conflicts.count, r.waiting,
         (unsigned long)r.errors.count);
    for (NSString *e in r.errors) CLOG(@"  %@", e);
    return r;
}

RSCloudReport *RSCloudResolve(NSArray<RSCloudConflict *> *conflicts, BOOL keepCloud) {
    RSCloudReport *r = [[RSCloudReport alloc] init];
    r.errors = [NSMutableArray array];
    uint32_t appid = RSCloudAppID();
    NSMutableDictionary *state = LoadState();
    NSMutableDictionary *files = state[@"files"];
    NSMutableDictionary *local = ScanLocal();
    NSMutableDictionary *uploads = [NSMutableDictionary dictionary], *times = [NSMutableDictionary dictionary];
    NSMutableArray *deletes = [NSMutableArray array];
    NSString *err = nil;
    gBackup = nil;
    for (RSCloudConflict *k in conflicts) {
        RSLocal *l = local[k.name];
        if (keepCloud) {
            if (l && !Keep(k.name, l, r.errors)) continue; // never overwrite what could not be kept
            if (k.cloud) {
                NSData *d = RSCloudDownload(appid, k.name, &err);
                if (!d) {
                    [r.errors addObject:err];
                    err = nil;
                } else if (Place(d, nil, LocalPath(k.name), k.cloud.time, r.errors)) {
                    files[k.name] = Record(k.cloud, LocalPath(k.name));
                    r.downloaded++;
                }
            } else if (l) {
                [NSFileManager.defaultManager removeItemAtPath:l.path error:nil];
                [files removeObjectForKey:k.name];
                r.deletedHere++;
            }
        } else {
            if (k.cloud) { // Steam Cloud's version goes to the backup folder first
                NSData *d = RSCloudDownload(appid, k.name, &err);
                if (!d || !Place(d, nil, BackupPath(@"Steam Cloud", k.name), k.cloud.time, r.errors)) {
                    if (err) [r.errors addObject:err];
                    err = nil;
                    continue;
                }
            }
            if (l) {
                uploads[k.name] = l.path;
                times[k.name] = @((uint64_t)l.mtime);
            } else {
                [deletes addObject:k.name];
            }
        }
    }
    if ((uploads.count || deletes.count) && RSCloudCommit(appid, gDevice, uploads, times, deletes, &err)) {
        for (NSString *name in uploads) {
            RSCloudFile *c = [[RSCloudFile alloc] init];
            NSData *d = [NSData dataWithContentsOfFile:uploads[name] options:NSDataReadingMappedIfSafe error:nil];
            c.sha = RSCloudSHA1(d ?: [NSData data]);
            c.size = d.length;
            c.time = [times[name] unsignedLongLongValue];
            files[name] = Record(c, uploads[name]);
        }
        for (NSString *name in deletes) [files removeObjectForKey:name];
        r.uploaded = (int)uploads.count;
        r.deletedThere = (int)deletes.count;
    } else if (err) {
        [r.errors addObject:err];
    }
    SaveState(state);
    NSString *why = keepCloud ? @"conflict, Steam Cloud kept" : [NSString stringWithFormat:@"conflict, %@ kept", gDevice];
    WriteReport(why, r);
    CLOG(@"%@: %d from Steam Cloud, %d to Steam Cloud, %lu errors", why, r.downloaded, r.uploaded, (unsigned long)r.errors.count);
    return r;
}
