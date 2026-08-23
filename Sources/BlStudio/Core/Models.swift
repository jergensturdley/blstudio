import Foundation

// MARK: - bl CLI response models (JSON contracts of bailian-cli 1.14.x)

/// `bl image generate` / `bl image edit` with `--output json`
struct ImageGenerationResult: Codable, Sendable {
    let urls: [String]
    let saved: [String]
    let total: Int
    let task_id: String?
    let task_ids: [String]?
}

/// The OpenAI-compatible chat completion envelope from `bl text chat` with `--output json`.
struct ChatCompletion: Codable, Sendable {
    struct Choice: Codable, Sendable {
        struct Message: Codable, Sendable {
            let role: String?
            let content: String?
            let reasoning_content: String?
        }
        let index: Int?
        let message: Message
        let finish_reason: String?
    }
    struct Usage: Codable, Sendable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let total_tokens: Int?
    }
    let id: String?
    let model: String?
    let choices: [Choice]
    let usage: Usage?

    var content: String {
        choices.first?.message.content ?? ""
    }
    var reasoning: String? {
        choices.first?.message.reasoning_content
    }
}

/// `bl auth status --output json`
struct AuthStatus: Codable, Sendable {
    struct KeyInfo: Codable, Sendable {
        let source: String?
        let masked: String?
        let base_url: String?
    }
    struct ConsoleInfo: Codable, Sendable {
        let source: String?
        let masked: String?
        let region: String?
        let site: String?
    }
    struct ErrorInfo: Codable, Sendable {
        let code: Int?
        let message: String
        let hint: String?
    }
    let authenticated: Bool?
    let config: String?
    let api_key: KeyInfo?
    let console: ConsoleInfo?
    let error: ErrorInfo?
}

/// `bl config list --output json`
struct ConfigList: Codable, Sendable {
    let active_config: String?
    let profiles: [String]
    let config_file: String?
}

/// `bl usage free --output json` (console session required)
struct FreeTierQuota: Codable, Sendable, Identifiable {
    let model: String
    let type: String?
    let remaining: Double?
    let total: Double?
    let usagePercent: Double?
    let remainingPercent: Double?
    let expires: String?
    let autoStop: Bool?

    var id: String { model }
}

/// `bl quota check --output json` (console session required)
struct RateUsage: Codable, Sendable, Identifiable {
    let model: String
    let rpmUsage: Int?
    let rpmLimit: Int?
    let tpmUsage: Int?
    let tpmLimit: Int?
    let rpmQuotaLeft: Double?
    let tpmQuotaLeft: Double?
    let rpmQuotaLabel: String?
    let tpmQuotaLabel: String?

    var id: String { model }
}

/// `bl quota list --output json`
struct RateLimit: Codable, Sendable, Identifiable {
    let model: String
    let rpm: Int?
    let tpm: Int?

    var id: String { model }
}

/// Error envelope bl prints on failure: `{"error": {"code": N, "message": ..., "hint": ...}}`
struct BLErrorEnvelope: Codable, Sendable {
    struct Info: Codable, Sendable {
        let code: Int?
        let message: String
        let hint: String?
    }
    let error: Info
}

// MARK: - Request-side models

struct ImageGenRequest: Sendable {
    var prompt: String
    var model: String? = nil
    var size: String? = nil            // "1:1" | "16:9" | "2048*2048"
    var n: Int = 1
    var seed: Int? = nil
    var negativePrompt: String? = nil
    var promptExtend: Bool? = nil
    var watermark: Bool? = nil
}

struct ImageEditRequest: Sendable {
    var sources: [URL]                 // local files or URLs
    var prompt: String
    var model: String? = nil
    var size: String? = nil
    var n: Int = 1
    var seed: Int? = nil
    var negativePrompt: String? = nil
    var function: String? = nil        // wanx*-imageedit function
    var promptExtend: Bool? = nil
    var watermark: Bool? = nil
}

struct VideoGenRequest: Sendable {
    var prompt: String
    var imageURL: String? = nil        // image-to-video source (URL for Bailian)
    var model: String? = nil
    var resolution: String? = nil      // e.g. "1080P"
    var ratio: String? = nil           // e.g. "16:9"
    var duration: Int? = nil           // seconds
    var seed: Int? = nil
    var negativePrompt: String? = nil
    var promptExtend: Bool? = nil
    var watermark: Bool? = nil
}

/// Best-effort decode of `bl video generate --output json` on completion.
struct VideoGenerationResult: Codable, Sendable {
    var task_id: String?
    var video_url: String?
    var status: String?
    var saved: String?
    var size: String?
}

struct ChatRequest: Sendable {
    var message: String
    var model: String? = nil
    var system: String? = nil
    var maxTokens: Int? = nil
    var temperature: Double? = nil
}

// MARK: - App-side models

enum WorkKind: String, Codable, Sendable, CaseIterable {
    case imageGenerate = "image generate"
    case imageEdit = "image edit"
    case videoGenerate = "video generate"
    case chat = "text chat"
    case vision = "vision describe"
}

struct HistoryEntry: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var kind: WorkKind
    var prompt: String
    var model: String?
    var keyId: UUID?          // nil → CLI default profile
    var keyLabel: String
    var savedPaths: [String]
    var remoteUrls: [String]
    var taskId: String?
    var createdAt: Date = Date()
    var durationMs: Int
    var ok: Bool
    var detail: String?       // chat reply text, vision description, or error message
}

struct UsageEvent: Codable, Sendable {
    var keyId: UUID?          // nil → CLI default profile
    var kind: WorkKind
    var model: String?
    var at: Date
    var images: Int
    var promptTokens: Int
    var completionTokens: Int
    var durationMs: Int
    var ok: Bool
}

struct UsageDayPoint: Identifiable, Sendable {
    let day: Date
    let images: Int
    var id: Date { day }
}

/// Which backend an API key belongs to.
enum KeyProvider: String, Codable, Sendable, CaseIterable {
    case bailian = "bailian"
    case minimax = "minimax"

    var label: String {
        switch self {
        case .bailian: return "Bailian (bl)"
        case .minimax: return "MiniMax"
        }
    }
}

struct APIKeyMeta: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var label: String
    var masked: String
    var baseUrl: String?
    var createdAt: Date = Date()
    /// Nil for keys saved before providers existed. Treated as Bailian.
    var provider: KeyProvider?

    var resolvedProvider: KeyProvider { provider ?? .bailian }
    var isMiniMax: Bool { resolvedProvider == .minimax }
}
