import Foundation

/// Typed wrappers around individual `bl` commands.
extension BLClient {

    // MARK: Image

    func imageGenerate(
        _ req: ImageGenRequest,
        outDir: URL,
        outPrefix: String,
        apiKey: String?,
        pollInterval: Int = 3,
        timeoutSeconds: Int = 900,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ImageGenerationResult {
        var args = ["image", "generate", "--prompt", req.prompt]
        args += imageCommonFlags(model: req.model, size: req.size, n: req.n, seed: req.seed,
                                 negativePrompt: req.negativePrompt,
                                 promptExtend: req.promptExtend, watermark: req.watermark)
        args += ["--out-dir", outDir.path, "--out-prefix", outPrefix,
                 "--poll-interval", String(pollInterval),
                 "--timeout", String(timeoutSeconds)]
        if let apiKey, !apiKey.isEmpty { args += ["--api-key", apiKey] }
        return try await runJSON(ImageGenerationResult.self, arguments: args,
                                 timeoutSeconds: timeoutSeconds + 60, onStderrLine: onProgress)
    }

    func imageEdit(
        _ req: ImageEditRequest,
        outDir: URL,
        outPrefix: String,
        apiKey: String?,
        pollInterval: Int = 3,
        timeoutSeconds: Int = 900,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ImageGenerationResult {
        var args = ["image", "edit"]
        for src in req.sources { args += ["--image", src.isFileURL ? src.path : src.absoluteString] }
        args += ["--prompt", req.prompt]
        args += imageCommonFlags(model: req.model, size: req.size, n: req.n, seed: req.seed,
                                 negativePrompt: req.negativePrompt,
                                 promptExtend: req.promptExtend, watermark: req.watermark)
        if let f = req.function, !f.isEmpty { args += ["--function", f] }
        args += ["--out-dir", outDir.path, "--out-prefix", outPrefix,
                 "--poll-interval", String(pollInterval),
                 "--timeout", String(timeoutSeconds)]
        if let apiKey, !apiKey.isEmpty { args += ["--api-key", apiKey] }
        return try await runJSON(ImageGenerationResult.self, arguments: args,
                                 timeoutSeconds: timeoutSeconds + 60, onStderrLine: onProgress)
    }

    private func imageCommonFlags(
        model: String?, size: String?, n: Int, seed: Int?,
        negativePrompt: String?, promptExtend: Bool?, watermark: Bool?
    ) -> [String] {
        var args: [String] = []
        if let model, !model.isEmpty { args += ["--model", model] }
        if let size, !size.isEmpty { args += ["--size", size] }
        args += ["--n", String(max(1, min(6, n)))]
        if let seed { args += ["--seed", String(seed)] }
        if let negativePrompt, !negativePrompt.isEmpty { args += ["--negative-prompt", negativePrompt] }
        if let promptExtend { args += ["--prompt-extend", promptExtend ? "true" : "false"] }
        if let watermark { args += ["--watermark", watermark ? "true" : "false"] }
        return args
    }

    // MARK: Text chat

    func textChat(
        _ req: ChatRequest,
        apiKey: String?,
        timeoutSeconds: Int = 300
    ) async throws -> ChatCompletion {
        var args = ["text", "chat", "--message", req.message]
        if let model = req.model, !model.isEmpty { args += ["--model", model] }
        if let system = req.system, !system.isEmpty { args += ["--system", system] }
        if let maxTokens = req.maxTokens { args += ["--max-tokens", String(maxTokens)] }
        if let t = req.temperature { args += ["--temperature", String(t)] }
        if let apiKey, !apiKey.isEmpty { args += ["--api-key", apiKey] }
        args += ["--timeout", String(timeoutSeconds)]
        return try await runJSON(ChatCompletion.self, arguments: args,
                                 timeoutSeconds: timeoutSeconds + 30)
    }

    // MARK: Vision

    func visionDescribe(
        imagePath: String,
        prompt: String?,
        model: String?,
        apiKey: String?,
        timeoutSeconds: Int = 180
    ) async throws -> String {
        var args = ["vision", "describe", "--image", imagePath, "--quiet"]
        if let prompt, !prompt.isEmpty { args += ["--prompt", prompt] }
        if let model, !model.isEmpty { args += ["--model", model] }
        if let apiKey, !apiKey.isEmpty { args += ["--api-key", apiKey] }
        let out = try await run(arguments: args, timeoutSeconds: timeoutSeconds)
        guard out.exitCode == 0 else {
            if let decoded = try? Self.decode(BLErrorEnvelope.self, from: out) {
                throw BLClientError.apiError(code: nil, message: decoded.error.message, hint: decoded.error.hint)
            }
            throw BLClientError.nonZeroExit(out.exitCode, stderrTail: Self.tail(out.stderr))
        }
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Account / quota

    func authStatus(timeoutSeconds: Int = 60) async throws -> AuthStatus {
        try await runJSON(AuthStatus.self, arguments: ["auth", "status"],
                          timeoutSeconds: timeoutSeconds)
    }

    func configList(timeoutSeconds: Int = 30) async throws -> ConfigList {
        try await runJSON(ConfigList.self, arguments: ["config", "list"],
                          timeoutSeconds: timeoutSeconds)
    }

    func usageFree(timeoutSeconds: Int = 120) async throws -> [FreeTierQuota] {
        try await runJSON([FreeTierQuota].self, arguments: ["usage", "free", "--all"],
                          timeoutSeconds: timeoutSeconds)
    }

    func quotaCheck(timeoutSeconds: Int = 120) async throws -> [RateUsage] {
        try await runJSON([RateUsage].self, arguments: ["quota", "check"],
                          timeoutSeconds: timeoutSeconds)
    }

    func quotaList(timeoutSeconds: Int = 120) async throws -> [RateLimit] {
        try await runJSON([RateLimit].self, arguments: ["quota", "list"],
                          timeoutSeconds: timeoutSeconds)
    }

    func cliVersion(timeoutSeconds: Int = 20) async throws -> String {
        let out = try await run(arguments: ["--version"], timeoutSeconds: timeoutSeconds)
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
