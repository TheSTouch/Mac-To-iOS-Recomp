import Foundation

/// One game as reported by `recomp.py scan --json` (tools/inspect_app.py + discover.py).
struct Game: Decodable, Identifiable, Hashable {
    let app: String
    let name: String
    let bundleId: String?
    let engine: String
    let engineBackend: String?
    let archs: [String]
    let macOnlyFrameworks: [String]
    let flags: [String]
    let routes: [String]
    let source: String
    /// "unity" or "unreal" when one of the port routes handles the game.
    let route: String?
    let status: String
    let statusDetail: String
    /// What decided a tested / untested / needs-work status (recomp/compat.py).
    let checks: [String]
    /// The game's profile has a saves block: its saves can sync with the iOS port through iCloud Drive.
    let saves: Bool?
    /// A Steam game with Steam Cloud: its port syncs saves with Steam Cloud by default (recomp/steam_cloud.py).
    let steamCloud: Bool?
    /// The game's profile says where its mods live: the port can compile them in (recomp/mods.py).
    let mods: Bool?
    /// What the game's profile records for each kind of device, nil where it was not played on one
    /// yet ("tested" and "tested_iphone"); only for games a route handles.
    let testedIpad: String?
    let testedIphone: String?

    var id: String { app }
    var support: Support { Support(rawValue: status) ?? .planned }
    var engineLabel: String { engineBackend.map { "\(engine) (\($0))" } ?? engine }
    var slug: String { name.filter { $0.isLetter || $0.isNumber } }
    /// The port's save sync unless the player picks another: `--saves` of recomp.py.
    var defaultSaves: String { steamCloud == true ? "steam" : saves == true ? "icloud" : "off" }

    var iphoneStatus: String { testedIphone.map { "Tested on iPhone: \($0)" } ?? "Not tried on iPhone yet" }
    /// The list's one-line summary per device, e.g. "Tested on iPad · not tried on iPhone yet".
    var devicesSummary: String {
        [testedIpad == nil ? nil : "Tested on iPad",
         testedIphone == nil ? "not tried on iPhone yet" : "Tested on iPhone"].compactMap { $0 }.joined(separator: " · ")
    }
}

enum Support: String, CaseIterable {
    case tested, untested, needsWork = "needs_work", planned, unsupported, missing

    var title: String {
        switch self {
        case .tested: return "Tested"
        case .untested: return "Untested: may work out of the box"
        case .needsWork: return "Needs work"
        case .planned: return "Not yet supported"
        case .unsupported: return "Not supported"
        case .missing: return "Not installed"
        }
    }

    var symbol: String {
        switch self {
        case .tested: return "checkmark.circle.fill"
        case .untested: return "questionmark.circle"
        case .needsWork: return "wrench.and.screwdriver"
        case .planned: return "clock"
        case .unsupported: return "xmark.circle"
        case .missing: return "questionmark.folder"
        }
    }
}

/// `recomp.py env --json`.
struct BuildEnvironment: Decodable {
    struct Team: Decodable, Hashable, Identifiable {
        let id: String
        let identity: String
    }

    struct Device: Decodable, Hashable, Identifiable {
        let id: String
        let name: String?
        let model: String?
        let type: String?
        let state: String?

        var label: String { [name, model].compactMap { $0 }.joined(separator: " — ") }
        /// "iPhone" or "iPad" (devicectl's deviceType).
        var kind: String { type ?? "device" }
        var shortName: String { name ?? model ?? kind }
    }

    let tools: [String: Bool]
    let teams: [Team]
    let devices: [Device]
    let home: String

    var missingTools: [String] { tools.filter { !$0.value }.map(\.key).sorted() }

    /// The devices a port can be installed on: every port is a universal build.
    var portDevices: [Device] { devices.filter { $0.type == "iPhone" || $0.type == "iPad" } }
    /// The first iPad, else the first iPhone.
    var defaultDevice: Device? { portDevices.first { $0.type == "iPad" } ?? portDevices.first }
}

/// `recomp.py saves <app> --status|--enable|--disable --json` (recomp/saves.py).
struct SaveSyncStatus: Decodable {
    struct Entry: Decodable, Hashable {
        let name: String
        /// Newest file of the entry on this Mac and in iCloud Drive (ISO dates).
        let mac: String?
        let icloud: String?
    }

    let enabled: Bool
    let icloud: Bool
    let running: Bool
    let root: String?
    let cloud: String?
    let entries: [Entry]
    let lastSync: String?
    /// How many games are synced; the background item runs while there is one.
    let syncedGames: Int
    let backup: String?
    let conflicts: Int?
    /// The save sync of the game's last port ("steam", "icloud", "off"), nil before one; and the next one's default.
    let portMode: String?
    let defaultMode: String?
}

/// `recomp.py mods <app> [--include ID] [--exclude ID] --json` (recomp/mods.py): the mods on this
/// Mac and what the next port does with each.
struct ModList: Decodable {
    struct Mod: Decodable, Identifiable, Hashable {
        let id: String
        let name: String
        let version: String
        let source: String
        let folder: String
        let description: String?
        /// "compiled" (its code goes into the port), "data only", "skipped" (reason says why),
        /// "excluded" (turned off for this game) or "unchecked" (before the first port).
        let status: String
        let reason: String?
        let selected: Bool
        /// Patches the game through Harmony: woven into the port's code.
        let harmony: Bool
        /// What the last port did with it, nil if it was not there.
        let lastPort: String?

        /// A mod of the port itself (recomp/builtin_mods), not one installed on the Mac.
        var builtIn: Bool { source == "Built in" }
    }

    let supported: Bool
    let folders: [String]
    let ios: String?
    let mods: [Mod]
}

/// `recomp.py toolchain <app> --check`.
struct ToolchainStatus: Decodable {
    let version: String
    let installed: Bool
    let path: String
}
