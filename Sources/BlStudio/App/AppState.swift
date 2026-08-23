import Foundation
import SwiftUI
import Observation

/// Root dependency container shared across the app.
@MainActor
@Observable
final class AppState {
    let client = BLClient()
    let minimax = MiniMaxClient()
    let pollinations = PollinationsClient()
    let gemini = GeminiClient()
    @ObservationIgnored let settingsStore = SettingsStore()
    @ObservationIgnored let keysStore = KeysStore()
    @ObservationIgnored let ledger = UsageLedger()
    @ObservationIgnored let history = HistoryStore()
    @ObservationIgnored let prompts = PromptLibrary()

    var cliVersion: String?
    var authStatus: AuthStatus?
    var statusMessage: String?

    // Feature models
    @ObservationIgnored var generate: GenerateModel!
    @ObservationIgnored var edit: EditModel!
    @ObservationIgnored var chat: ChatModel!
    @ObservationIgnored var video: VideoModel!
    @ObservationIgnored var quota: QuotaModel!

    init() {
        client.binaryOverride = settingsStore.settings.blBinaryPath.nonEmptyOrNil
        generate = GenerateModel(app: self)
        edit = EditModel(app: self)
        chat = ChatModel(app: self)
        video = VideoModel(app: self)
        quota = QuotaModel(app: self)
    }

    func applySettings() {
        client.binaryOverride = settingsStore.settings.blBinaryPath.nonEmptyOrNil
    }

    func refreshStatus() async {
        async let v = try? client.cliVersion()
        async let a = try? client.authStatus()
        cliVersion = await v
        authStatus = await a
    }

    /// Currently selected API key secret (nil → CLI default profile).
    var activeSecret: String? { keysStore.activeSecret }
    var activeKeyId: UUID? { keysStore.activeKeyId }
    var activeKeyLabel: String { keysStore.activeLabel() }

    /// MiniMax key resolution (independent of the Bailian active key).
    var miniMaxConfigured: Bool { keysStore.miniMaxConfigured }
    var miniMaxSecret: String? { keysStore.activeMiniMaxSecret }
    var miniMaxKeyId: UUID? { keysStore.activeMiniMaxMeta?.id }
    var miniMaxKeyLabel: String { keysStore.activeMiniMaxLabel() }

    /// Gemini key resolution (independent of the Bailian active key).
    var geminiConfigured: Bool { keysStore.geminiConfigured }
    var geminiSecret: String? { keysStore.activeGeminiSecret }
    var geminiKeyId: UUID? { keysStore.activeGeminiMeta?.id }
    var geminiKeyLabel: String { keysStore.activeGeminiLabel() }

    func recordUsage(kind: WorkKind, model: String?, images: Int = 0,
                     promptTokens: Int = 0, completionTokens: Int = 0,
                     durationMs: Int, ok: Bool, keyIdOverride: UUID? = nil) {
        ledger.record(UsageEvent(
            keyId: keyIdOverride ?? keysStore.activeKeyId,
            kind: kind, model: model, at: Date(),
            images: images, promptTokens: promptTokens,
            completionTokens: completionTokens,
            durationMs: durationMs, ok: ok))
    }

    /// Unique, prompt-derived filename prefix for saved images.
    nonisolated static func outPrefix(for prompt: String, kind: String) -> String {
        let words = prompt.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let head = words.prefix(3).map { String($0).lowercased() }.joined(separator: "-")
        let stamp = Int(Date().timeIntervalSince1970)
        return head.isEmpty ? "\(kind)-\(stamp)" : "\(head)-\(stamp)"
    }
}

private extension String {
    var nonEmptyOrNil: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - Generate

enum GenPhase: Equatable {
    case idle
    case running
    case done
    case failed(String)
}

/// Validates and parses an optional seed field. Throws with a friendly message.
/// Shared by the Generate and Edit panes.
func parseSeed(enabled: Bool, text: String) throws -> Int? {
    guard enabled else { return nil }
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else {
        throw NSError(domain: "BlStudio", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Seed is enabled but empty. Enter a number or switch it off.",
        ])
    }
    guard let v = Int(t), v >= 0, v <= 2_147_483_647 else {
        throw NSError(domain: "BlStudio", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Seed must be a whole number between 0 and 2147483647.",
        ])
    }
    return v
}

@MainActor
@Observable
final class GenerateModel {
    @ObservationIgnored unowned let app: AppState

    var prompt: String = ""
    var negativePrompt: String = ""
    var model: String = ""
    var size: String = "1:1"
    var customSize: String = ""
    var count: Int = 1
    var seedEnabled = false
    var seedText: String = ""
    var promptExtend: Bool? = nil
    var watermark: Bool? = false
    /// Which backend generates images: "bailian" (bl CLI) or "minimax" (native HTTP).
    var provider: String = KeyProvider.bailian.rawValue
    var activePresets: Set<String> = []

    var phase: GenPhase = .idle
    var progressLine: String = ""
    var lastResult: ImageGenerationResult?
    var lastSavedPaths: [String] = []

    init(app: AppState) { self.app = app }

    var effectiveSize: String {
        size == "custom" ? customSize : size
    }

    func togglePreset(_ preset: PromptPreset) {
        if activePresets.contains(preset.name) {
            activePresets.remove(preset.name)
            removeSuffix(preset.suffix)
        } else {
            activePresets.insert(preset.name)
            appendSuffix(preset.suffix)
        }
    }

    private func appendSuffix(_ suffix: String) {
        let p = prompt.trimmingCharacters(in: .whitespaces)
        prompt = p.isEmpty ? suffix : "\(p), \(suffix)"
    }

    private func removeSuffix(_ suffix: String) {
        prompt = prompt
            .replacingOccurrences(of: ", \(suffix)", with: "")
            .replacingOccurrences(of: suffix, with: "")
    }

    /// Fills the seed field with a random valid value and turns the seed on.
    func randomizeSeed() {
        seedText = String(Int.random(in: 0...2_147_483_647))
        seedEnabled = true
    }

    // MARK: AI prompt assistance

    var enhancing = false
    var enhanceSuggestion: String?
    var enhanceError: String?

    private static let enhanceSystem = """
    You are an expert at writing prompts for text-to-image models. \
    Rewrite the user's idea into a clearer, more vivid, more detailed image prompt \
    that preserves their subject and intent. Keep it to one to three sentences. \
    Respond with only the improved prompt text. No preamble, no quotes, no explanation.
    """

    /// Asks the configured chat model to rewrite the current prompt into a
    /// stronger image-generation prompt. The result is surfaced as a suggestion
    /// (`enhanceSuggestion`) rather than applied automatically.
    func enhancePrompt() async {
        let current = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty, !enhancing else { return }
        enhancing = true
        enhanceSuggestion = nil
        enhanceError = nil
        defer { enhancing = false }

        let settings = app.settingsStore.settings
        var req = ChatRequest(message: current)
        req.model = settings.defaultChatModel.nonEmptyOrNil
        req.system = Self.enhanceSystem
        req.maxTokens = 500

        let started = Date()
        do {
            let completion = try await app.client.textChat(req, apiKey: app.activeSecret)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            app.recordUsage(kind: .chat, model: req.model,
                            promptTokens: completion.usage?.prompt_tokens ?? 0,
                            completionTokens: completion.usage?.completion_tokens ?? 0,
                            durationMs: ms, ok: true)
            let improved = completion.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if improved.isEmpty {
                enhanceError = "The model returned an empty suggestion."
            } else {
                enhanceSuggestion = improved
            }
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            app.recordUsage(kind: .chat, model: req.model, durationMs: ms, ok: false)
            enhanceError = error.localizedDescription
        }
    }

    var canRun: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && phase != .running
    }

    var isMiniMax: Bool { provider == KeyProvider.minimax.rawValue }
    var isPollinations: Bool { provider == KeyProvider.pollinations.rawValue }
    var isGemini: Bool { provider == KeyProvider.gemini.rawValue }

    func generate() async {
        if isMiniMax {
            await generateMiniMax()
            return
        }
        if isPollinations {
            await generatePollinations()
            return
        }
        if isGemini {
            await generateGemini()
            return
        }
        guard canRun else { return }

        let seedValue: Int?
        do {
            seedValue = try parseSeed(enabled: seedEnabled, text: seedText)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        phase = .running
        progressLine = "Starting…"
        lastResult = nil
        lastSavedPaths = []

        let settings = app.settingsStore.settings
        let outDir = settings.libraryURL
        AppPaths.ensureDir(outDir)

        var req = ImageGenRequest(prompt: composedPrompt)
        req.model = model.nonEmptyOrNil
        req.size = effectiveSize.nonEmptyOrNil
        req.n = 1
        req.seed = seedValue
        req.negativePrompt = negativePrompt.nonEmptyOrNil
        req.promptExtend = promptExtend
        req.watermark = watermark

        let started = Date()
        do {
            let result: ImageGenerationResult
            if count <= 1 {
                result = try await app.client.imageGenerate(
                    req, outDir: outDir,
                    outPrefix: AppState.outPrefix(for: prompt, kind: "img"),
                    apiKey: app.activeSecret,
                    pollInterval: settings.pollInterval,
                    timeoutSeconds: settings.requestTimeout,
                    onProgress: { [weak self] line in
                        Task { @MainActor in self?.progressLine = line }
                    })
            } else {
                result = try await generateFanOut(
                    req, count: count, seed: seedValue, outDir: outDir,
                    pollInterval: settings.pollInterval,
                    timeoutSeconds: settings.requestTimeout)
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            lastResult = result
            lastSavedPaths = result.saved
            phase = .done
            app.recordUsage(kind: .imageGenerate, model: req.model, images: result.total,
                            durationMs: ms, ok: true)
            app.history.add(HistoryEntry(
                kind: .imageGenerate, prompt: composedPrompt, model: req.model,
                keyId: app.activeKeyId, keyLabel: app.activeKeyLabel,
                savedPaths: result.saved, remoteUrls: result.urls,
                taskId: result.task_id ?? result.task_ids?.first,
                durationMs: ms, ok: true, detail: nil))
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            phase = .failed(error.localizedDescription)
            app.recordUsage(kind: .imageGenerate, model: req.model, durationMs: ms, ok: false)
            app.history.add(HistoryEntry(
                kind: .imageGenerate, prompt: composedPrompt, model: req.model,
                keyId: app.activeKeyId, keyLabel: app.activeKeyLabel,
                savedPaths: [], remoteUrls: [], taskId: nil,
                durationMs: ms, ok: false, detail: error.localizedDescription))
        }
    }

    /// Generates images through the MiniMax HTTP API directly (no `bl` CLI).
    /// MiniMax supports a native batch of up to 9 images per request, so no
    /// fan-out is needed. Seed, negative prompt, and watermark are not part of
    /// the MiniMax API and are ignored here.
    private func generateMiniMax() async {
        guard canRun else { return }
        guard let apiKey = app.miniMaxSecret else {
            phase = .failed("No MiniMax API key configured. Add one in the API Keys tab and set its provider to MiniMax.")
            return
        }

        let ratio = ModelCatalog.minimaxAspectRatios.contains(size) ? size : "1:1"
        let modelUsed = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "image-01" : model
        let displayModel = "MiniMax \(modelUsed)"
        let promptText = composedPrompt

        phase = .running
        progressLine = "Contacting MiniMax…"
        lastResult = nil
        lastSavedPaths = []

        let outDir = app.settingsStore.settings.libraryURL
        AppPaths.ensureDir(outDir)
        let prefix = AppState.outPrefix(for: prompt, kind: "img")
        let started = Date()

        do {
            let urls = try await app.minimax.generate(
                apiKey: apiKey,
                prompt: promptText,
                n: count,
                aspectRatio: ratio,
                promptOptimizer: promptExtend ?? true,
                model: modelUsed)
            var saved: [String] = []
            for (i, u) in urls.enumerated() {
                progressLine = "Downloading image \(i + 1)/\(urls.count)…"
                let dest = try await app.minimax.downloadImage(u, to: outDir, prefix: prefix, index: i + 1)
                saved.append(dest.path)
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            lastSavedPaths = saved
            phase = .done
            app.recordUsage(kind: .imageGenerate, model: displayModel, images: saved.count,
                            durationMs: ms, ok: true, keyIdOverride: app.miniMaxKeyId)
            app.history.add(HistoryEntry(
                kind: .imageGenerate, prompt: promptText, model: displayModel,
                keyId: app.miniMaxKeyId, keyLabel: app.miniMaxKeyLabel,
                savedPaths: saved, remoteUrls: urls,
                taskId: nil, durationMs: ms, ok: true, detail: nil))
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            phase = .failed(error.localizedDescription)
            app.recordUsage(kind: .imageGenerate, model: displayModel,
                            durationMs: ms, ok: false, keyIdOverride: app.miniMaxKeyId)
            app.history.add(HistoryEntry(
                kind: .imageGenerate, prompt: promptText, model: displayModel,
                keyId: app.miniMaxKeyId, keyLabel: app.miniMaxKeyLabel,
                savedPaths: [], remoteUrls: [], taskId: nil,
                durationMs: ms, ok: false, detail: error.localizedDescription))
        }
    }

    /// Generates images through Pollinations.ai (free, no API key). Each image is
    /// a separate request; a base seed is offset per image so batches stay distinct.
    private func generatePollinations() async {
        guard canRun else { return }

        let ratio = ModelCatalog.freeAspectRatios.contains(size) ? size : "1:1"
        let (w, h) = ModelCatalog.pixelSize(forAspectRatio: ratio)
        let modelUsed = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "flux" : model
        let displayModel = "Pollinations \(modelUsed)"
        let promptText = composedPrompt

        let baseSeed: Int
        do {
            if let p = try parseSeed(enabled: seedEnabled, text: seedText) {
                baseSeed = p
            } else {
                baseSeed = Int.random(in: 0...2_147_483_647)
            }
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        phase = .running
        progressLine = "Contacting Pollinations…"
        lastResult = nil
        lastSavedPaths = []

        let outDir = app.settingsStore.settings.libraryURL
        AppPaths.ensureDir(outDir)
        let prefix = AppState.outPrefix(for: prompt, kind: "img")
        let started = Date()

        do {
            var saved: [String] = []
            let total = max(1, count)
            for i in 0..<total {
                progressLine = "Generating image \(i + 1)/\(total)…"
                let dest = outDir.appendingPathComponent("\(prefix)-\(i + 1).jpg")
                let url = try await app.pollinations.generate(
                    prompt: promptText, model: modelUsed,
                    width: w, height: h, seed: baseSeed + i, dest: dest)
                saved.append(url.path)
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            lastSavedPaths = saved
            phase = .done
            app.ledger.record(UsageEvent(
                keyId: nil, kind: .imageGenerate, model: displayModel, at: Date(),
                images: saved.count, promptTokens: 0, completionTokens: 0,
                durationMs: ms, ok: true))
            app.history.add(HistoryEntry(
                kind: .imageGenerate, prompt: promptText, model: displayModel,
                keyId: nil, keyLabel: "Pollinations (no key)",
                savedPaths: saved, remoteUrls: [], taskId: nil,
                durationMs: ms, ok: true, detail: nil))
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            phase = .failed(error.localizedDescription)
            app.ledger.record(UsageEvent(
                keyId: nil, kind: .imageGenerate, model: displayModel, at: Date(),
                images: 0, promptTokens: 0, completionTokens: 0,
                durationMs: ms, ok: false))
            app.history.add(HistoryEntry(
                kind: .imageGenerate, prompt: promptText, model: displayModel,
                keyId: nil, keyLabel: "Pollinations (no key)",
                savedPaths: [], remoteUrls: [], taskId: nil,
                durationMs: ms, ok: false, detail: error.localizedDescription))
        }
    }

    /// Generates images through Google Gemini (free AI Studio key). Each call
    /// returns one image, so the requested count is produced sequentially.
    private func generateGemini() async {
        guard canRun else { return }
        guard let apiKey = app.geminiSecret else {
            phase = .failed("No Gemini API key configured. Add a free Google AI Studio key in the API Keys tab and set its provider to Google Gemini.")
            return
        }

        let ratio = ModelCatalog.freeAspectRatios.contains(size) ? size : "1:1"
        let modelUsed = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "gemini-2.5-flash-image" : model
        let displayModel = "Gemini \(modelUsed)"
        let promptText = composedPrompt

        phase = .running
        progressLine = "Contacting Gemini…"
        lastResult = nil
        lastSavedPaths = []

        let outDir = app.settingsStore.settings.libraryURL
        AppPaths.ensureDir(outDir)
        let prefix = AppState.outPrefix(for: prompt, kind: "img")
        let started = Date()

        do {
            var saved: [String] = []
            let total = max(1, count)
            for i in 0..<total {
                progressLine = "Generating image \(i + 1)/\(total)…"
                let dest = outDir.appendingPathComponent("\(prefix)-\(i + 1).png")
                let url = try await app.gemini.generate(
                    apiKey: apiKey, model: modelUsed, prompt: promptText,
                    aspectRatio: ratio, dest: dest)
                saved.append(url.path)
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            lastSavedPaths = saved
            phase = .done
            app.recordUsage(kind: .imageGenerate, model: displayModel, images: saved.count,
                            durationMs: ms, ok: true, keyIdOverride: app.geminiKeyId)
            app.history.add(HistoryEntry(
                kind: .imageGenerate, prompt: promptText, model: displayModel,
                keyId: app.geminiKeyId, keyLabel: app.geminiKeyLabel,
                savedPaths: saved, remoteUrls: [], taskId: nil,
                durationMs: ms, ok: true, detail: nil))
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            phase = .failed(error.localizedDescription)
            app.recordUsage(kind: .imageGenerate, model: displayModel,
                            durationMs: ms, ok: false, keyIdOverride: app.geminiKeyId)
            app.history.add(HistoryEntry(
                kind: .imageGenerate, prompt: promptText, model: displayModel,
                keyId: app.geminiKeyId, keyLabel: app.geminiKeyLabel,
                savedPaths: [], remoteUrls: [], taskId: nil,
                durationMs: ms, ok: false, detail: error.localizedDescription))
        }
    }

    /// Several image models (incl. the default qwen-image-3.0) ignore the batch
    /// parameter `n` and return a single image per request. To honor the requested
    /// count anyway, run N parallel single-image requests. This is the same approach as
    /// `bl image generate --concurrent N`. Seeds are offset per image so a fixed
    /// seed still yields N distinct, reproducible results.
    private func generateFanOut(
        _ req: ImageGenRequest,
        count: Int,
        seed: Int?,
        outDir: URL,
        pollInterval: Int,
        timeoutSeconds: Int
    ) async throws -> ImageGenerationResult {
        let basePrefix = AppState.outPrefix(for: prompt, kind: "img")
        let apiKey = app.activeSecret
        let client = app.client

        return try await withThrowingTaskGroup(of: (Int, ImageGenerationResult).self) { group in
            for index in 0..<count {
                var sub = req
                if let seed { sub.seed = seed + index }
                group.addTask { [weak self] in
                    let me = self
                    let result = try await client.imageGenerate(
                        sub, outDir: outDir,
                        outPrefix: "\(basePrefix)-\(index + 1)",
                        apiKey: apiKey,
                        pollInterval: pollInterval,
                        timeoutSeconds: timeoutSeconds,
                        onProgress: { line in
                            Task { @MainActor in
                                me?.progressLine = "Image \(index + 1)/\(count). \(line)"
                            }
                        })
                    return (index, result)
                }
            }

            var collected: [(Int, ImageGenerationResult)] = []
            for try await item in group {
                collected.append(item)
            }
            collected.sort { $0.0 < $1.0 }

            var saved: [String] = []
            var urls: [String] = []
            var taskIds: [String] = []
            var total = 0
            for (_, r) in collected {
                saved.append(contentsOf: r.saved)
                urls.append(contentsOf: r.urls)
                total += r.total
                if let t = r.task_id { taskIds.append(t) }
                if let t = r.task_ids { taskIds.append(contentsOf: t) }
            }
            return ImageGenerationResult(urls: urls, saved: saved, total: total,
                                         task_id: nil,
                                         task_ids: taskIds.isEmpty ? nil : taskIds)
        }
    }

    private var composedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Edit

@MainActor
@Observable
final class EditModel {
    @ObservationIgnored unowned let app: AppState

    var sources: [URL] = []
    var prompt: String = ""
    var negativePrompt: String = ""
    var model: String = ""
    var size: String = ""
    var count: Int = 1
    var editFunction: String = ""
    var seedEnabled = false
    var seedText: String = ""

    var phase: GenPhase = .idle
    var progressLine: String = ""
    var lastSavedPaths: [String] = []

    init(app: AppState) { self.app = app }

    var canRun: Bool {
        !sources.isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && phase != .running
    }

    func addSources(_ urls: [URL]) {
        for u in urls {
            guard !sources.contains(u) else { continue }
            _ = u.startAccessingSecurityScopedResource()
            sources.append(u)
        }
    }

    func removeSource(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
        sources.removeAll { $0 == url }
    }

    /// Fills the seed field with a random valid value and turns the seed on.
    func randomizeSeed() {
        seedText = String(Int.random(in: 0...2_147_483_647))
        seedEnabled = true
    }

    func generate() async {
        guard canRun else { return }

        let seedValue: Int?
        do {
            seedValue = try parseSeed(enabled: seedEnabled, text: seedText)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        phase = .running
        progressLine = "Starting…"
        lastSavedPaths = []

        let settings = app.settingsStore.settings
        let outDir = settings.libraryURL
        AppPaths.ensureDir(outDir)

        var req = ImageEditRequest(sources: sources, prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        req.model = model.nonEmptyOrNil
        req.size = size.nonEmptyOrNil
        req.n = 1
        req.seed = seedValue
        req.negativePrompt = negativePrompt.nonEmptyOrNil
        req.function = editFunction.nonEmptyOrNil

        let started = Date()
        do {
            let result: ImageGenerationResult
            if count <= 1 {
                result = try await app.client.imageEdit(
                    req, outDir: outDir,
                    outPrefix: AppState.outPrefix(for: prompt, kind: "edit"),
                    apiKey: app.activeSecret,
                    pollInterval: settings.pollInterval,
                    timeoutSeconds: settings.requestTimeout,
                    onProgress: { [weak self] line in
                        Task { @MainActor in self?.progressLine = line }
                    })
            } else {
                result = try await editFanOut(
                    req, count: count, seed: seedValue, outDir: outDir,
                    pollInterval: settings.pollInterval,
                    timeoutSeconds: settings.requestTimeout)
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            lastSavedPaths = result.saved
            phase = .done
            app.recordUsage(kind: .imageEdit, model: req.model, images: result.total,
                            durationMs: ms, ok: true)
            app.history.add(HistoryEntry(
                kind: .imageEdit, prompt: req.prompt, model: req.model,
                keyId: app.activeKeyId, keyLabel: app.activeKeyLabel,
                savedPaths: result.saved, remoteUrls: result.urls,
                taskId: result.task_id ?? result.task_ids?.first,
                durationMs: ms, ok: true,
                detail: "sources: " + sources.map(\.lastPathComponent).joined(separator: ", ")))
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            phase = .failed(error.localizedDescription)
            app.recordUsage(kind: .imageEdit, model: req.model, durationMs: ms, ok: false)
            app.history.add(HistoryEntry(
                kind: .imageEdit, prompt: req.prompt, model: req.model,
                keyId: app.activeKeyId, keyLabel: app.activeKeyLabel,
                savedPaths: [], remoteUrls: [], taskId: nil,
                durationMs: ms, ok: false, detail: error.localizedDescription))
        }
    }

    /// Same fan-out rationale as Generate: several image models return one image
    /// per request regardless of `n`, so run N parallel single-image edit requests.
    private func editFanOut(
        _ req: ImageEditRequest,
        count: Int,
        seed: Int?,
        outDir: URL,
        pollInterval: Int,
        timeoutSeconds: Int
    ) async throws -> ImageGenerationResult {
        let basePrefix = AppState.outPrefix(for: prompt, kind: "edit")
        let apiKey = app.activeSecret
        let client = app.client

        return try await withThrowingTaskGroup(of: (Int, ImageGenerationResult).self) { group in
            for index in 0..<count {
                var sub = req
                if let seed { sub.seed = seed + index }
                group.addTask { [weak self] in
                    let me = self
                    let result = try await client.imageEdit(
                        sub, outDir: outDir,
                        outPrefix: "\(basePrefix)-\(index + 1)",
                        apiKey: apiKey,
                        pollInterval: pollInterval,
                        timeoutSeconds: timeoutSeconds,
                        onProgress: { line in
                            Task { @MainActor in
                                me?.progressLine = "Image \(index + 1)/\(count). \(line)"
                            }
                        })
                    return (index, result)
                }
            }

            var collected: [(Int, ImageGenerationResult)] = []
            for try await item in group {
                collected.append(item)
            }
            collected.sort { $0.0 < $1.0 }

            var saved: [String] = []
            var urls: [String] = []
            var taskIds: [String] = []
            var total = 0
            for (_, r) in collected {
                saved.append(contentsOf: r.saved)
                urls.append(contentsOf: r.urls)
                total += r.total
                if let t = r.task_id { taskIds.append(t) }
                if let t = r.task_ids { taskIds.append(contentsOf: t) }
            }
            return ImageGenerationResult(urls: urls, saved: saved, total: total,
                                         task_id: nil,
                                         task_ids: taskIds.isEmpty ? nil : taskIds)
        }
    }
}

// MARK: - Video

@MainActor
@Observable
final class VideoModel {
    @ObservationIgnored unowned let app: AppState

    /// "bailian" or "minimax".
    var provider: String = KeyProvider.bailian.rawValue
    /// "t2v" or "i2v".
    var mode: String = "t2v"
    var prompt: String = ""
    var model: String = ""
    var imageURL: String = ""          // i2v source for Bailian (must be a URL)
    var i2vFileURL: URL? = nil         // i2v source for MiniMax (local file)
    var resolution: String = "1080P"
    var ratio: String = "16:9"
    var duration: Int = 5
    var seedEnabled = false
    var seedText: String = ""
    var promptExtend: Bool? = nil
    var watermark: Bool? = false

    var phase: GenPhase = .idle
    var progressLine: String = ""
    var lastSavedPath: String? = nil

    init(app: AppState) { self.app = app }

    var isMiniMax: Bool { provider == KeyProvider.minimax.rawValue }

    var canRun: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && phase != .running
    }

    func randomizeSeed() {
        seedText = String(Int.random(in: 0...2_147_483_647))
        seedEnabled = true
    }

    func generate() async {
        if isMiniMax {
            await generateMiniMax()
        } else {
            await generateBailian()
        }
    }

    private func generateBailian() async {
        guard canRun else { return }
        let seedValue: Int?
        do {
            seedValue = try parseSeed(enabled: seedEnabled, text: seedText)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        phase = .running
        progressLine = "Starting…"
        lastSavedPath = nil

        let settings = app.settingsStore.settings
        let outDir = settings.libraryURL
        AppPaths.ensureDir(outDir)
        let promptText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let outPath = outDir.appendingPathComponent("\(AppState.outPrefix(for: prompt, kind: "vid")).mp4")

        var req = VideoGenRequest(prompt: promptText)
        req.imageURL = mode == "i2v" ? imageURL.nonEmptyOrNil : nil
        req.model = model.nonEmptyOrNil
        req.resolution = resolution.nonEmptyOrNil
        req.ratio = ratio.nonEmptyOrNil
        req.duration = duration
        req.seed = seedValue
        req.promptExtend = promptExtend
        req.watermark = watermark

        let started = Date()
        do {
            let out = try await app.client.videoGenerate(
                req, outPath: outPath, apiKey: app.activeSecret,
                pollInterval: max(3, settings.pollInterval),
                timeoutSeconds: settings.requestTimeout,
                onProgress: { [weak self] line in
                    Task { @MainActor in self?.progressLine = line }
                })
            guard FileManager.default.fileExists(atPath: outPath.path) else {
                throw NSError(domain: "BlStudio", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "bl finished but no video file was saved.",
                ])
            }
            let decoded = try? BLClient.decode(VideoGenerationResult.self, from: out)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            lastSavedPath = outPath.path
            phase = .done
            app.recordUsage(kind: .videoGenerate, model: req.model ?? "video",
                            durationMs: ms, ok: true)
            app.history.add(HistoryEntry(
                kind: .videoGenerate, prompt: promptText, model: req.model,
                keyId: app.activeKeyId, keyLabel: app.activeKeyLabel,
                savedPaths: [outPath.path],
                remoteUrls: (decoded?.video_url).map { [$0] } ?? [],
                taskId: decoded?.task_id,
                durationMs: ms, ok: true, detail: nil))
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            phase = .failed(error.localizedDescription)
            app.recordUsage(kind: .videoGenerate, model: req.model ?? "video",
                            durationMs: ms, ok: false)
            app.history.add(HistoryEntry(
                kind: .videoGenerate, prompt: promptText, model: req.model,
                keyId: app.activeKeyId, keyLabel: app.activeKeyLabel,
                savedPaths: [], remoteUrls: [], taskId: nil,
                durationMs: ms, ok: false, detail: error.localizedDescription))
        }
    }

    private func generateMiniMax() async {
        guard canRun else { return }
        guard let apiKey = app.miniMaxSecret else {
            phase = .failed("No MiniMax API key configured. Add one in the API Keys tab and set its provider to MiniMax.")
            return
        }

        phase = .running
        progressLine = "Contacting MiniMax…"
        lastSavedPath = nil

        let promptText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let outDir = app.settingsStore.settings.libraryURL
        AppPaths.ensureDir(outDir)
        let dest = outDir.appendingPathComponent("\(AppState.outPrefix(for: prompt, kind: "vid")).mp4")

        // MiniMax accepts the first frame as a URL or a data: URI.
        var firstFrame: String? = nil
        if mode == "i2v" {
            if let f = i2vFileURL, let data = try? Data(contentsOf: f) {
                let mime: String
                switch f.pathExtension.lowercased() {
                case "png": mime = "image/png"
                case "webp": mime = "image/webp"
                case "gif": mime = "image/gif"
                default: mime = "image/jpeg"
                }
                firstFrame = "data:\(mime);base64," + data.base64EncodedString()
            } else {
                firstFrame = imageURL.nonEmptyOrNil
            }
        }

        let effectiveModel: String
        if !model.trimmingCharacters(in: .whitespaces).isEmpty {
            effectiveModel = model
        } else {
            effectiveModel = mode == "i2v" ? "I2V-01" : "MiniMax-Hailuo-2.3"
        }
        let isHailuo = effectiveModel.contains("Hailuo")
        let displayModel = "MiniMax \(effectiveModel)"

        let started = Date()
        do {
            let saved = try await app.minimax.generateVideoAndWait(
                apiKey: apiKey,
                model: effectiveModel,
                prompt: promptText,
                firstFrameImage: firstFrame,
                duration: isHailuo ? duration : nil,
                resolution: isHailuo ? resolution : nil,
                dest: dest,
                pollSeconds: 10,
                onStatus: { [weak self] line in
                    Task { @MainActor in self?.progressLine = line }
                })
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            lastSavedPath = saved.path
            phase = .done
            app.recordUsage(kind: .videoGenerate, model: displayModel,
                            durationMs: ms, ok: true, keyIdOverride: app.miniMaxKeyId)
            app.history.add(HistoryEntry(
                kind: .videoGenerate, prompt: promptText, model: displayModel,
                keyId: app.miniMaxKeyId, keyLabel: app.miniMaxKeyLabel,
                savedPaths: [saved.path], remoteUrls: [], taskId: nil,
                durationMs: ms, ok: true, detail: nil))
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            phase = .failed(error.localizedDescription)
            app.recordUsage(kind: .videoGenerate, model: displayModel,
                            durationMs: ms, ok: false, keyIdOverride: app.miniMaxKeyId)
            app.history.add(HistoryEntry(
                kind: .videoGenerate, prompt: promptText, model: displayModel,
                keyId: app.miniMaxKeyId, keyLabel: app.miniMaxKeyLabel,
                savedPaths: [], remoteUrls: [], taskId: nil,
                durationMs: ms, ok: false, detail: error.localizedDescription))
        }
    }
}

// MARK: - Chat

struct ChatMessage: Identifiable, Sendable {
    enum Role: String, Sendable { case user, assistant, system }
    var id = UUID()
    let role: Role
    var content: String
    var model: String? = nil
    var promptTokens: Int? = nil
    var completionTokens: Int? = nil
    var reasoning: String? = nil
    var error: Bool = false
}

@MainActor
@Observable
final class ChatModel {
    @ObservationIgnored unowned let app: AppState

    var messages: [ChatMessage] = []
    var draft: String = ""
    var model: String = ""
    var systemPrompt: String = ""
    var maxTokens: Int = 4096
    var busy = false

    init(app: AppState) { self.app = app }

    var canSend: Bool {
        !busy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() async {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        messages.append(ChatMessage(role: .user, content: text))
        busy = true
        defer { busy = false }

        var req = ChatRequest(message: text)
        req.model = model.nonEmptyOrNil
        req.system = systemPrompt.nonEmptyOrNil
        req.maxTokens = maxTokens

        let started = Date()
        do {
            let completion = try await app.client.textChat(req, apiKey: app.activeSecret)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            var reply = ChatMessage(role: .assistant, content: completion.content,
                                    model: completion.model)
            reply.promptTokens = completion.usage?.prompt_tokens
            reply.completionTokens = completion.usage?.completion_tokens
            reply.reasoning = completion.reasoning
            messages.append(reply)
            app.recordUsage(kind: .chat, model: req.model,
                            promptTokens: reply.promptTokens ?? 0,
                            completionTokens: reply.completionTokens ?? 0,
                            durationMs: ms, ok: true)
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            messages.append(ChatMessage(role: .assistant,
                                        content: error.localizedDescription, error: true))
            app.recordUsage(kind: .chat, model: req.model, durationMs: ms, ok: false)
        }
    }
}

// MARK: - Quota

@MainActor
@Observable
final class QuotaModel {
    @ObservationIgnored unowned let app: AppState

    var freeQuotas: [FreeTierQuota] = []
    var rateUsages: [RateUsage] = []
    var quotaError: String?
    var loading = false
    var lastRefreshed: Date?

    init(app: AppState) { self.app = app }

    func refresh() async {
        loading = true
        quotaError = nil
        defer { loading = false; lastRefreshed = Date() }
        do {
            async let f = app.client.usageFree()
            async let r = app.client.quotaCheck()
            freeQuotas = (try? await f) ?? []
            rateUsages = (try? await r) ?? []
            if freeQuotas.isEmpty && rateUsages.isEmpty {
                // Surface a useful message: rerun sequentially to capture the error.
                do { _ = try await app.client.usageFree() }
                catch { quotaError = error.localizedDescription }
            }
        }
    }
}
