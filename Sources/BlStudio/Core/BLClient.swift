import Foundation

// MARK: - Errors

enum BLClientError: Error, LocalizedError {
    case binaryNotFound(searched: [String])
    case apiError(code: Int?, message: String, hint: String?)
    case badOutput(String)
    case timeout(seconds: Int)
    case nonZeroExit(Int32, stderrTail: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let searched):
            return "bl binary not found. Searched: \(searched.joined(separator: ", ")). Install bailian-cli or set the path in Settings."
        case .apiError(_, let message, let hint):
            if let hint, !hint.isEmpty { return "\(message): \(hint)" }
            return message
        case .badOutput(let head):
            return "Could not parse bl output: \(head)"
        case .timeout(let seconds):
            return "bl command timed out after \(seconds)s."
        case .nonZeroExit(let code, let tail):
            return "bl exited with code \(code). \(tail)"
        case .cancelled:
            return "Cancelled."
        }
    }
}

struct BLProcessOutput: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

// MARK: - JSON extraction (tolerates banners/trailing junk around the JSON document)

enum BLJSON {
    /// Extract the first JSON document from possibly noisy CLI stdout.
    static func extract(_ raw: String) -> Data? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else { return nil }
        let opener: Character = first
        let closer: Character = opener == "{" ? "}" : "]"
        guard let start = trimmed.firstIndex(of: opener),
              let end = trimmed.lastIndex(of: closer), start <= end else { return nil }
        return Data(trimmed[start...end].utf8)
    }
}

// MARK: - Client

/// Thin async wrapper around the `bl` executable.
final class BLClient: @unchecked Sendable {

    var binaryOverride: String?

    private static let searchPaths: [String] = [
        "\(NSHomeDirectory())/.local/bin/bl",
        "/opt/homebrew/bin/bl",
        "/usr/local/bin/bl",
        "\(NSHomeDirectory())/.bun/bin/bl",
        "\(NSHomeDirectory())/.npm-global/bin/bl",
    ]

    func resolveBinary() throws -> URL {
        var searched: [String] = []
        if let override = binaryOverride, !override.isEmpty {
            searched.append(override)
            if FileManager.default.isExecutableFile(atPath: override) {
                return URL(fileURLWithPath: override)
            }
        }
        for p in Self.searchPaths {
            searched.append(p)
            if FileManager.default.isExecutableFile(atPath: p) {
                return URL(fileURLWithPath: p)
            }
        }
        // Fall back to PATH lookup.
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            for dir in envPath.split(separator: ":") {
                let p = "\(dir)/bl"
                searched.append(p)
                if FileManager.default.isExecutableFile(atPath: p) {
                    return URL(fileURLWithPath: p)
                }
            }
        }
        throw BLClientError.binaryNotFound(searched: searched)
    }

    /// Run `bl <arguments>` and capture output. Streams stderr lines to `onStderrLine` live.
    func run(
        arguments: [String],
        timeoutSeconds: Int = 300,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> BLProcessOutput {
        let binary = try resolveBinary()
        return try await withTaskCancellationHandler {
            try await runProcess(url: binary, arguments: arguments,
                                 timeoutSeconds: timeoutSeconds, onStderrLine: onStderrLine)
        } onCancel: {
            // Handled inside runProcess via the session box.
        }
    }

    /// Run a command expecting a JSON document on stdout, decoded into `T`.
    /// Detects the `{"error": ...}` envelope and maps it to `BLClientError.apiError`.
    func runJSON<T: Decodable>(
        _ type: T.Type,
        arguments: [String],
        timeoutSeconds: Int = 300,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> T {
        let out = try await run(arguments: arguments + ["--output", "json"],
                                timeoutSeconds: timeoutSeconds,
                                onStderrLine: onStderrLine)
        return try Self.decode(T.self, from: out)
    }

    static func decode<T: Decodable>(_ type: T.Type, from out: BLProcessOutput) throws -> T {
        let stdout = out.stdout
        if let data = BLJSON.extract(stdout) {
            let decoder = JSONDecoder()
            // First try the error envelope: bl uses it on failures even with exit 0 sometimes.
            if let envelope = try? decoder.decode(BLErrorEnvelope.self, from: data),
               envelope.error.message.nonEmpty {
                throw BLClientError.apiError(code: envelope.error.code,
                                             message: envelope.error.message,
                                             hint: envelope.error.hint)
            }
            if let value = try? decoder.decode(T.self, from: data) {
                return value
            }
        }
        if out.exitCode != 0 {
            throw BLClientError.nonZeroExit(out.exitCode, stderrTail: Self.tail(out.stderr))
        }
        throw BLClientError.badOutput(String(stdout.prefix(300)))
    }

    static func tail(_ s: String, lines: Int = 4) -> String {
        let l = s.split(separator: "\n", omittingEmptySubsequences: true)
        return l.suffix(lines).joined(separator: " ")
    }

    // MARK: process plumbing

    private final class Session: @unchecked Sendable {
        let process = Process()
        func terminate() {
            if process.isRunning { process.terminate() }
        }
    }

    private func runProcess(
        url: URL,
        arguments: [String],
        timeoutSeconds: Int,
        onStderrLine: (@Sendable (String) -> Void)?
    ) async throws -> BLProcessOutput {
        let session = Session()
        let proc = session.process
        proc.executableURL = url
        proc.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        // Make sure node/bl deps and friends are reachable even from a GUI launch context.
        let extraPaths = [
            "\(NSHomeDirectory())/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let existing = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [existing]).joined(separator: ":")
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        proc.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.standardInput = FileHandle.nullDevice

        let stdoutData = PipeCollector()
        let stderrData = PipeCollector()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            stdoutData.append(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            stderrData.append(data)
            if let onStderrLine {
                for line in stderrData.drainLines() {
                    onStderrLine(line)
                }
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<BLProcessOutput, Error>) in
                let resumeLock = NSLock()
                var resumed = false
                let resume: (Result<BLProcessOutput, Error>) -> Void = { result in
                    resumeLock.lock()
                    let should = !resumed
                    resumed = true
                    resumeLock.unlock()
                    if should { cont.resume(with: result) }
                }

                // Timeout watchdog.
                let timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                    if !Task.isCancelled, proc.isRunning {
                        session.terminate()
                        resume(.failure(BLClientError.timeout(seconds: timeoutSeconds)))
                    }
                }

                proc.terminationHandler = { p in
                    timeoutTask.cancel()
                    // Give the readability handlers a moment to drain EOF chunks.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        if let onStderrLine {
                            for line in stderrData.drainLines() { onStderrLine(line) }
                        }
                        let out = BLProcessOutput(
                            stdout: stdoutData.string(),
                            stderr: stderrData.string(),
                            exitCode: p.terminationStatus
                        )
                        resume(.success(out))
                    }
                }

                do {
                    try proc.run()
                } catch {
                    timeoutTask.cancel()
                    resume(.failure(error))
                    return
                }
            }
        } onCancel: {
            session.terminate()
        }
    }
}

private extension String {
    var nonEmpty: Bool { !trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Thread-safe byte collector that can also emit complete stderr lines incrementally.
final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var lineRemainder = Data()

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        lineRemainder.append(data)
        lock.unlock()
    }

    func string() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: buffer, encoding: .utf8) ?? ""
    }

    /// Returns complete lines accumulated since the last call (for live progress display).
    func drainLines() -> [String] {
        lock.lock(); defer { lock.unlock() }
        // Work on a copy of everything after what lines() already consumed.
        var out: [String] = []
        var scan = lineRemainder
        while let nl = scan.firstIndex(of: 0x0A) {
            let lineData = scan[..<nl]
            if let s = String(data: lineData, encoding: .utf8) {
                let trimmed = s.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { out.append(trimmed) }
            }
            scan = Data(scan[scan.index(after: nl)...])
        }
        lineRemainder = scan
        return out
    }
}
