import AppKit
import CoreServices
import Foundation
import ServiceManagement

/// The background item that keeps synced games' saves in step with iCloud Drive
/// (`recomp.py saves`, see recomp/saves.py).
///
/// It is this app's own executable started by launchd with --sync-saves, so macOS
/// treats its file access as Recomp Helper's: the player allows Documents and
/// iCloud Drive once, when turning sync on from the app.
enum SaveSyncAgent {
    static let plistName = "io.github.thestouch.recomphelper.saves.plist"
    /// The build that registered the item. launchd keeps the plist and the code
    /// requirement it was registered with, and refuses to start a rebuilt binary
    /// (exit 78, "needs LWCR update"), so every new build registers it again.
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
    static var service: SMAppService { .agent(plistName: plistName) }
    static let gamesFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Recomp Helper/save-sync/games.json")
    static let icloudFolder = "\(NSHomeDirectory())/Library/Mobile Documents/com~apple~CloudDocs/Recomp Saves"

    /// Synced games by name -> app path (written by `recomp.py saves --enable`).
    static func syncedGames() -> [String: String] {
        guard let data = try? Data(contentsOf: gamesFile) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// Registers the item while at least one game is synced, unregisters it otherwise.
    /// Returns a note for the player when something is left for them to do.
    static func update(wanted: Bool) -> String? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(plistName)")
        guard FileManager.default.fileExists(atPath: bundled.path) else {
            return wanted ? "Saves sync now. Automatic syncing needs the packaged app (scripts/build-app.sh)." : nil
        }
        do {
            if wanted, service.status != .enabled {
                try service.register()
            } else if !wanted, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            return "The background item could not be \(wanted ? "added" : "removed"): \(error.localizedDescription)"
        }
        UserDefaults.standard.set(wanted ? version : nil, forKey: "saveSyncAgentVersion")
        if wanted, service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return "Allow Recomp Helper in System Settings > General > Login Items so saves keep syncing."
        }
        return nil
    }

    /// At app launch: re-register an item registered by another build of the app.
    /// launchd keeps the loaded job with the code requirement of the build that
    /// registered it (ad-hoc builds change it every time; Developer ID builds do
    /// not), and SMAppService.unregister/register alone does not reload it. So the
    /// job is booted out, the registration is redone once it is gone, and the whole
    /// thing is tried once more if the job still does not run.
    static func refreshIfOutdated() {
        // The status is not "enabled" here after a rebuild, so it is not checked.
        guard !syncedGames().isEmpty, UserDefaults.standard.string(forKey: "saveSyncAgentVersion") != version
        else { return }
        NSLog("[recomp] save sync item: re-registering for build \(version) (status \(service.status.rawValue))")
        DispatchQueue.global(qos: .utility).async {
            for attempt in 1...2 {
                let out = launchctl(["bootout", job]).status
                var waited = 0
                while waited < 20, launchctl(["print", job]).status == 0 {
                    Thread.sleep(forTimeInterval: 0.25)
                    waited += 1
                }
                let done = DispatchSemaphore(value: 0)
                service.unregister { _ in done.signal() }
                done.wait()
                let before = service.status
                let note = update(wanted: true)
                Thread.sleep(forTimeInterval: 3)
                NSLog("[recomp] save sync item, attempt \(attempt): bootout \(out), gone after \(waited) waits, "
                      + "status before register \(before.rawValue), after \(service.status.rawValue), "
                      + "\(note ?? "registered"), running \(running())")
                if running() { return }
            }
        }
    }

    private static var job: String { "gui/\(getuid())/\(plistName.replacingOccurrences(of: ".plist", with: ""))" }

    private static func running() -> Bool { launchctl(["print", job]).output.contains("state = running") }

    @discardableResult
    private static func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (-1, "") }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, text)
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
