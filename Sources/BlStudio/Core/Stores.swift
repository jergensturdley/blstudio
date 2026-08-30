import Foundation
import Observation
import Security

/// Central locations for app data.
enum AppPaths {
    static var appSupport: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BlStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static var settingsFile: URL { appSupport.appendingPathComponent("settings.json") }
    static var keysFile: URL { appSupport.appendingPathComponent("keys.json") }
    static var usageFile: URL { appSupport.appendingPathComponent("usage.jsonl") }
    static var historyFile: URL { appSupport.appendingPathComponent("history.json") }
    static var favoritesFile: URL { appSupport.appendingPathComponent("favorites.json") }
    static var negativeFavoritesFile: URL { appSupport.appendingPathComponent("negative-favorites.json") }

    /// Default directory where generated images are stored.
    static var defaultImageLibrary: URL {
        let pics = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        return pics.appendingPathComponent("BlStudio", isDirectory: true)
    }

    static func ensureDir(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Test helper: a throwaway usage-file location.
    static func makeTempUsageFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("blstudio-test-\(UUID().uuidString).jsonl")
    }
}

// MARK: - Settings

struct AppSettings: Codable, Sendable {
    var blBinaryPath: String = ""          // empty → auto-detect
    /// Optional so settings files written before the mmx integration decode cleanly.
    var mmxBinaryPath: String? = nil       // empty/nil → auto-detect (mmx CLI for MiniMax video/quota)
    var imageLibraryDir: String = ""       // empty → ~/Pictures/BlStudio
    var defaultImageModel: String = ""     // empty → bl default (qwen-image-3.0)
    var defaultChatModel: String = ""
    var defaultSize: String = "1:1"
    var pollInterval: Int = 3
    var requestTimeout: Int = 900
    /// Providers the user switched off in Settings (raw values). Optional so
    /// older settings files decode cleanly; nil/absent means everything is on.
    var disabledProviders: [String]? = nil
    /// Provider → preferred API key id. Used by the per-provider resolution
    /// in KeysStore; absent means "no preference, fall back to the first key
    /// of that provider". Optional for backward compatibility.
    var preferredKeyByProvider: [String: UUID]? = nil

    var libraryURL: URL {
        if imageLibraryDir.isEmpty { return AppPaths.defaultImageLibrary }
        return URL(fileURLWithPath: (imageLibraryDir as NSString).expandingTildeInPath)
    }

    func isProviderEnabled(_ p: KeyProvider) -> Bool {
        !(disabledProviders ?? []).contains(p.rawValue)
    }

    func preferredKeyId(for provider: KeyProvider) -> UUID? {
        preferredKeyByProvider?[provider.rawValue]
    }

    mutating func setPreferredKeyId(_ id: UUID?, for provider: KeyProvider) {
        var map = preferredKeyByProvider ?? [:]
        if let id { map[provider.rawValue] = id } else { map.removeValue(forKey: provider.rawValue) }
        preferredKeyByProvider = map.isEmpty ? nil : map
    }
}

@MainActor
@Observable
final class SettingsStore {
    var settings: AppSettings {
        didSet { save() }
    }

    init() {
        if let data = try? Data(contentsOf: AppPaths.settingsFile),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: AppPaths.settingsFile, options: .atomic)
        }
    }

    /// Provider on/off switches (Settings tab).
    func isProviderEnabled(_ p: KeyProvider) -> Bool {
        settings.isProviderEnabled(p)
    }

    func setProviderEnabled(_ p: KeyProvider, enabled: Bool) {
        var disabled = Set(settings.disabledProviders ?? [])
        if enabled {
            disabled.remove(p.rawValue)
        } else {
            disabled.insert(p.rawValue)
        }
        settings.disabledProviders = disabled.isEmpty ? nil : Array(disabled).sorted()
    }

    /// Returns the preferred API key id for `provider`, or nil if no preference
    /// is stored or the stored id no longer points at a key of that provider.
    func preferredKeyId(for provider: KeyProvider) -> UUID? {
        settings.preferredKeyId(for: provider)
    }

    func setPreferredKeyId(_ id: UUID?, for provider: KeyProvider) {
        settings.setPreferredKeyId(id, for: provider)
    }
}

// MARK: - Keychain

enum Keychain {
    static let service = "BlStudio"

    /// Carries the result out of the watchdog thread.
    private final class SecretBox: @unchecked Sendable {
        var value: String?
    }

    /// Reads a secret with a hard timeout. A keychain item whose ACL demands
    /// interactive authorization would otherwise block the calling thread on a
    /// dialog forever (corrupted items from older builds can do that); in that
    /// case we give up after `timeout` seconds and return nil. The blocked
    /// worker thread is left behind; it unblocks if the dialog is ever answered.
    static func getSecret(account: String, timeout: TimeInterval = 10) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let box = SecretBox()
        let sem = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data {
                box.value = String(data: data, encoding: .utf8)
            }
            sem.signal()
        }
        guard sem.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.value
    }

    static func setSecret(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        deleteSecret(account: account)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        var status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // A stale item survived the delete (its ACL demanded user consent
            // and the watchdog gave up). Replace its value in place instead.
            let update: [String: Any] = [kSecValueData as String: data]
            status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    /// Deletes a secret, bounded by the same watchdog as reads.
    static func deleteSecret(account: String, timeout: TimeInterval = 10) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let sem = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            SecItemDelete(query as CFDictionary)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
    }
}

func maskAPIKey(_ key: String) -> String {
    let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard k.count > 12 else { return String(repeating: "•", count: max(4, k.count)) }
    let head = k.prefix(6)
    let tail = k.suffix(4)
    return "\(head)…\(tail)"
}

// MARK: - Keys store

struct KeySelection: Hashable, Sendable {
    var keyId: UUID?   // nil → CLI default profile
}

@MainActor
@Observable
final class KeysStore {
    /// Settings is needed to look up the per-provider preferred key id.
    @ObservationIgnored let settings: SettingsStore

    private(set) var keys: [APIKeyMeta] = []

    private struct Persisted: Codable {
        var keys: [APIKeyMeta]
        // Older files may carry `activeKeyId` from the previous build; we
        // ignore it on load and drop it from the schema.
        var activeKeyId: UUID?
    }

    init(settings: SettingsStore) {
        self.settings = settings
        if let data = try? Data(contentsOf: AppPaths.keysFile),
           let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            keys = decoded.keys
            // Old `activeKeyId` is intentionally dropped. No migration is run
            // because the provider-specific preference will be set the next
            // time the user changes it from Settings.
        }
    }

    /// Resolves the API key for `provider`: the per-provider preference from
    /// Settings if it still points at a key of that provider, otherwise the
    /// first key of that provider. Returns nil if none exists.
    func activeMeta(for provider: KeyProvider) -> APIKeyMeta? {
        if let preferred = settings.preferredKeyId(for: provider),
           let m = keys.first(where: { $0.id == preferred && $0.resolvedProvider == provider }) {
            return m
        }
        return keys.first { $0.resolvedProvider == provider }
    }

    /// Convenience: secret for the resolved key, or nil if none.
    func activeSecret(for provider: KeyProvider) -> String? {
        guard let m = activeMeta(for: provider) else { return nil }
        return Keychain.getSecret(account: m.id.uuidString)
    }

    func activeLabel(for provider: KeyProvider) -> String {
        activeMeta(for: provider)?.label ?? "No \(provider.label) key"
    }

    /// Keys of the given provider, in storage order (used by Settings to build
    /// the per-provider key picker).
    func keys(for provider: KeyProvider) -> [APIKeyMeta] {
        keys.filter { $0.resolvedProvider == provider }
    }

    func add(label: String, secret: String, provider: KeyProvider = .bailian,
             accountId: String? = nil) throws -> APIKeyMeta {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else {
            throw NSError(domain: "BlStudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "API key looks too short."])
        }
        var meta = APIKeyMeta(label: label.isEmpty ? maskAPIKey(trimmed) : label,
                              masked: maskAPIKey(trimmed))
        meta.provider = provider
        let acct = accountId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        meta.accountId = acct.isEmpty ? nil : acct
        try Keychain.setSecret(trimmed, account: meta.id.uuidString)
        keys.append(meta)
        // If this is the first key of its provider, make it the preferred one
        // so the user doesn't have to touch Settings just to get started.
        if settings.preferredKeyId(for: provider) == nil {
            settings.setPreferredKeyId(meta.id, for: provider)
        }
        save()
        return meta
    }

    // MARK: Per-provider convenience accessors

    var bailianConfigured: Bool { keys.contains { $0.resolvedProvider == .bailian } }
    var activeBailianMeta: APIKeyMeta? { activeMeta(for: .bailian) }
    var activeBailianSecret: String? { activeSecret(for: .bailian) }
    func activeBailianLabel() -> String { activeLabel(for: .bailian) }

    var miniMaxConfigured: Bool { keys.contains { $0.isMiniMax } }
    var activeMiniMaxMeta: APIKeyMeta? { activeMeta(for: .minimax) }
    var activeMiniMaxSecret: String? { activeSecret(for: .minimax) }
    func activeMiniMaxLabel() -> String { activeLabel(for: .minimax) }

    var geminiConfigured: Bool { keys.contains { $0.isGemini } }
    var activeGeminiMeta: APIKeyMeta? { activeMeta(for: .gemini) }
    var activeGeminiSecret: String? { activeSecret(for: .gemini) }
    func activeGeminiLabel() -> String { activeLabel(for: .gemini) }

    var fishConfigured: Bool { keys.contains { $0.isFish } }
    var activeFishMeta: APIKeyMeta? { activeMeta(for: .fish) }
    var activeFishSecret: String? { activeSecret(for: .fish) }
    func activeFishLabel() -> String { activeLabel(for: .fish) }

    var cloudflareConfigured: Bool { keys.contains { $0.isCloudflare } }
    var activeCloudflareMeta: APIKeyMeta? { activeMeta(for: .cloudflare) }
    var activeCloudflareSecret: String? { activeSecret(for: .cloudflare) }
    var activeCloudflareAccountId: String? { activeCloudflareMeta?.accountId }
    func activeCloudflareLabel() -> String { activeLabel(for: .cloudflare) }

    var huggingFaceConfigured: Bool { keys.contains { $0.isHuggingFace } }
    var activeHuggingFaceMeta: APIKeyMeta? { activeMeta(for: .huggingface) }
    var activeHuggingFaceSecret: String? { activeSecret(for: .huggingface) }
    var activeHuggingFaceProvider: String? { activeHuggingFaceMeta?.accountId }
    func activeHuggingFaceLabel() -> String { activeLabel(for: .huggingface) }

    var metaMuseConfigured: Bool { keys.contains { $0.isMeta } }
    var activeMetaMuseMeta: APIKeyMeta? { activeMeta(for: .meta) }
    var activeMetaMuseSecret: String? { activeSecret(for: .meta) }
    func activeMetaMuseLabel() -> String { activeLabel(for: .meta) }

    func updateLabel(_ id: UUID, label: String) {
        guard let i = keys.firstIndex(where: { $0.id == id }) else { return }
        keys[i].label = label
        save()
    }

    func remove(_ id: UUID) {
        guard let removed = keys.first(where: { $0.id == id }) else { return }
        let provider = removed.resolvedProvider
        Keychain.deleteSecret(account: id.uuidString)
        keys.removeAll { $0.id == id }
        // Clear the per-provider preference if it pointed at the removed key,
        // so the next resolution falls back to the next key of that provider.
        if settings.preferredKeyId(for: provider) == id {
            settings.setPreferredKeyId(nil, for: provider)
        }
        save()
    }

    func secret(for id: UUID, timeout: TimeInterval = 10) -> String? {
        Keychain.getSecret(account: id.uuidString, timeout: timeout)
    }

    private func save() {
        let persisted = Persisted(keys: keys, activeKeyId: nil)
        if let data = try? JSONEncoder().encode(persisted) {
            try? data.write(to: AppPaths.keysFile, options: .atomic)
        }
    }
}

// MARK: - Usage ledger (per-key local quota tracking)

@MainActor
@Observable
final class UsageLedger {
    private(set) var events: [UsageEvent] = []

    @ObservationIgnored private let fileURL: URL

    @ObservationIgnored private lazy var encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    @ObservationIgnored private lazy var decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? AppPaths.usageFile
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return }
        events = text.split(separator: "\n").compactMap { line in
            try? decoder.decode(UsageEvent.self, from: Data(line.utf8))
        }
    }

    func record(_ event: UsageEvent) {
        events.append(event)
        if let data = try? encoder.encode(event) {
            var line = data
            line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: fileURL)
            }
        }
    }

    // MARK: Aggregates

    struct KeySummary {
        var images = 0
        var edits = 0
        var videos = 0
        var music = 0
        var audio = 0
        var chats = 0
        var promptTokens = 0
        var completionTokens = 0
        var failed = 0
        var lastUsed: Date?
        var todayImages = 0
        var dailyImages: [Date: Int] = [:]   // day-start → count (last N days)

        var totalTokens: Int { promptTokens + completionTokens }
    }

    func summary(keyId: UUID?, days: Int = 14) -> KeySummary {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        var s = KeySummary()
        for e in events where e.keyId == keyId {
            switch e.kind {
            case .imageGenerate: s.images += e.images
            case .imageEdit: s.edits += e.images
            case .videoGenerate: s.videos += 1
            case .musicGenerate: s.music += 1
            case .speech: s.audio += 1
            case .chat: s.chats += 1
            case .vision: s.chats += 0
            }
            s.promptTokens += e.promptTokens
            s.completionTokens += e.completionTokens
            if !e.ok { s.failed += 1 }
            if e.kind == .imageGenerate || e.kind == .imageEdit {
                let day = cal.startOfDay(for: e.at)
                s.dailyImages[day, default: 0] += e.images
                if day == todayStart { s.todayImages += e.images }
            }
            if s.lastUsed == nil || e.at > s.lastUsed! { s.lastUsed = e.at }
        }
        return s
    }

    /// Days (oldest → newest) with image counts for charting.
    func dailySeries(keyId: UUID?, days: Int = 14) -> [UsageDayPoint] {
        let s = summary(keyId: keyId, days: days)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<days).reversed().map { offset in
            let day = cal.date(byAdding: .day, value: -offset, to: today)!
            return UsageDayPoint(day: day, images: s.dailyImages[day] ?? 0)
        }
    }

    var knownKeyIds: Set<UUID?> {
        Set(events.map { $0.keyId })
    }
}

// MARK: - History / gallery

@MainActor
@Observable
final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []

    private let maxEntries = 500

    @ObservationIgnored private lazy var encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted]
        return e
    }()
    @ObservationIgnored private lazy var decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        if let data = try? Data(contentsOf: AppPaths.historyFile),
           let decoded = try? decoder.decode([HistoryEntry].self, from: data) {
            entries = decoded.sorted { $0.createdAt > $1.createdAt }
        }
    }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        save()
    }

    func remove(_ id: UUID, trashFiles: Bool) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        if trashFiles {
            for p in entry.savedPaths {
                try? FileManager.default.trashItem(
                    at: URL(fileURLWithPath: p), resultingItemURL: nil)
            }
        }
        entries.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? encoder.encode(entries) {
            try? data.write(to: AppPaths.historyFile, options: .atomic)
        }
    }
}

// MARK: - Prompt library

struct PromptPreset: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let suffix: String
}

@MainActor
@Observable
final class PromptLibrary {
    var favorites: [String] = []
    var negativeFavorites: [String] = []

    static let presets: [PromptPreset] = [
        .init(name: "Photoreal", suffix: "photorealistic, ultra detailed, natural lighting, 8k"),
        .init(name: "Cinematic", suffix: "cinematic lighting, dramatic composition, film still, shallow depth of field"),
        .init(name: "Anime", suffix: "anime style, clean line art, vibrant colors, detailed background"),
        .init(name: "Watercolor", suffix: "watercolor painting, soft edges, paper texture, pastel palette"),
        .init(name: "Oil paint", suffix: "oil painting, impasto brush strokes, rich colors"),
        .init(name: "3D render", suffix: "3d render, octane, studio lighting, high detail"),
        .init(name: "Pixel art", suffix: "pixel art, 16-bit, crisp sprites"),
        .init(name: "Logo", suffix: "minimal vector logo, flat design, simple shapes, white background"),
        .init(name: "Product", suffix: "professional product photography, studio softbox lighting, clean backdrop"),
        .init(name: "Cyberpunk", suffix: "cyberpunk, neon lights, rain, futuristic city, high contrast"),
        .init(name: "Sketch", suffix: "pencil sketch, hand drawn, cross hatching, monochrome"),
        .init(name: "Isometric", suffix: "isometric illustration, soft shadows, pastel colors, diorama"),
    ]

    init() {
        if let data = try? Data(contentsOf: AppPaths.favoritesFile),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            favorites = decoded
        }
        if let data = try? Data(contentsOf: AppPaths.negativeFavoritesFile),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            negativeFavorites = decoded
        }
    }

    func toggleFavorite(_ prompt: String) {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        if let i = favorites.firstIndex(of: p) {
            favorites.remove(at: i)
        } else {
            favorites.insert(p, at: 0)
            favorites = Array(favorites.prefix(50))
        }
        save()
    }

    func toggleNegativeFavorite(_ prompt: String) {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        if let i = negativeFavorites.firstIndex(of: p) {
            negativeFavorites.remove(at: i)
        } else {
            negativeFavorites.insert(p, at: 0)
            negativeFavorites = Array(negativeFavorites.prefix(50))
        }
        saveNegatives()
    }

    private func saveNegatives() {
        if let data = try? JSONEncoder().encode(negativeFavorites) {
            try? data.write(to: AppPaths.negativeFavoritesFile, options: .atomic)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(favorites) {
            try? data.write(to: AppPaths.favoritesFile, options: .atomic)
        }
    }
}
