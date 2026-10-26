import AppKit
import SwiftUI

@main
enum Main {
    /// launchd starts the app with --sync-saves for the save sync's background item (SaveSync.swift).
    @MainActor static func main() {
        if CommandLine.arguments.contains("--sync-saves") { SaveSyncAgent.runHeadless() }
        SaveSyncAgent.refresh()
        RecompHelperApp.main()
    }
}

struct RecompHelperApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Recomp Helper") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 860, minHeight: 540)
                .task { await state.refresh() }
        }
        Settings {
            SettingsView().environmentObject(state).frame(width: 520, height: 360)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationSplitView {
            List(selection: $state.selection) {
                ForEach(Support.allCases, id: \.self) { support in
                    let games = state.games(support)
                    if !games.isEmpty {
                        Section(support.title) {
                            ForEach(games) { GameRow(game: $0).tag($0.id) }
                        }
                    }
                }
            }
            .overlay {
                if state.games.isEmpty && !state.scanning {
                    ContentUnavailableView("No games found", systemImage: "gamecontroller",
                                           description: Text("Add the folder your games are installed in."))
                }
            }
            .safeAreaInset(edge: .bottom) { EnvironmentFooter() }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            if let game = state.selectedGame {
                GameDetail(game: game)
            } else {
                ContentUnavailableView("Select a game", systemImage: "gamecontroller")
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if state.scanning { ProgressView().controlSize(.small) }
                Button { state.addCustomFolder() } label: { Label("Add Folder", systemImage: "folder.badge.plus") }
                    .help("Scan another folder for games")
                Button { Task { await state.refresh() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .disabled(state.scanning)
            }
        }
        .alert("Scan failed", isPresented: .constant(state.error != nil)) {
            Button("OK") { state.error = nil }
        } message: { Text(state.error ?? "") }
        .sheet(item: $state.job) { job in PortSheet(job: job) }
    }
}

struct GameRow: View {
    let game: Game

    var body: some View {
        HStack {
            Image(systemName: game.support.symbol).foregroundStyle(color(game.support))
            VStack(alignment: .leading) {
                Text(game.name)
                Text("\(game.engineLabel) · \(game.source)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

func color(_ s: Support) -> Color {
    switch s {
    case .tested: return .green
    case .untested: return .teal
    case .needsWork: return .yellow
    case .planned: return .orange
    case .unsupported: return .red
    case .missing: return .secondary
    }
}

struct EnvironmentFooter: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let env = state.environment {
                if !env.missingTools.isEmpty {
                    Label("Missing: \(env.missingTools.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Label(env.teams.isEmpty ? "No Apple Development certificate" : "\(env.teams.count) signing team(s)",
                      systemImage: "signature")
                Label("\(env.devices.filter { $0.type == "iPhone" }.count) iPhone(s) and \(env.devices.filter { $0.type == "iPad" }.count) iPad(s) paired",
                      systemImage: "ipad.and.iphone")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }
}

struct GameDetail: View {
    @EnvironmentObject var state: AppState
    let game: Game
    @State private var setup = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: game.app))
                        .resizable().frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(game.name).font(.title.bold())
                        Label(game.support.title, systemImage: game.support.symbol).foregroundStyle(color(game.support))
                        Text(game.statusDetail).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if game.route == "unity" || game.route == "unreal" {
                        Button("Port to iOS…") { setup = true }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    row("Engine", game.engineLabel)
                    row("CPU", game.archs.isEmpty ? "—" : game.archs.joined(separator: ", "))
                    row("Mac-only frameworks", game.macOnlyFrameworks.isEmpty ? "none" : game.macOnlyFrameworks.joined(separator: ", "))
                    row("Found in", game.source)
                    row("Location", game.app)
                }
                if game.saves == true {
                    SaveSyncBox(game: game).id(game.id)
                }
                if game.mods == true {
                    ModsBox(game: game).id(game.id)
                }
                if !game.checks.isEmpty {
                    GroupBox("Compatibility") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(game.checks, id: \.self) { Label($0, systemImage: "checklist").font(.callout) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !game.flags.isEmpty {
                    GroupBox("Notes") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(game.flags, id: \.self) { Label($0, systemImage: "info.circle").font(.callout) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: game.app)]) }
            }
            .padding(24)
        }
        .sheet(isPresented: $setup) { PortSetup(game: game) }
    }

    @ViewBuilder private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled)
        }
    }
}

/// Shares the Mac game's saves with its iOS ports through iCloud Drive (`recomp.py saves`).
/// The Mac game and Steam Cloud keep their own folder; a background item copies both ways.
struct SaveSyncBox: View {
    @EnvironmentObject var state: AppState
    let game: Game
    @State private var status: SaveSyncStatus?
    @State private var busy = false
    @State private var error: String?
    @State private var note: String?

    var body: some View {
        GroupBox("Saves") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("Sync saves with iCloud Drive", isOn: Binding(
                        get: { status?.enabled ?? false },
                        set: { on in Task { await run(on ? "--enable" : "--disable") } }))
                        .disabled(busy || status == nil || status?.icloud == false)
                    if busy { ProgressView().controlSize(.small) }
                }
                Text("The game keeps saving to its usual folder, and Steam Cloud keeps syncing it. Recomp Helper copies the saves both ways with iCloud Drive/Recomp Saves/\(game.name), the folder its iPhone and iPad ports sync with: right after the game quits, when saves arrive from iOS, and hourly. Only changed files are copied.")
                    .font(.caption).foregroundStyle(.secondary)
                if let s = status {
                    if !s.icloud {
                        Label("iCloud Drive is off on this Mac. Turn it on in System Settings > your name > iCloud.",
                              systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    if s.enabled {
                        Label("Last sync: " + (s.lastSync.map(shown) ?? "not yet") + (s.running ? " (\(game.name) is running: it syncs after it quits)" : ""),
                              systemImage: "arrow.triangle.2.circlepath").font(.callout)
                    }
                    ForEach(s.entries, id: \.self) { e in
                        Label("\(e.name): last change on this Mac \(e.mac.map(shown) ?? "—"), in iCloud Drive \(e.icloud.map(shown) ?? "—")",
                              systemImage: "doc").font(.callout)
                    }
                    if let backup = s.backup {
                        Label("Backup of the previous saves: \(backup)", systemImage: "archivebox").font(.caption)
                            .textSelection(.enabled)
                    }
                    if let n = s.conflicts, n > 0 {
                        Label("\(n) files differed on the Mac and in iCloud Drive: the newest is used, the other is kept next to it as a .conflict copy.",
                              systemImage: "doc.on.doc").font(.caption)
                    }
                }
                if let note {
                    Label(note, systemImage: "info.circle").font(.callout)
                }
                if let error {
                    Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await run("--status") }
    }

    private func shown(_ iso: String) -> String { iso.replacingOccurrences(of: "T", with: " ") }

    private func run(_ action: String) async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let s = try await Engine.json(SaveSyncStatus.self, ["saves", game.app, action, "--json"], home: state.workspace)
            status = s
            if action != "--status" { note = SaveSyncAgent.update(wanted: s.syncedGames > 0) }
        } catch {
            self.error = error.localizedDescription
            if action != "--status" { await run("--status") }
        }
    }
}

/// Chooses which of the Mac's mods go into the port (`recomp.py mods`). iOS cannot run code
/// that was not compiled into the app, so a mod's code only works on the iPhone or iPad when the mod
/// was installed and selected here before porting; its data files are copied to the device after.
struct ModsBox: View {
    @EnvironmentObject var state: AppState
    let game: Game
    @State private var list: ModList?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(list?.mods.filter(\.builtIn) ?? []) { mod in
                builtIn(mod)
            }
            macMods
        }
        .task { await run([]) }
    }

    /// A mod of the port itself, e.g. Timberborn's Touchscreen (each gets its own box, so a later
    /// one such as small-screen UI for iPhone sits beside it): explained on its own instead of
    /// listed with the Mac's mods, and on unless turned off here (or in the game's mod list).
    private func builtIn(_ mod: ModList.Mod) -> some View {
        GroupBox("Built into the port: \(mod.name)") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("Include in the port", isOn: Binding(
                        get: { mod.selected },
                        set: { on in Task { await run([on ? "--include" : "--exclude", mod.id]) } }))
                        .disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                }
                if let d = mod.description, !d.isEmpty {
                    Text(d).font(.callout)
                }
                Text("Part of the iOS port, not a mod from this Mac. It can also be turned off on the device in the game's mod list, without porting again; turning it off here leaves it out of the next port.")
                    .font(.caption).foregroundStyle(.secondary)
                if let last = mod.lastPort, (last == "compiled") != mod.selected {
                    Label(mod.selected ? "Not in the installed port yet: port again to add it." : "The installed port still has it: port again to leave it out.",
                          systemImage: "arrow.triangle.2.circlepath").font(.caption)
                } else if mod.lastPort == nil, mod.selected {
                    Label("Not in the installed port yet: port again to add it.", systemImage: "arrow.triangle.2.circlepath").font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var macMods: some View {
        GroupBox("Mods") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Mods installed for \(game.name) on this Mac. The ticked ones are compiled into the next port and copied to the iPhone or iPad after it. Adding, updating or removing a mod with code needs a new port; mods made only of data files can also be dropped into Files > \(game.name) > Mods on the device.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button("Refresh") { Task { await run([]) } }.disabled(busy)
                }
                if let list {
                    if list.mods.allSatisfy(\.builtIn) {
                        Label("No mods found in " + list.folders.joined(separator: " or "), systemImage: "puzzlepiece")
                            .font(.callout)
                    }
                    ForEach(list.mods.filter { !$0.builtIn }) { mod in
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(isOn: Binding(
                                get: { mod.selected },
                                set: { on in Task { await run([on ? "--include" : "--exclude", mod.id]) } })) {
                                Text("\(mod.name) \(mod.version)").font(.callout.bold())
                                    + Text("  \(mod.source)").font(.caption).foregroundColor(.secondary)
                            }
                            .disabled(busy)
                            Label(summary(mod), systemImage: symbol(mod))
                                .font(.caption).foregroundStyle(mod.status == "skipped" ? .orange : .secondary)
                                .padding(.leading, 20)
                        }
                    }
                }
                if let error {
                    Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summary(_ mod: ModList.Mod) -> String {
        var text: String
        switch mod.status {
        case "compiled": text = mod.harmony ? "Code compiled in; its Harmony patches are woven into the game" : "Code compiled in"
        case "data only": text = "Data files only"
        case "excluded": text = "Left out of the next port"
        case "unchecked": text = mod.reason ?? "Checked on the first port"
        default: text = "Cannot run on iOS: " + (mod.reason ?? "unknown reason")
        }
        if let last = mod.lastPort, last != mod.status, mod.status != "skipped" {
            text += last == "compiled" || last == "data only" ? " (the installed port still has the previous choice)" : " (not in the installed port yet)"
        } else if mod.lastPort == nil, mod.selected, mod.status != "skipped" {
            text += " (not in the installed port yet)"
        }
        return text
    }

    private func symbol(_ mod: ModList.Mod) -> String {
        switch mod.status {
        case "compiled": return "cpu"
        case "data only": return "doc"
        case "skipped": return "exclamationmark.triangle"
        default: return "minus.circle"
        }
    }

    private func run(_ args: [String]) async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            list = try await Engine.json(ModList.self, ["mods", game.app] + args + ["--json"], home: state.workspace)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Collects everything the pipeline needs before it starts, so it never stops to ask.
struct PortSetup: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    let game: Game
    @State private var team = ""
    @State private var device = ""
    @State private var bundleId = ""

    var devices: [BuildEnvironment.Device] { state.environment?.portDevices ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Port \(game.name) to iOS").font(.title2.bold())
            Form {
                Picker("Device", selection: $device) {
                    ForEach(devices) { Text($0.label).tag($0.id) }
                }
                Picker("Signing team", selection: $team) {
                    ForEach(state.environment?.teams ?? []) { Text($0.identity).tag($0.id) }
                }
                TextField("Bundle ID", text: $bundleId)
                LabeledContent("Workspace") {
                    HStack {
                        Text(state.workspace).lineLimit(1).truncationMode(.middle)
                        Button("Change…") { state.chooseWorkspace() }
                    }
                }
                if let free = state.freeSpace(at: state.workspace) {
                    LabeledContent("Free space", value: ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
                    if game.route == "unreal" {
                        // The app holds the game's data as APFS clones, free on the game's own disk.
                        if free < 2_000_000_000 {
                            Text("An Unreal port needs a few GB, and as much as the game itself when the workspace is not on the game's disk. Choose a bigger disk.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    } else if free < 40_000_000_000 {
                        Text("A Unity port needs about 40 GB (editor, generated code, the game's data). Choose a bigger disk.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if devices.isEmpty {
                Label("No iPhone or iPad paired. Connect it with a cable once and trust this Mac, then refresh.",
                      systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if state.environment?.teams.isEmpty ?? true {
                Label("No Apple Development certificate. Sign in to your developer account in Xcode → Settings → Accounts.",
                      systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Text("The app is signed with your developer account and installed on your own devices only. Do not share it: it contains the game.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Refresh devices") { Task { await state.refreshEnvironment() } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start") {
                    let picked = devices.first { $0.id == device }
                    let job = PortJob(game: game, settings: .init(team: team, bundleId: bundleId, device: device,
                                                                  deviceName: picked?.shortName ?? device,
                                                                  deviceKind: picked?.kind ?? "device",
                                                                  workspace: state.workspace))
                    dismiss()
                    state.job = job
                    job.start()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(team.isEmpty || device.isEmpty || bundleId.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onChange(of: devices) {
            if !devices.contains(where: { $0.id == device }) { device = state.environment?.defaultDevice?.id ?? "" }
        }
        .onAppear {
            team = state.environment?.teams.first?.id ?? ""
            device = state.environment?.defaultDevice?.id ?? ""
            bundleId = "recomp.\(team.lowercased()).\(game.slug.lowercased())"
        }
    }
}

struct PortSheet: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var job: PortJob
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Porting \(job.game.name)").font(.title2.bold())
            VStack(alignment: .leading, spacing: 8) {
                ForEach(job.stages) { stage in
                    HStack {
                        stageIcon(stage.state).frame(width: 18)
                        Text(stage.title).foregroundStyle(stage.state == .pending ? .secondary : .primary)
                    }
                }
            }
            switch job.phase {
            case .checking:
                ProgressView("Checking for the Unity editor…")
            case .confirmDownload(let version):
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("This game needs Unity \(version) with iOS support.").bold()
                        Text("It is about 5.5 GB to download and 15 GB unpacked, saved in \(job.settings.workspace). It is verified as signed by Unity and is not installed system-wide.")
                            .font(.callout)
                        HStack {
                            Spacer()
                            Button("Cancel") { job.cancel() }
                            Button("Download") { job.confirmDownload() }.buttonStyle(.borderedProminent)
                        }
                    }
                }
            case .running, .finished:
                if let f = job.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
                Text(job.detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            case .failed(let msg):
                Label(msg, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
            case .cancelled:
                Label("Cancelled", systemImage: "stop.circle")
            }
            ForEach(job.hints, id: \.self) { Label($0, systemImage: "lightbulb").font(.callout) }
            DisclosureGroup("Log", isExpanded: $showLog) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(job.log.suffix(500).enumerated()), id: \.offset) { i, line in
                                Text(line).font(.system(.caption, design: .monospaced)).id(i)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    }
                    .frame(height: 200)
                    .onChange(of: job.log.count) { proxy.scrollTo(min(job.log.count, 500) - 1) }
                }
            }
            HStack {
                Button("Show Build Folder") { NSWorkspace.shared.open(job.workFolder) }
                if case .failed = job.phase, job.stages.last?.state == .failed {
                    Button("Retry Install") { job.retryInstall() }
                }
                Spacer()
                if job.phase == .running || job.phase == .checking {
                    Button("Stop") { job.cancel() }
                } else {
                    Button("Close") { state.job = nil }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 620)
        .interactiveDismissDisabled()
    }

    @ViewBuilder private func stageIcon(_ s: PortJob.StageState) -> some View {
        switch s {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var picked: String?

    var body: some View {
        Form {
            Section("Extra game folders") {
                List(state.customFolders, id: \.self, selection: $picked) { Text($0) }.frame(height: 140)
                HStack {
                    Button("Add…") { state.addCustomFolder() }
                    Button("Remove") { state.customFolders.removeAll { $0 == picked } }.disabled(picked == nil)
                }
            }
            Section("Workspace (Unity editors and builds, ~40 GB per game)") {
                Text(state.workspace).textSelection(.enabled)
                HStack {
                    Button("Change…") { state.chooseWorkspace() }
                    Button("Reset") { state.workspace = AppState.defaultWorkspace }
                }
            }
        }
        .padding()
    }
}
