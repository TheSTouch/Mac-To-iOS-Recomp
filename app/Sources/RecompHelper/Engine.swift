import Foundation

/// Runs the Python engine (recomp.py) and decodes what it prints.
///
/// The engine ships inside the app at Contents/Resources/engine. During development
/// it is found through RECOMP_ENGINE or by walking up from the executable.
enum Engine {
    static let python = "/usr/bin/python3"

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
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-I", dir.appendingPathComponent("recomp.py").path] + args
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
        return try await withCheckedThrowingContinuation { cont in
            p.terminationHandler = { proc in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                guard proc.terminationStatus == 0 else {
                    let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    cont.resume(throwing: EngineError.failed(msg.trimmingCharacters(in: .whitespacesAndNewlines)))
                    return
                }
                do {
                    let dec = JSONDecoder()
                    dec.keyDecodingStrategy = .convertFromSnakeCase
                    cont.resume(returning: try dec.decode(T.self, from: data))
                } catch {
                    cont.resume(throwing: error)
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
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
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return "The recomp engine was not found inside the app."
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
