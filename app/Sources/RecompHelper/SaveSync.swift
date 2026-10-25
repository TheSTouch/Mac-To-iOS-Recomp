import AppKit
import CoreServices
import Foundation

/// The background item that keeps synced games' saves in step with iCloud Drive
/// (`recomp.py saves`, see recomp/saves.py).
///
/// A LaunchAgent in ~/Library/LaunchAgents starts this app's own executable with
/// --sync-saves, so macOS treats its file access as Recomp Helper's: the player
/// allows Documents and iCloud Drive once, from the app. It is a plain agent, not
/// an SMAppService one: launchd ties those to the code signature they were
/// registered with and refuses every ad-hoc rebuild of the app (exit 78).
enum SaveSyncAgent {
    static let label = "io.github.thestouch.recomphelper.savesync"
    static let plist = "\(NSHomeDirectory())/Library/LaunchAgents/\(label).plist"
    static let gamesFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Recomp Helper/save-sync/games.json")
    static let icloudFolder = "\(NSHomeDirectory())/Library/Mobile Documents/com~apple~CloudDocs/Recomp Saves"
    private static var job: String { "gui/\(getuid())/\(label)" }

    /// Synced games by name -> app path (written by `recomp.py saves --enable`).
    static func syncedGames() -> [String: String] {
        guard let data = try? Data(contentsOf: gamesFile) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// Installs and (re)starts the agent while at least one game is synced, removes it otherwise.
    /// Returns a note for the player when something did not work.
    @discardableResult
    static func update(wanted: Bool) -> String? {
        launchctl(["bootout", job])
        guard wanted else {
            try? FileManager.default.removeItem(atPath: plist)
            return nil
        }
        guard let exe = Bundle.main.executablePath, Bundle.main.bundlePath.hasSuffix(".app") else {
            return "Saves sync now. Automatic syncing needs the packaged app (scripts/build-app.sh)."
        }
        let agent: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe, "--sync-saves"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "LowPriorityIO": true,
        ]
        do {
            try FileManager.default.createDirectory(atPath: (plist as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
                .write(to: URL(fileURLWithPath: plist))
        } catch {
            return "The background item could not be written: \(error.localizedDescription)"
        }
        let (status, output) = launchctl(["bootstrap", "gui/\(getuid())", plist])
        return status == 0 ? nil : "The background item could not start: \(output)"
    }

    /// At app launch: restart the agent from this copy of the app (it may have been
    /// rebuilt or moved since the agent was installed).
    static func refresh() {
        guard !syncedGames().isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { update(wanted: true) }
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = out
        p.standardError = out
        guard (try? p.run()) != nil else { return (-1, "") }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @MainActor static func runHeadless() -> Never {
        let home = UserDefaults.standard.string(forKey: "workspace") ?? AppState.defaultWorkspace
        SaveSyncDaemon(home: home).run()
    }
}

/// The background item's process. It stays idle and syncs when something happened:
/// a synced game quit (its new saves go up), iCloud Drive/Recomp Saves changed
/// (saves from iOS come down), and once an hour in case an event was missed.
/// The engine skips games that are running, and copies only files that changed.
final class SaveSyncDaemon: @unchecked Sendable {
    private let home: String
    private let queue = DispatchQueue(label: "recomp.saves")
    private let lock = NSLock()
    private var queued = Set<String>() // app paths; "" stands for every synced game
    private var stream: FSEventStreamRef?

    init(home: String) { self.home = home }

    func run() -> Never {
        request("")
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let path = app?.bundleURL?.standardizedFileURL.path,
                  SaveSyncAgent.syncedGames().values.contains(where: { URL(fileURLWithPath: $0).standardizedFileURL.path == path })
            else { return }
            request(path)
        }
        watch(SaveSyncAgent.icloudFolder)
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [self] _ in request("") }
        RunLoop.main.run()
        exit(0)
    }

    /// Queues one sync; a sync already waiting for the same target covers this request.
    private func request(_ app: String) {
        lock.lock()
        let fresh = queued.insert(app).inserted
        lock.unlock()
        guard fresh else { return }
        queue.async { [self] in
            lock.lock()
            queued.remove(app)
            lock.unlock()
            engine(app.isEmpty ? ["saves", "--sync-all"] : ["saves", app, "--sync"])
        }
    }

    private func engine(_ args: [String]) {
        do {
            let p = try Engine.makeProcess(args, home: home)
            try p.run()
            p.waitUntilExit()
        } catch {
            FileHandle.standardError.write(Data("save sync: \(error.localizedDescription)\n".utf8))
        }
    }

    /// FSEvents on the iCloud Drive folder, batched over 30 s (a sync's own copies end in one quiet re-check).
    private func watch(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<SaveSyncDaemon>.fromOpaque(info).takeUnretainedValue().request("")
        }
        guard let s = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 30,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }
}
