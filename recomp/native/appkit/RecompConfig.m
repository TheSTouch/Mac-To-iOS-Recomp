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
// Engine.ini keys are workarounds: they are rewritten at every launch, in case
// the game saved over them. Every other file's keys are defaults the player may
// change in the game: one is written only when the file lacks it or the
// profile's value changed since the shim last wrote it, which <Name>.ini.recomp
// (next to the .ini) remembers.
//
// The value "auto" for r.Streaming.PoolSize sizes the texture pool from the
// device's RAM: Mac builds size it for a GPU with its own memory, while an
// iOS device's GPU shares RAM with the game and the system.
//
// "auto" for ApplicationScale ([/Script/Engine.UserInterfaceSettings]) keeps
// UMG's layout whole on a short screen. UE4's default DPI curve scales the UI
// by the viewport's short side over 1080, so every layout has 1080 units of
// height, but the curve stops at 480: below it (a phone's 375-430 points) the
// UI keeps the 480 scale, has fewer than 1080 units, and menus laid out for
// 1080 pile up (Stray's title menu became one line). Short side / 480 makes up
// the difference.
//
// A file named recomp-ini in Documents lays test settings over all of these, for
// trying engine settings with a relaunch instead of a rebuild:
//   [Engine:SystemSettings]
//   r.Shadow.CSM.MaxCascades=2
//   [GameUserSettings:/Script/Hk_project.HKGameUserSettings]
//   FrameRateLimit=0.000000
// Its keys are written at every launch; a key taken out of it is taken out of the
// game's .ini at the next launch (or set back to the profile's value), so a test
// never lingers. Documents/recomp-ini.applied remembers which keys it wrote.
//
// "auto" for ResolutionSizeX/Y and LastUserConfirmedResolutionSizeX/Y is the
// largest display mode the shim offers on this device (RecompDisplay.m), so a
// profile can ask for the sharpest output without knowing the screen size.
#import "RecompAppKit.h"

static NSString *Resolve(NSString *key, NSString *value) {
    if (![value isEqualToString:@"auto"]) return value;
    if ([key isEqualToString:@"r.Streaming.PoolSize"]) {
        unsigned long long mb = NSProcessInfo.processInfo.physicalMemory >> 20;
        return [NSString stringWithFormat:@"%llu", MIN(MAX(mb * 15 / 100, 600ULL), 3000ULL)];
    }
    if ([key hasSuffix:@"ResolutionSizeX"] || [key hasSuffix:@"ResolutionSizeY"]) {
        CGSize m = RecompLargestModeSize();
        return [NSString stringWithFormat:@"%.0f", [key hasSuffix:@"X"] ? m.width : m.height];
    }
    if ([key isEqualToString:@"ApplicationScale"]) {
        CGSize s = UIScreen.mainScreen.bounds.size;
        return [NSString stringWithFormat:@"%.4f", MIN(MIN(s.width, s.height) / 480.0, 1.0)];
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

// Writes the sections' keys into the .ini at path. forced: every key; otherwise
// only missing keys and keys whose wanted value changed since the last write.
// Adds the lines written to written, and the player's lines left alone to kept.
static void Merge(NSString *path, NSDictionary<NSString *, NSDictionary *> *sections, BOOL forced,
                  NSMutableArray *written, NSMutableArray *kept) {
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSMutableArray<NSString *> *lines = [[text componentsSeparatedByString:@"\n"] mutableCopy];
    NSString *sidecar = [path stringByAppendingPathExtension:@"recomp"];
    NSDictionary *last = forced ? nil : [NSDictionary dictionaryWithContentsOfFile:sidecar];
    NSMutableDictionary *wrote = [NSMutableDictionary new];
    for (NSString *section in sections) {
        NSString *header = [NSString stringWithFormat:@"[%@]", section];
        NSUInteger start = [lines indexOfObject:header];
        if (start == NSNotFound) {
            if (lines.count && [lines.lastObject length]) [lines addObject:@""];
            [lines addObject:header];
            start = lines.count - 1;
        }
        NSDictionary *keys = sections[section];
        NSMutableDictionary *wroteHere = [NSMutableDictionary new];
        for (NSString *key in keys) {
            NSString *want = Resolve(key, keys[key]);
            NSString *prefix = [key stringByAppendingString:@"="];
            NSUInteger i = start + 1, found = NSNotFound;
            for (; i < lines.count && ![lines[i] hasPrefix:@"["]; i++)
                if ([lines[i] hasPrefix:prefix]) found = i;
            wroteHere[key] = want;
            if (!forced && found != NSNotFound && [last[section][key] isEqualToString:want]) {
                [kept addObject:lines[found]];
                continue;
            }
            NSString *line = [prefix stringByAppendingString:want];
            if (found != NSNotFound) lines[found] = line;
            else [lines insertObject:line atIndex:start + 1];
            [written addObject:line];
        }
        wrote[section] = wroteHere;
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [[lines componentsJoinedByString:@"\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (!forced) [wrote writeToFile:sidecar atomically:YES];
}

// Documents/recomp-ini as {file name: {section: {key: value}}}.
static NSDictionary *TestSettings(NSString *path) {
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSMutableDictionary *files = [NSMutableDictionary new];
    NSMutableDictionary *keys;
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!line.length || [line hasPrefix:@";"] || [line hasPrefix:@"#"]) continue;
        if ([line hasPrefix:@"["] && [line hasSuffix:@"]"]) {
            NSString *inner = [line substringWithRange:NSMakeRange(1, line.length - 2)];
            NSRange colon = [inner rangeOfString:@":"];
            keys = nil;
            if (colon.location == NSNotFound) continue;
            NSString *file = [inner substringToIndex:colon.location], *section = [inner substringFromIndex:colon.location + 1];
            if (!files[file]) files[file] = [NSMutableDictionary new];
            keys = files[file][section] ?: [NSMutableDictionary new];
            files[file][section] = keys;
            continue;
        }
        NSRange eq = [line rangeOfString:@"="];
        if (keys && eq.location != NSNotFound && eq.location > 0)
            keys[[line substringToIndex:eq.location]] = [line substringFromIndex:eq.location + 1];
    }
    return files;
}

// Takes the given keys ({section: [key]}) out of the .ini at path.
static void RemoveKeys(NSString *path, NSDictionary<NSString *, NSArray *> *sections, NSMutableArray *removed) {
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text) return;
    NSMutableArray<NSString *> *lines = [[text componentsSeparatedByString:@"\n"] mutableCopy];
    NSString *section = nil;
    for (NSUInteger i = 0; i < lines.count;) {
        NSString *line = lines[i];
        if ([line hasPrefix:@"["]) section = [line substringWithRange:NSMakeRange(1, MAX(line.length, 2) - 2)];
        NSRange eq = [line rangeOfString:@"="];
        if (section && eq.location != NSNotFound && [sections[section] containsObject:[line substringToIndex:eq.location]]) {
            [removed addObject:line];
            [lines removeObjectAtIndex:i];
            continue;
        }
        i++;
    }
    if (removed.count) [[lines componentsJoinedByString:@"\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

__attribute__((constructor)) static void RecompConfigInit(void) {
    @autoreleasepool {
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        NSString *dir = info[@"RecompConfigDir"];
        NSDictionary *files = info[@"RecompIniOverrides"];
        // RECOMP_IDIOM=phone in the environment applies the phone set elsewhere,
        // e.g. on a Mac running the iOS build, to measure what an iPhone gets.
        const char *idiom = getenv("RECOMP_IDIOM");
        BOOL phone = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone ||
                     (idiom && !strcmp(idiom, "phone"));
        NSDictionary *phoneFiles = phone ? info[@"RecompIniOverridesPhone"] : nil;
        if (!dir) return;
        dir = [NSHomeDirectory() stringByAppendingPathComponent:dir];
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *appliedPath = [docs stringByAppendingPathComponent:@"recomp-ini.applied"];
        NSDictionary *tests = TestSettings([docs stringByAppendingPathComponent:@"recomp-ini"]);
        NSDictionary *applied = [NSDictionary dictionaryWithContentsOfFile:appliedPath];
        NSMutableSet *names = [NSMutableSet setWithArray:[files allKeys]];
        [names addObjectsFromArray:[phoneFiles allKeys]];
        [names addObjectsFromArray:[tests allKeys]];
        [names addObjectsFromArray:[applied allKeys]];
        NSString *set = phoneFiles ? @"iPhone settings over the base" : @"base settings";
        NSMutableDictionary *nowApplied = [NSMutableDictionary new];
        for (NSString *name in names) {
            NSString *path = [dir stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"ini"]];
            NSDictionary *profile = Overlay(files[name], phoneFiles[name]);
            // Keys an earlier test wrote that neither the test nor the profile names now.
            NSMutableDictionary *stale = [NSMutableDictionary new];
            for (NSString *section in applied[name])
                for (NSString *key in applied[name][section])
                    if (!tests[name][section][key] && !profile[section][key])
                        stale[section] = [(stale[section] ?: @[]) arrayByAddingObject:key];
            NSMutableArray *removed = [NSMutableArray new];
            RemoveKeys(path, stale, removed);
            if (removed.count) RLOG(@"config: %@.ini: test settings taken out: %@", name, [removed componentsJoinedByString:@", "]);
            NSMutableDictionary *testKeys = [NSMutableDictionary new];
            for (NSString *section in tests[name]) testKeys[section] = [tests[name][section] allKeys];
            if (testKeys.count) nowApplied[name] = testKeys;
            NSDictionary *sections = Overlay(profile, tests[name]);
            if (![sections count]) continue;
            BOOL forced = [name isEqualToString:@"Engine"] || tests[name];
            NSMutableArray *written = [NSMutableArray new], *kept = [NSMutableArray new];
            Merge(path, sections, forced, written, kept);
            RLOG(@"config: %@.ini (%@): %@ %@%@%@", name, set, forced ? @"forced" : @"defaults written:",
                 written.count ? [written componentsJoinedByString:@", "] : @"none",
                 kept.count ? @"; left as the player set them: " : @"", [kept componentsJoinedByString:@", "]);
            if (tests[name]) RLOG(@"config: %@.ini: test settings from Documents/recomp-ini: %@", name, tests[name]);
        }
        [nowApplied writeToFile:appliedPath atomically:YES];
    }
}
