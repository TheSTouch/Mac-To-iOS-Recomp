import Foundation

/// One run of the port pipeline for a game, with live progress.
@MainActor
final class PortJob: ObservableObject, Identifiable {
    struct Settings {
        var team: String
        var bundleId: String
        var device: String
        /// The device's name and kind ("iPhone" or "iPad"), for the stage titles and the finish text.
        var deviceName: String
        var deviceKind: String
        var workspace: String
        /// How the port's saves follow the player: "steam", "icloud" or "off" (`--saves`).
        var saves: String
    }

    enum StageState { case pending, running, done, failed }

    struct Stage: Identifiable {
        let id: String
        var title: String
        var state: StageState = .pending
    }

    enum Phase: Equatable {
        case checking
        case confirmDownload(version: String)
        case running
        case finished
        case failed(String)
        case cancelled
    }

    let game: Game
    /// The device changes when the finished port is installed on another one.
    @Published private(set) var settings: Settings
    @Published var phase: Phase = .checking
    @Published var stages: [Stage]
    @Published var fraction: Double?
    @Published var detail = ""
    @Published var log: [String] = []
    @Published var hints: [String] = []

    private var process: Process?
    private var toolchainMissing = false

    nonisolated var id: String { game.id }

    static let unityStages: [(String, String)] = [
        ("toolchain", "Get Unity editor"),
        ("prepare", "Prepare game code"),
        ("player", "Recompile with IL2CPP"),
        ("inject", "Add game data"),
        ("xcode", "Build and sign iOS app"),
    ]

    static let unrealStages: [(String, String)] = [
        ("prepare", "Retarget game code to iOS"),
        ("xcode", "Build and sign iOS app"),
    ]

    /// The engine command for the game's route: "unity" or "unreal".
    let route: String

    init(game: Game, settings: Settings) {
        self.game = game
        self.settings = settings
        route = game.route ?? "unity"
        stages = (route == "unreal" ? Self.unrealStages : Self.unityStages).map { Stage(id: $0.0, title: $0.1) }
            + [Stage(id: "install", title: "Install on \(settings.deviceName)")]
    }

    var workFolder: URL {
        URL(fileURLWithPath: settings.workspace).appendingPathComponent("build").appendingPathComponent(game.slug)
    }

    func start() {
        Task { await check() }
    }

    private func check() async {
        phase = .checking
        if route == "unreal" {
            // Nothing to download: the game's own binaries are retargeted.
            await runPipeline()
            return
        }
        do {
            let status = try await Engine.json(ToolchainStatus.self, ["toolchain", game.app, "--check"], home: settings.workspace)
            if status.installed {
                mark("toolchain", .done)
                await runPipeline()
            } else {
                toolchainMissing = true
                phase = .confirmDownload(version: status.version)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// The user agreed to download the Unity editor.
    func confirmDownload() {
        Task { await runPipeline() }
    }

    func cancel() {
        process?.terminate()
        phase = .cancelled
        for i in stages.indices where stages[i].state == .running { stages[i].state = .failed }
    }

    /// Run only the install stage again (e.g. after unlocking the device).
    func retryInstall() {
        Task {
            phase = .running
            mark("install", .pending)
            if await run([route, game.app, "install"] + portOptions) { finish() }
        }
    }

    /// Install the finished port on another iPhone or iPad: the build is universal, so only
    /// the install stage runs, with the same team and bundle ID.
    func install(on device: BuildEnvironment.Device) {
        settings.device = device.id
        settings.deviceName = device.shortName
        settings.deviceKind = device.kind
        if let i = stages.firstIndex(where: { $0.id == "install" }) { stages[i].title = "Install on \(device.shortName)" }
        hints = []
        fraction = nil
        retryInstall()
    }

    private var portOptions: [String] {
        ["--team", settings.team, "--bundle-id", settings.bundleId, "--device", settings.device, "--saves", settings.saves]
    }

    private func runPipeline() async {
        phase = .running
        if toolchainMissing {
            guard await run(["toolchain", game.app]) else { return }
        }
        guard await run([route, game.app] + portOptions) else { return }
        finish()
    }

    private func finish() {
        phase = .finished
        fraction = 1
        detail = "Installed. Open it from your \(settings.deviceKind)'s home screen."
    }

    /// Returns true on success.
    private func run(_ args: [String]) async -> Bool {
        do {
            let status = try await Engine.stream(args, home: settings.workspace, process: { self.process = $0 }) { line in
                Task { @MainActor in self.handle(line) }
            }
            // Let queued line handlers run before judging the outcome.
            await Task.yield()
            if phase == .cancelled { return false }
            if status != 0 {
                let last = log.last { !$0.hasPrefix("@@") && !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
                phase = .failed(last.isEmpty ? "The engine stopped with status \(status)." : last)
                return false
            }
            return true
        } catch {
            phase = .failed(error.localizedDescription)
            return false
        }
    }

    private func handle(_ line: String) {
        guard let event = EngineEvent.parse(line) else {
            log.append(line)
            if log.count > 2000 { log.removeFirst(log.count - 2000) }
            return
        }
        switch event.kind {
        case "stage":
            guard let name = event.name else { return }
            switch event.state {
            case "start":
                mark(name, .running)
                fraction = nil
                detail = stages.first { $0.id == name }?.title ?? name
            case "done": mark(name, .done)
            case "failed": mark(name, .failed)
            default: break
            }
        case "progress":
            fraction = event.fraction
            if let d = event.detail, !d.isEmpty { detail = d }
        case "log":
            if let l = event.line { log.append(l) }
        case "hint":
            if let t = event.text, !hints.contains(t) { hints.append(t) }
        default:
            break
        }
    }

    private func mark(_ id: String, _ state: StageState) {
        if let i = stages.firstIndex(where: { $0.id == id }) { stages[i].state = state }
    }
}
