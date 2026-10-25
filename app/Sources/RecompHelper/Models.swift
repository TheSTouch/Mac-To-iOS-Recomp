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

    var id: String { app }
    var support: Support { Support(rawValue: status) ?? .planned }
    var engineLabel: String { engineBackend.map { "\(engine) (\($0))" } ?? engine }
    var slug: String { name.filter { $0.isLetter || $0.isNumber } }
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
    }

    let tools: [String: Bool]
    let teams: [Team]
    let devices: [Device]
    let home: String

    var missingTools: [String] { tools.filter { !$0.value }.map(\.key).sorted() }
}

/// `recomp.py saves <app> --status|--enable|--disable --json` (recomp/saves.py).
struct SaveSyncStatus: Decodable {
    struct Entry: Decodable, Hashable {
        let name: String
        let state: String
        let lastChange: String?
    }

    let enabled: Bool
    let icloud: Bool
    let root: String?
    let cloud: String?
    let entries: [Entry]
    let lastChange: String?
    let backup: String?
    let conflicts: Int?
}

/// `recomp.py toolchain <app> --check`.
struct ToolchainStatus: Decodable {
    let version: String
    let installed: Bool
    let path: String
}
