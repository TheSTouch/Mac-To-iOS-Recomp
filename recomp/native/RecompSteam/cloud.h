// Steam Cloud, shared by the cloud*.m files here: the sync with local folders (cloud_sync.m),
// ISteamRemoteStorage on a folder (cloud_remotestorage.m) and the hooks into the game's life
// (cloud_launch.m). The Cloud service they build on (list, download, upload) is Kettle's
// RecompSteamCloud.h and cloud_protocol.m (recomp/vendor/kettle).
#import "RecompSteamCloud.h"

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
// saves: at launch); with upload, this device's changes go up (the launch leaves them to the
// next pass, so the game does not wait for them). Conflicts are reported, never resolved
// here. settle skips files changed in the last seconds (half written).
RSCloudReport *RSCloudSync(NSString *why, BOOL download, BOOL upload, BOOL settle, NSTimeInterval budget);
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
