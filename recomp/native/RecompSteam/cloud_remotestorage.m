// ISteamRemoteStorage's file calls on a folder, as the Steam client keeps them in
// userdata/<account>/<app>/remote/: a game reads and writes its cloud files there, and
// cloud_sync.m syncs the folder with Steam Cloud (its files are the cloud names with no
// root). The folder is the "" rule of Info.plist RecompSteamCloud; without it (saves not
// in steam mode) the account and app report Steam Cloud off, and the calls fail, as the
// generated stubs did.
//
// Asynchronous and UGC calls (FileWriteAsync, FileReadAsync, FileShare, the UGC ones)
// stay generated stubs: no tested game needs them.
#import "cloud.h"
#import "RecompSteamSession.h"

static NSArray<NSString *> *gListed;
static NSMutableArray<NSData *> *gListedC;      // GetFileNameAndSize's C strings, valid until the next GetFileCount
static NSMutableDictionary<NSNumber *, NSMutableData *> *gStreams;
static NSMutableDictionary<NSNumber *, NSString *> *gStreamNames;
static uint64_t gNextStream = 1;
static BOOL gAppEnabled = YES;

static NSString *Path(const char *name) {
    NSString *root = RSCloudRemoteFolder();
    if (!root || !name || !name[0]) return nil;
    NSString *n = [[NSString stringWithUTF8String:name] stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    if ([n hasPrefix:@"/"] || [n hasPrefix:@"%"]) return nil;
    for (NSString *part in [n componentsSeparatedByString:@"/"])
        if ([part isEqualToString:@".."]) return nil;
    return [root stringByAppendingPathComponent:n];
}

static BOOL Write(NSString *path, NSData *data) {
    if (!path) return NO;
    NSString *dir = path.stringByDeletingLastPathComponent;
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSError *err = nil;
    if ([data writeToFile:path options:NSDataWritingAtomic error:&err]) return YES;
    CLOG(@"remote storage: cannot write %@: %@", path.lastPathComponent, err.localizedDescription);
    return NO;
}

static NSArray<NSString *> *Files(uint64_t *bytes) {
    NSString *root = RSCloudRemoteFolder();
    NSMutableArray *out = [NSMutableArray array];
    uint64_t total = 0;
    NSDirectoryEnumerator *e = root ? [NSFileManager.defaultManager enumeratorAtPath:root] : nil;
    for (NSString *rel in e) {
        if ([rel.lastPathComponent hasPrefix:@"."]) {
            if ([e.fileAttributes.fileType isEqualToString:NSFileTypeDirectory]) [e skipDescendants];
            continue;
        }
        if (![e.fileAttributes.fileType isEqualToString:NSFileTypeRegular]) continue;
        [out addObject:rel];
        total += e.fileAttributes.fileSize;
    }
    if (bytes) *bytes = total;
    return [out sortedArrayUsingSelector:@selector(compare:)];
}

__attribute__((used)) bool SteamAPI_ISteamRemoteStorage_FileWrite(void *self, const char *name, const void *data, int32_t size) {
    if (size < 0 || (!data && size)) return false;
    @synchronized(NSFileManager.class) { return Write(Path(name), [NSData dataWithBytes:data length:(NSUInteger)size]); }
}

__attribute__((used)) int32_t SteamAPI_ISteamRemoteStorage_FileRead(void *self, const char *name, void *data, int32_t size) {
    NSString *path = Path(name);
    if (!path || size <= 0 || !data) return 0;
    @synchronized(NSFileManager.class) {
        NSData *d = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
        int32_t n = (int32_t)MIN((NSUInteger)size, d.length);
        if (n > 0) memcpy(data, d.bytes, (size_t)n);
        return n;
    }
}

__attribute__((used)) bool SteamAPI_ISteamRemoteStorage_FileExists(void *self, const char *name) {
    NSString *path = Path(name);
    return path && [NSFileManager.defaultManager fileExistsAtPath:path];
}

__attribute__((used)) bool SteamAPI_ISteamRemoteStorage_FilePersisted(void *self, const char *name) {
    return SteamAPI_ISteamRemoteStorage_FileExists(self, name);
}

__attribute__((used)) bool SteamAPI_ISteamRemoteStorage_FileDelete(void *self, const char *name) {
    NSString *path = Path(name);
    @synchronized(NSFileManager.class) { return path && [NSFileManager.defaultManager removeItemAtPath:path error:nil]; }
}

// Forget: Steam stops syncing the file but leaves it on disk; here it stays and syncs.
__attribute__((used)) bool SteamAPI_ISteamRemoteStorage_FileForget(void *self, const char *name) {
    return SteamAPI_ISteamRemoteStorage_FileExists(self, name);
}

__attribute__((used)) int32_t SteamAPI_ISteamRemoteStorage_GetFileSize(void *self, const char *name) {
    NSString *path = Path(name);
    return path ? (int32_t)[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileSize : 0;
}

__attribute__((used)) int64_t SteamAPI_ISteamRemoteStorage_GetFileTimestamp(void *self, const char *name) {
    NSString *path = Path(name);
    return path ? (int64_t)[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileModificationDate.timeIntervalSince1970 : 0;
}

// ERemoteStoragePlatform: every platform.
__attribute__((used)) int32_t SteamAPI_ISteamRemoteStorage_GetSyncPlatforms(void *self, const char *name) {
    return SteamAPI_ISteamRemoteStorage_FileExists(self, name) ? -1 : 0;
}

__attribute__((used)) bool SteamAPI_ISteamRemoteStorage_SetSyncPlatforms(void *self, const char *name, int32_t platforms) {
    return SteamAPI_ISteamRemoteStorage_FileExists(self, name);
}

__attribute__((used)) int32_t SteamAPI_ISteamRemoteStorage_GetFileCount(void *self) {
    @synchronized(NSFileManager.class) {
        gListed = Files(NULL);
        gListedC = [NSMutableArray array];
        for (NSString *n in gListed) [gListedC addObject:[NSData dataWithBytes:n.UTF8String length:strlen(n.UTF8String) + 1]];
        return (int32_t)gListed.count;
    }
}

__attribute__((used)) const char *SteamAPI_ISteamRemoteStorage_GetFileNameAndSize(void *self, int index, int32_t *size) {
    @synchronized(NSFileManager.class) {
        if (!gListed) SteamAPI_ISteamRemoteStorage_GetFileCount(self);
        if (index < 0 || (NSUInteger)index >= gListed.count) {
            if (size) *size = 0;
            return "";
        }
        if (size) *size = SteamAPI_ISteamRemoteStorage_GetFileSize(self, gListed[index].UTF8String);
        return gListedC[index].bytes;
    }
}

__attribute__((used)) bool SteamAPI_ISteamRemoteStorage_GetQuota(void *self, uint64_t *total, uint64_t *available) {
    if (!RSCloudRemoteFolder()) return false;
    uint64_t used = 0, quota = RSCloudQuota() ?: 1000000000ull;
    Files(&used);
    if (total) *total = quota;
    if (available) *available = used < quota ? quota - used : 0;
    return true;
}

__attribute__((used)) bool SteamAPI_ISteamRemoteStorage_IsCloudEnabledForAccount(void *self) {
    return RSCloudRemoteFolder() != nil;
}

__attribute__((used)) bool SteamAPI_ISteamRemoteStorage_IsCloudEnabledForApp(void *self) {
    return RSCloudRemoteFolder() != nil && gAppEnabled;
}

__attribute__((used)) void SteamAPI_ISteamRemoteStorage_SetCloudEnabledForApp(void *self, bool enabled) {
    gAppEnabled = enabled;
}

__attribute__((used)) bool SteamAPI_ISteamRemoteStorage_BeginFileWriteBatch(void *self) { return true; }
__attribute__((used)) bool SteamAPI_ISteamRemoteStorage_EndFileWriteBatch(void *self) { return true; }

// Streams: the bytes gather in memory and are written at Close, as Steam writes them.
__attribute__((used)) uint64_t SteamAPI_ISteamRemoteStorage_FileWriteStreamOpen(void *self, const char *name) {
    if (!Path(name)) return 0;
    @synchronized(NSFileManager.class) {
        if (!gStreams) gStreams = [NSMutableDictionary dictionary], gStreamNames = [NSMutableDictionary dictionary];
        uint64_t h = gNextStream++;
        gStreams[@(h)] = [NSMutableData data];
        gStreamNames[@(h)] = [NSString stringWithUTF8String:name];
        return h;
    }
}

__attribute__((used)) bool SteamAPI_ISteamRemoteStorage_FileWriteStreamWriteChunk(void *self, uint64_t handle, const void *data, int32_t size) {
    @synchronized(NSFileManager.class) {
        NSMutableData *d = gStreams[@(handle)];
        if (!d || size < 0 || (!data && size)) return false;
        [d appendBytes:data length:(NSUInteger)size];
        return true;
    }
}

__attribute__((used)) bool SteamAPI_ISteamRemoteStorage_FileWriteStreamClose(void *self, uint64_t handle) {
    @synchronized(NSFileManager.class) {
        NSMutableData *d = gStreams[@(handle)];
        if (!d) return false;
        NSString *name = gStreamNames[@(handle)];
        [gStreams removeObjectForKey:@(handle)];
        [gStreamNames removeObjectForKey:@(handle)];
        return Write(Path(name.UTF8String), d);
    }
}

__attribute__((used)) bool SteamAPI_ISteamRemoteStorage_FileWriteStreamCancel(void *self, uint64_t handle) {
    @synchronized(NSFileManager.class) {
        BOOL had = gStreams[@(handle)] != nil;
        [gStreams removeObjectForKey:@(handle)];
        [gStreamNames removeObjectForKey:@(handle)];
        return had;
    }
}
