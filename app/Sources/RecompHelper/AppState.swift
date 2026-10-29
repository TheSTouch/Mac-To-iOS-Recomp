import AppKit
import Foundation

/// Library of scanned games, user settings, and the build environment.
@MainActor
final class AppState: ObservableObject {
    @Published var games: [Game] = []
    @Published var environment: BuildEnvironment?
    @Published var scanning = false
    @Published var error: String?
    @Published var selection: Game.ID?
    @Published var job: PortJob?

    @Published var customFolders: [String] {
        didSet { UserDefaults.standard.set(customFolders, forKey: "customFolders") }
    }
    /// Where Unity editors (~15 GB each) and build output go.
    @Published var workspace: String {
        didSet { UserDefaults.standard.set(workspace, forKey: "workspace") }
    }

    /// The Python that runs the engine; empty for the automatic choice (see Engine.python).
    @Published var python: String {
        didSet { UserDefaults.standard.set(python, forKey: "python") }
    }

    static let defaultWorkspace: String = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("macToiOSRecomp").path
    }()

    init() {
        customFolders = UserDefaults.standard.stringArray(forKey: "customFolders") ?? []
        workspace = UserDefaults.standard.string(forKey: "workspace") ?? Self.defaultWorkspace
        python = UserDefaults.standard.string(forKey: "python") ?? ""
    }

    var selectedGame: Game? { games.first { $0.id == selection } }

    func games(_ support: Support) -> [Game] {
        games.filter { $0.support == support }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func refresh() async {
        scanning = true
        error = nil
        defer { scanning = false }
        try? FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        do {
            async let env = Engine.json(BuildEnvironment.self, ["env", "--json"], home: workspace)
            let args = ["scan", "--json"] + customFolders.flatMap { ["--extra", $0] }
            games = try await Engine.json([Game].self, args, home: workspace)
            environment = try await env
            if selection == nil { selection = (games(.tested) + games(.untested)).first?.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refreshEnvironment() async {
        environment = try? await Engine.json(BuildEnvironment.self, ["env", "--json"], home: workspace)
    }

    func chooseFolder(prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    func addCustomFolder() {
        guard let path = chooseFolder(prompt: "Add Folder"), !customFolders.contains(path) else { return }
        customFolders.append(path)
        Task { await refresh() }
    }

    func chooseWorkspace() {
        if let path = chooseFolder(prompt: "Use This Folder") { workspace = path }
    }

    func choosePython() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.resolvesAliases = false  // keep /opt/homebrew/bin/python3, which survives upgrades, not its Cellar target
        panel.directoryURL = URL(fileURLWithPath: FileManager.default.fileExists(atPath: "/opt/homebrew/bin")
                                 ? "/opt/homebrew/bin" : "/usr/local/bin")
        panel.message = "Choose a python3 executable (Python \(Engine.minimumPython.map(String.init).joined(separator: ".")) or newer)."
        panel.prompt = "Use This Python"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    func freeSpace(at path: String) -> Int64? {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
