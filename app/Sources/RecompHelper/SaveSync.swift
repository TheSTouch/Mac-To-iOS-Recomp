import Foundation
import ServiceManagement

/// The background item that keeps synced games' saves in step with iCloud Drive
/// (`recomp.py saves --sync-all`, see recomp/saves.py).
///
/// It is this app's own executable started by launchd with --sync-saves, so macOS
/// treats its file access as Recomp Helper's: the player allows Documents and
/// iCloud Drive once, when turning sync on from the app.
enum SaveSyncAgent {
    static let plistName = "io.github.thestouch.recomphelper.saves.plist"
    static var service: SMAppService { .agent(plistName: plistName) }

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
        if wanted, service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return "Allow Recomp Helper in System Settings > General > Login Items so saves keep syncing."
        }
        return nil
    }

    /// The background run: sync every synced game that is not running, then exit.
    @MainActor static func runHeadless() -> Int32 {
        let home = UserDefaults.standard.string(forKey: "workspace") ?? AppState.defaultWorkspace
        do {
            let p = try Engine.makeProcess(["saves", "--sync-all"], home: home)
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            FileHandle.standardError.write(Data("save sync: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
