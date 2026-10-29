import Foundation

/// Runs the Python engine (recomp.py) and decodes what it prints.
///
/// The engine ships inside the app at Contents/Resources/engine. During development
/// it is found through RECOMP_ENGINE or by walking up from the executable.
enum Engine {
    /// The oldest Python the engine runs on (recomp.py checks it too).
    static let minimumPython = [3, 9]

    /// Where the Python running the engine came from.
    enum PythonSource { case settings, environment, automatic }

    /// The Python that runs the engine: the one chosen in Settings, else RECOMP_PYTHON, else the
    /// newest Homebrew or python.org one, else macOS's own (3.9.6 on current macOS).
    static var python: (path: String, source: PythonSource) {
        if let p = UserDefaults.standard.string(forKey: "python"), !p.isEmpty { return (p, .settings) }
        if let p = ProcessInfo.processInfo.environment["RECOMP_PYTHON"], !p.isEmpty { return (p, .environment) }
        return (automaticPython, .automatic)
    }

    /// The newest Homebrew or python.org Python new enough, else macOS's own. macOS's own is not
    /// probed: without Xcode, its /usr/bin/python3 shim offers to install the developer tools.
    static let automaticPython: String = {
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3",
                          "/Library/Frameworks/Python.framework/Versions/Current/bin/python3"]
        let found = candidates.compactMap { path in pythonVersion(path).map { (path, $0) } }
            .filter { !$0.1.lexicographicallyPrecedes(minimumPython) }
        return found.max { $0.1.lexicographicallyPrecedes($1.1) }?.0 ?? "/usr/bin/python3"
    }()

    /// [major, minor, micro] of the Python at `path`, nil when it does not run.
    static func pythonVersion(_ path: String) -> [Int]? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-I", "-c", "import sys; print('%d.%d.%d' % sys.version_info[:3])"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let parts = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".").compactMap { Int($0) }
        return parts.count == 3 ? parts : nil
    }

    /// Bytecode goes to the user's caches: written next to the engine inside the app, it breaks the
    /// app's signature. macOS's own Python does this by itself; Homebrew's and python.org's do not.
    static let pycache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("io.github.thestouch.recomphelper/pycache").path

    static var directory: URL? = {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL?.appendingPathComponent("engine"),
           fm.fileExists(atPath: res.appendingPathComponent("recomp.py").path) {
            return res
        }
        if let env = ProcessInfo.processInfo.environment["RECOMP_ENGINE"] {
            return URL(fileURLWithPath: env)
        }
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        while let d = dir, d.path != "/" {
            if fm.fileExists(atPath: d.appendingPathComponent("recomp.py").path) { return d }
            dir = d.deletingLastPathComponent()
        }
        return nil
    }()

    /// GUI apps start with a minimal PATH; the pipeline needs Homebrew's and .NET's tools.
    static func environment(home: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/local/share/dotnet", "\(NSHomeDirectory())/.dotnet"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        env["RECOMP_HOME"] = home
        env["RECOMP_EVENTS"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        env["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
        return env
    }

    static func makeProcess(_ args: [String], home: String) throws -> Process {
        guard let dir = directory else { throw EngineError.notFound }
        let python = python
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw EngineError.noPython(python.path) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python.path)
        p.arguments = ["-I", "-X", "pycache_prefix=\(pycache)", dir.appendingPathComponent("recomp.py").path] + args
        p.currentDirectoryURL = dir
        p.environment = environment(home: home)
        return p
    }

    /// Run to completion and decode stdout as JSON.
    static func json<T: Decodable>(_ type: T.Type, _ args: [String], home: String) async throws -> T {
        let p = try makeProcess(args, home: home)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        // Read both pipes while it runs: the scan prints more than a pipe holds (16 KB when the
        // kernel has no big pipes left), and a full pipe would block the engine forever.
        let (data, errData) = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let errRead = DispatchGroup()
                nonisolated(unsafe) var errData = Data()
                DispatchQueue.global().async(group: errRead) { errData = err.fileHandleForReading.readDataToEndOfFile() }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                errRead.wait()
                p.waitUntilExit()
                cont.resume(returning: (data, errData))
            }
        }
        guard p.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? ""
            throw EngineError.failed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(T.self, from: data)
    }

    /// Run and report every output line as it arrives; returns the exit status.
    static func stream(_ args: [String], home: String, process: (Process) -> Void,
                       onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let p = try makeProcess(args, home: home)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let buffer = LineBuffer(onLine: onLine)
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil } else { buffer.append(data) }
        }
        process(p)
        return try await withCheckedThrowingContinuation { cont in
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
                buffer.flush()
                cont.resume(returning: proc.terminationStatus)
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}

enum EngineError: LocalizedError {
    case notFound
    case noPython(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return "The recomp engine was not found inside the app."
        case .noPython(let path): return "No Python at \(path). Choose one in Settings > Python."
        case .failed(let msg): return msg.isEmpty ? "The engine failed." : msg
        }
    }
}

/// Splits a byte stream into lines.
final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func append(_ data: Data) {
        lock.lock()
        pending.append(data)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...nl)
        }
        lock.unlock()
        lines.forEach(onLine)
    }

    func flush() {
        lock.lock()
        let rest = pending
        pending.removeAll()
        lock.unlock()
        if !rest.isEmpty { onLine(String(decoding: rest, as: UTF8.self)) }
    }
}

/// One '@@'-prefixed line from the engine (see recomp/events.py).
struct EngineEvent: Decodable {
    let kind: String
    let name: String?
    let state: String?
    let fraction: Double?
    let detail: String?
    let line: String?
    let text: String?

    static func parse(_ line: String) -> EngineEvent? {
        guard line.hasPrefix("@@"), let data = line.dropFirst(2).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(EngineEvent.self, from: data)
    }
}
