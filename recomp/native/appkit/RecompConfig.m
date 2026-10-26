// Per-game engine settings (the "engine_ini" and "game_user_settings_ini" of a
// recomp profile), merged into the game's user config files (Engine.ini,
// GameUserSettings.ini) before the engine starts. Unreal reads
// <user config dir>/<Name>.ini over the settings in its paks, so a [Section]
// key written here wins.
//
// On an iPhone, RecompIniOverridesPhone (the profile's "iphone" block over the
// generic phone defaults, see unreal_ios.py) is laid over RecompIniOverrides key
// by key: phone values win, base keys it does not name are kept.
//
// Keys are rewritten at every launch, in case the game saved over them.
//
// The value "auto" for r.Streaming.PoolSize sizes the texture pool from the
// device's RAM: Mac builds size it for a GPU with its own memory, while an
// iPad's GPU shares RAM with the game and the system.
#import "RecompAppKit.h"

static NSString *Resolve(NSString *key, NSString *value) {
    if (![value isEqualToString:@"auto"]) return value;
    if ([key isEqualToString:@"r.Streaming.PoolSize"]) {
        unsigned long long mb = NSProcessInfo.processInfo.physicalMemory >> 20;
        return [NSString stringWithFormat:@"%llu", MIN(MAX(mb * 15 / 100, 600ULL), 3000ULL)];
    }
    return value;
}

// base with over's keys laid on top, section by section.
static NSDictionary *Overlay(NSDictionary *base, NSDictionary *over) {
    NSMutableDictionary *out = [base mutableCopy] ?: [NSMutableDictionary new];
    for (NSString *section in over) {
        NSMutableDictionary *keys = [out[section] mutableCopy] ?: [NSMutableDictionary new];
        [keys addEntriesFromDictionary:over[section]];
        out[section] = keys;
    }
    return out;
}

static void Merge(NSString *path, NSDictionary<NSString *, NSDictionary *> *sections) {
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSMutableArray<NSString *> *lines = [[text componentsSeparatedByString:@"\n"] mutableCopy];
    for (NSString *section in sections) {
        NSString *header = [NSString stringWithFormat:@"[%@]", section];
        NSUInteger start = [lines indexOfObject:header];
        if (start == NSNotFound) {
            if (lines.count && [lines.lastObject length]) [lines addObject:@""];
            [lines addObject:header];
            start = lines.count - 1;
        }
        NSDictionary *keys = sections[section];
        for (NSString *key in keys) {
            NSString *line = [NSString stringWithFormat:@"%@=%@", key, Resolve(key, keys[key])];
            NSUInteger i = start + 1, found = NSNotFound;
            for (; i < lines.count && ![lines[i] hasPrefix:@"["]; i++)
                if ([lines[i] hasPrefix:[key stringByAppendingString:@"="]]) found = i;
            if (found != NSNotFound) lines[found] = line;
            else [lines insertObject:line atIndex:start + 1];
        }
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [[lines componentsJoinedByString:@"\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

__attribute__((constructor)) static void RecompConfigInit(void) {
    @autoreleasepool {
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        NSString *dir = info[@"RecompConfigDir"];
        NSDictionary *files = info[@"RecompIniOverrides"];
        BOOL phone = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone;
        NSDictionary *phoneFiles = phone ? info[@"RecompIniOverridesPhone"] : nil;
        if (!dir) return;
        dir = [NSHomeDirectory() stringByAppendingPathComponent:dir];
        NSMutableSet *names = [NSMutableSet setWithArray:[files allKeys]];
        [names addObjectsFromArray:[phoneFiles allKeys]];
        NSString *set = phoneFiles ? @"iPhone settings over the base" : @"base settings";
        for (NSString *name in names) {
            NSDictionary *sections = Overlay(files[name], phoneFiles[name]);
            if (![sections count]) continue;
            Merge([dir stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"ini"]], sections);
            NSMutableArray *applied = [NSMutableArray new];
            for (NSString *sec in sections)
                for (NSString *k in sections[sec]) [applied addObject:[NSString stringWithFormat:@"%@=%@", k, Resolve(k, sections[sec][k])]];
            RLOG(@"config: %@.ini (%@): %@", name, set, [applied componentsJoinedByString:@", "]);
        }
    }
}
