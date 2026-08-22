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
    var imageLibraryDir: String = ""       // empty → ~/Pictures/BlStudio
    var defaultImageModel: String = ""     // empty → bl default (qwen-image-3.0)
    var defaultChatModel: String = ""
    var defaultSize: String = "1:1"
    var pollInterval: Int = 3
    var requestTimeout: Int = 900

    var libraryURL: URL {
        if imageLibraryDir.isEmpty { return AppPaths.defaultImageLibrary }
        return URL(fileURLWithPath: (imageLibraryDir as NSString).expandingTildeInPath)
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
}

// MARK: - Keychain

enum Keychain {
    static let service = "BlStudio"

    static func setSecret(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func getSecret(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteSecret(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
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
    private(set) var keys: [APIKeyMeta] = []
    /// The key currently selected for requests. `nil` = use the CLI default profile.
    var activeKeyId: UUID?

    private struct Persisted: Codable {
        var keys: [APIKeyMeta]
        var activeKeyId: UUID?
    }

    init() {
        if let data = try? Data(contentsOf: AppPaths.keysFile),
           let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            keys = decoded.keys
            activeKeyId = decoded.activeKeyId
        }
    }

    var activeMeta: APIKeyMeta? {
        keys.first { $0.id == activeKeyId }
    }

    /// Secret for the active key (nil when using CLI default profile).
    var activeSecret: String? {
        guard let id = activeKeyId else { return nil }
        return Keychain.getSecret(account: id.uuidString)
    }

    func activeLabel() -> String {
        activeMeta?.label ?? "CLI default profile"
    }

    func add(label: String, secret: String) throws -> APIKeyMeta {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else {
            throw NSError(domain: "BlStudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "API key looks too short."])
        }
        let meta = APIKeyMeta(label: label.isEmpty ? maskAPIKey(trimmed) : label,
                              masked: maskAPIKey(trimmed))
        try Keychain.setSecret(trimmed, account: meta.id.uuidString)
        keys.append(meta)
        if activeKeyId == nil { activeKeyId = meta.id }
        save()
        return meta
    }

    func updateLabel(_ id: UUID, label: String) {
        guard let i = keys.firstIndex(where: { $0.id == id }) else { return }
        keys[i].label = label
        save()
    }

    func remove(_ id: UUID) {
        Keychain.deleteSecret(account: id.uuidString)
        keys.removeAll { $0.id == id }
        if activeKeyId == id { activeKeyId = keys.first?.id }
        save()
    }

    func secret(for id: UUID) -> String? {
        Keychain.getSecret(account: id.uuidString)
    }

    private func save() {
        let persisted = Persisted(keys: keys, activeKeyId: activeKeyId)
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

    private func save() {
        if let data = try? JSONEncoder().encode(favorites) {
            try? data.write(to: AppPaths.favoritesFile, options: .atomic)
        }
    }
}
