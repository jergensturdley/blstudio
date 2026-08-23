import Foundation

/// Client for Google Gemini image generation (e.g. gemini-2.5-flash-image,
/// "Nano Banana") via the generativelanguage REST API. Returns the generated
/// image inline as base64. Free API keys come from Google AI Studio.
final class GeminiClient: @unchecked Sendable {
    static let baseURL = "https://generativelanguage.googleapis.com/v1beta"

    /// Generates a single image and writes it to `dest`. Returns `dest`.
    func generate(
        apiKey: String,
        model: String,
        prompt: String,
        aspectRatio: String?,
        dest: URL
    ) async throws -> URL {
        let modelId = model.trimmingCharacters(in: .whitespaces).isEmpty
            ? "gemini-2.5-flash-image" : model
        guard let url = URL(string: "\(Self.baseURL)/models/\(modelId):generateContent") else {
            throw GeminiError.badURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 240
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var generationConfig: [String: Any] = ["responseModalities": ["IMAGE", "TEXT"]]
        if let ar = aspectRatio, !ar.isEmpty {
            generationConfig["imageConfig"] = ["aspectRatio": ar]
        }
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": generationConfig,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw GeminiError.badResponse("no HTTP response") }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw GeminiError.http(http.statusCode, String(msg.prefix(220)))
        }

        let decoded: GeminiGenResponse
        do {
            decoded = try JSONDecoder().decode(GeminiGenResponse.self, from: data)
        } catch {
            throw GeminiError.badResponse(String((String(data: data, encoding: .utf8) ?? "").prefix(200)))
        }

        guard let parts = decoded.candidates?.first?.content?.parts else { throw GeminiError.noImage }
        for part in parts {
            if let inline = part.inlineData, let b64 = inline.data, !b64.isEmpty,
               let imgData = Data(base64Encoded: b64) {
                let target = dest.deletingPathExtension()
                    .appendingPathExtension(Self.ext(forMIME: inline.mimeType))
                try? FileManager.default.removeItem(at: target)
                try imgData.write(to: target)
                return target
            }
        }
        throw GeminiError.noImage
    }

    /// Cheap key validation: list models. Returns a friendly status string.
    func validate(apiKey: String) async throws -> String {
        guard let url = URL(string: "\(Self.baseURL)/models?pageSize=1") else { throw GeminiError.badURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw GeminiError.badResponse("no HTTP response") }
        if http.statusCode == 200 { return "OK · authenticated" }
        let msg = String(data: data, encoding: .utf8) ?? ""
        throw GeminiError.http(http.statusCode, String(msg.prefix(180)))
    }

    static func ext(forMIME mime: String?) -> String {
        switch mime?.lowercased() {
        case "image/png": return "png"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        default: return "png"
        }
    }
}

struct GeminiGenResponse: Codable, Sendable {
    struct Candidate: Codable, Sendable {
        struct Content: Codable, Sendable {
            struct Part: Codable, Sendable {
                struct InlineData: Codable, Sendable {
                    var mimeType: String?
                    var data: String?
                }
                var text: String?
                var inlineData: InlineData?
            }
            var parts: [Part]?
        }
        var content: Content?
        var finishReason: String?
    }
    var candidates: [Candidate]?
    struct APIError: Codable, Sendable {
        var code: Int?
        var message: String?
        var status: String?
    }
    var error: APIError?
}

enum GeminiError: LocalizedError {
    case badURL
    case noImage
    case badResponse(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Invalid Gemini API URL."
        case .noImage:
            return "Gemini returned no image. It may have declined the prompt or hit a limit."
        case .badResponse(let head):
            return "Could not parse Gemini response: \(head)"
        case .http(let code, let body):
            return "Gemini HTTP \(code): \(body)"
        }
    }
}
