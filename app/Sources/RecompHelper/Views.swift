import AppKit
import SwiftUI

@main
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
                Label("\(env.devices.filter { $0.type == "iPad" }.count) iPad(s) paired", systemImage: "ipad")
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
                    if game.route == "unity" {
                        Button("Port to iPad…") { setup = true }
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

/// Collects everything the pipeline needs before it starts, so it never stops to ask.
struct PortSetup: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    let game: Game
    @State private var team = ""
    @State private var device = ""
    @State private var bundleId = ""

    var ipads: [BuildEnvironment.Device] { state.environment?.devices.filter { $0.type == "iPad" } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Port \(game.name) to iPad").font(.title2.bold())
            Form {
                Picker("iPad", selection: $device) {
                    ForEach(ipads) { Text($0.label).tag($0.id) }
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
                    if free < 40_000_000_000 {
                        Text("A Unity port needs about 40 GB (editor, generated code, the game's data). Choose a bigger disk.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if ipads.isEmpty {
                Label("No iPad paired. Connect it with a cable once and trust this Mac, then refresh.",
                      systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if state.environment?.teams.isEmpty ?? true {
                Label("No Apple Development certificate. Sign in to your developer account in Xcode → Settings → Accounts.",
                      systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Text("The app is signed with your developer account and installed on your iPad only. Do not share it: it contains the game.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Refresh devices") { Task { await state.refreshEnvironment() } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start") {
                    let job = PortJob(game: game, settings: .init(team: team, bundleId: bundleId, device: device,
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
        .onAppear {
            team = state.environment?.teams.first?.id ?? ""
            device = ipads.first?.id ?? ""
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
