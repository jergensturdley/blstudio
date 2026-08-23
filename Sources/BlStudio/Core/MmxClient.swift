import Foundation

// MARK: - Errors

enum MmxClientError: Error, LocalizedError {
    case binaryNotFound(searched: [String])
    case apiError(code: Int?, message: String, hint: String?)
    case badOutput(String)
    case timeout(seconds: Int)
    case nonZeroExit(Int32, stderrTail: String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let searched):
            return "mmx binary not found. Searched: \(searched.joined(separator: ", ")). Install it with `npm i -g mmx-cli`, or set the path in Settings."
        case .apiError(_, let message, let hint):
            if let hint, !hint.isEmpty { return "\(message). \(hint)" }
            return message
        case .badOutput(let head):
            return "Could not parse mmx output: \(head)"
        case .timeout(let seconds):
            return "mmx command timed out after \(seconds)s."
        case .nonZeroExit(let code, let tail):
            return "mmx exited with code \(code). \(tail)"
        }
    }
}

// MARK: - Result types

/// Success envelope for `mmx video generate --download <path> --output json`.
/// `file_id` is only present for legacy (non-H3) tasks; H3 results carry the
/// video URL instead. `saved` is the download path we asked for.
struct MmxVideoResult: Codable, Sendable {
    var task_id: String?
    var status: String?
    var file_id: String?
    var url: String?
    var saved: String?
    var size: String?
}

/// One row of `mmx quota show --output json` (model_remains).
struct MmxQuotaRemain: Codable, Sendable, Identifiable {
    var id: String { model_name ?? "unknown" }
    var model_name: String?
    var remains_time: Int?
    var current_interval_total_count: Int?
    var current_interval_usage_count: Int?
    var current_interval_remaining_percent: Double?
    var current_interval_status: Int?
    var current_weekly_total_count: Int?
    var current_weekly_usage_count: Int?
    var current_weekly_remaining_percent: Double?
    var current_weekly_status: Int?
    var weekly_boost_permille: Int?
}

struct MmxQuotaResponse: Codable, Sendable {
    var model_remains: [MmxQuotaRemain]?
}

// MARK: - Client

/// Thin async wrapper around the `mmx` executable (mmx-cli), used the same way
/// BlStudio drives `bl`. MiniMax video generation (incl. MiniMax-H3) and quota
/// lookups go through it; the API key is passed per call via `--api-key`.
final class MmxClient: @unchecked Sendable {

    var binaryOverride: String?

    static let h3Model = "MiniMax-H3"
    /// First mmx version that supports MiniMax-H3 (Video Generation V2).
    static let h3MinVersion = "1.0.19"

    private static let searchPaths: [String] = [
        "\(NSHomeDirectory())/.local/bin/mmx",
        "/opt/homebrew/bin/mmx",
        "/usr/local/bin/mmx",
        "\(NSHomeDirectory())/.bun/bin/mmx",
        "\(NSHomeDirectory())/.npm-global/bin/mmx",
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
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            for dir in envPath.split(separator: ":") {
                let p = "\(dir)/mmx"
                searched.append(p)
                if FileManager.default.isExecutableFile(atPath: p) {
                    return URL(fileURLWithPath: p)
                }
            }
        }
        throw MmxClientError.binaryNotFound(searched: searched)
    }

    func isAvailable() -> Bool { (try? resolveBinary()) != nil }

    /// `mmx --version` → the numeric part, e.g. "1.0.22".
    func cliVersion() async throws -> String {
        let out = try await run(arguments: ["--version"], timeoutSeconds: 30)
        let s = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: #"[0-9][0-9.]*"#, options: .regularExpression) {
            return String(s[r])
        }
        throw MmxClientError.badOutput(s)
    }

    /// Numeric version comparison: `versionAtLeast("1.0.22", "1.0.19") == true`.
    static func versionAtLeast(_ version: String, _ minimum: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0) ?? 0 }
        }
        var a = parts(version)
        var b = parts(minimum)
        let n = max(a.count, b.count)
        while a.count < n { a.append(0) }
        while b.count < n { b.append(0) }
        for i in 0..<n {
            if a[i] != b[i] { return a[i] > b[i] }
        }
        return true
    }

    /// Generates a video: creates the task, lets mmx poll it, and downloads the
    /// finished file to `dest`. Live stderr lines (model/status updates) are
    /// forwarded to `onProgress`.
    @discardableResult
    func videoGenerate(
        apiKey: String,
        model: String,
        prompt: String,
        duration: Int? = nil,
        ratio: String? = nil,
        firstFrame: String? = nil,
        lastFrame: String? = nil,
        dest: URL,
        timeoutSeconds: Int = 1800,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> MmxVideoResult? {
        var args = [
            "video", "generate",
            "--prompt", prompt,
            "--model", model,
            "--download", dest.path,
            "--api-key", apiKey,
            "--region", "global",
            "--output", "json",
            "--non-interactive",
            "--timeout", String(timeoutSeconds),
            "--poll-interval", "5",
        ]
        if let duration { args += ["--duration", String(duration)] }
        if let ratio, !ratio.isEmpty { args += ["--ratio", ratio] }
        if let firstFrame, !firstFrame.isEmpty { args += ["--image", firstFrame] }
        if let lastFrame, !lastFrame.isEmpty { args += ["--last-frame", lastFrame] }

        // Give our watchdog a bit more room than mmx's own timeout.
        let out = try await run(arguments: args, timeoutSeconds: timeoutSeconds + 120,
                                onStderrLine: onProgress)
        return try Self.decodeVideo(out, expectedDest: dest)
    }

    static func decodeVideo(_ out: BLProcessOutput, expectedDest: URL) throws -> MmxVideoResult? {
        var result: MmxVideoResult?
        if let data = BLJSON.extract(out.stdout) {
            let decoder = JSONDecoder()
            if let envelope = try? decoder.decode(BLErrorEnvelope.self, from: data),
               !envelope.error.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw MmxClientError.apiError(code: envelope.error.code,
                                              message: envelope.error.message,
                                              hint: envelope.error.hint)
            }
            result = try? decoder.decode(MmxVideoResult.self, from: data)
        }
        let fileExists = FileManager.default.fileExists(atPath: expectedDest.path)
        if out.exitCode != 0 {
            if let result, result.saved != nil, fileExists { return result }
            throw MmxClientError.nonZeroExit(out.exitCode, stderrTail: BLClient.tail(out.stderr))
        }
        guard fileExists else {
            throw MmxClientError.badOutput(String(out.stdout.prefix(300)))
        }
        return result
    }

    /// Token-plan / remaining quota via `mmx quota show --output json`.
    func quotaShow(apiKey: String, timeoutSeconds: Int = 60) async throws -> MmxQuotaResponse {
        let args = [
            "quota", "show",
            "--api-key", apiKey,
            "--region", "global",
            "--output", "json",
            "--non-interactive",
        ]
        let out = try await run(arguments: args, timeoutSeconds: timeoutSeconds)
        guard let data = BLJSON.extract(out.stdout) else {
            if out.exitCode != 0 {
                throw MmxClientError.nonZeroExit(out.exitCode, stderrTail: BLClient.tail(out.stderr))
            }
            throw MmxClientError.badOutput(String(out.stdout.prefix(300)))
        }
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(BLErrorEnvelope.self, from: data),
           !envelope.error.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MmxClientError.apiError(code: envelope.error.code,
                                          message: envelope.error.message,
                                          hint: envelope.error.hint)
        }
        guard let quota = try? decoder.decode(MmxQuotaResponse.self, from: data) else {
            throw MmxClientError.badOutput(String(out.stdout.prefix(300)))
        }
        return quota
    }

    // MARK: process plumbing (mirrors BLClient)

    private final class Session: @unchecked Sendable {
        let process = Process()
        func terminate() {
            if process.isRunning { process.terminate() }
        }
    }

    func run(
        arguments: [String],
        timeoutSeconds: Int = 300,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> BLProcessOutput {
        let binary = try resolveBinary()
        let session = Session()
        let proc = session.process
        proc.executableURL = binary
        proc.arguments = arguments

        var env = ProcessInfo.processInfo.environment
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

                let timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                    if !Task.isCancelled, proc.isRunning {
                        session.terminate()
                        resume(.failure(MmxClientError.timeout(seconds: timeoutSeconds)))
                    }
                }

                proc.terminationHandler = { p in
                    timeoutTask.cancel()
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
