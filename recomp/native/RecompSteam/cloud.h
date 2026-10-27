// Steam Cloud, shared by the cloud*.m files: the Cloud service (cloud_protocol.m), the
// sync with local folders (cloud_sync.m), ISteamRemoteStorage on a folder
// (cloud_remotestorage.m) and the hooks into the game's life (cloud_launch.m).
//
// Steam Cloud names a file by its Auto-Cloud root and path ("%WinMyDocuments%Timberborn/
// Saves/a.timber") or, for what a game writes through ISteamRemoteStorage, by the bare
// name it gave ("characters/x.fch"). Each app has a change number that grows with
// every upload batch.
#import <Foundation/Foundation.h>

#define CLOG(fmt, ...) RecompSteam_Log("cloud: %s", [[NSString stringWithFormat:fmt, ##__VA_ARGS__] UTF8String])

// --- cloud_protocol.m: the Cloud service --------------------------------------------
// Synchronous: call from a queue of your own, never the session's or the main one.

@interface RSCloudFile : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSData *sha;        // SHA-1 of the raw file
@property (nonatomic) uint64_t size, time;      // raw size; Unix time of its last change
@property (nonatomic, copy) NSString *machine;  // what last uploaded it, when Steam says
@end

// Every file Steam Cloud holds for the app (deleted and forgotten ones left out).
NSArray<RSCloudFile *> *RSCloudList(uint32_t appid, uint64_t *change, NSString **error);
// One file's raw bytes, unzipped and checked against its SHA-1.
NSData *RSCloudDownload(uint32_t appid, NSString *name, NSString **error);
// One upload batch: uploads (name -> file path, with its time) and deletes.
BOOL RSCloudCommit(uint32_t appid, NSString *machine, NSDictionary<NSString *, NSString *> *uploads,
                   NSDictionary<NSString *, NSNumber *> *times, NSArray<NSString *> *deletes, NSString **error);
NSData *RSCloudSHA1(NSData *data);
NSString *RSCloudHex(NSData *data);

// --- cloud_sync.m: the sync -------------------------------------------------------------

@interface RSCloudConflict : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) RSCloudFile *cloud;   // nil: deleted in Steam Cloud
@property (nonatomic) NSTimeInterval localTime;     // 0: deleted here
@end

@interface RSCloudReport : NSObject
@property (nonatomic) int downloaded, uploaded, deletedHere, deletedThere, waiting;
@property (nonatomic, strong) NSMutableArray<NSString *> *errors;
@property (nonatomic, strong) NSArray<RSCloudConflict *> *conflicts;
@property (nonatomic) BOOL offline, heldDeletes;
@end

// Info.plist RecompSteamCloud; container is the folder relative "local" rules start from.
BOOL RSCloudConfigure(NSDictionary *config, NSString *container, NSString *statusDir, NSString *stateDir,
                      NSString *device);
uint32_t RSCloudAppID(void);
NSString *RSCloudRemoteFolder(void);            // where ISteamRemoteStorage keeps its files
uint64_t RSCloudQuota(void);
// The account's {64BitSteamID}; the sync does nothing before it is known.
void RSCloudSetAccount(uint64_t steamid);
// One pass. With download, cloud changes come here (only while the game has not read its
// saves: at launch); without, only this device's changes go up. Conflicts are reported,
// never resolved here. settle skips files changed in the last seconds (half written).
RSCloudReport *RSCloudSync(NSString *why, BOOL download, BOOL settle, NSTimeInterval budget);
// The player's answer to a conflict: YES keeps Steam Cloud's version, NO this device's. The
// version not kept goes to the backup folder first.
RSCloudReport *RSCloudResolve(NSArray<RSCloudConflict *> *conflicts, BOOL keepCloud);
void RSCloudWriteOffline(NSString *why);

// --- cloud_launch.m ----------------------------------------------------------------------
// Waits (at most until 15 s after the launch) for the launch pass to bring Steam Cloud's saves
// down. SteamAPI_Init and ISteamRemoteStorage call it, from the game's threads; a no-op outside
// steam mode and once the pass is done.
void RSCloudWaitForLaunch(void);
// Non-blocking: runs done once the first sync of this run (the launch's, or the one after the
// first sign-in) is done, at once outside steam mode, after 60 s at most. RecompLicense.m keeps
// its cover over the game until then (found with dlsym).
void RSCloudWhenSynced(void (^done)(void));
NSString *RSCloudBackupShown(void);
