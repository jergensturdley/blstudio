import Foundation
import SwiftUI
import Observation

/// Root dependency container shared across the app.
@MainActor
@Observable
final class AppState {
    let client = BLClient()
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
    @ObservationIgnored var quota: QuotaModel!

    init() {
        client.binaryOverride = settingsStore.settings.blBinaryPath.nonEmptyOrNil
        generate = GenerateModel(app: self)
        edit = EditModel(app: self)
        chat = ChatModel(app: self)
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

    func recordUsage(kind: WorkKind, model: String?, images: Int = 0,
                     promptTokens: Int = 0, completionTokens: Int = 0,
                     durationMs: Int, ok: Bool) {
        ledger.record(UsageEvent(
            keyId: keysStore.activeKeyId,
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
    var watermark: Bool? = nil
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

    var canRun: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && phase != .running
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
