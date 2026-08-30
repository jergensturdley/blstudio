import Foundation

/// HTTP client for Meta's Muse Image text-to-image API (Meta Model API).
///
/// Meta Model API is OpenAI-compatible: `https://api.meta.ai/v1` serves a
/// `/v1/images/generations` endpoint that takes the standard
/// `{model, prompt, n, size, response_format}` body and returns
/// `{data:[{b64_json}], output_format}`. Authentication is a Bearer API key
/// issued from the Meta Model API dashboard. See
/// https://dev.meta.ai/docs/image-generation.
final class MetaMuseClient: @unchecked Sendable {
    static let baseURL = "https://api.meta.ai/v1"

    /// Image-generation model id (the only image model advertised by the
    /// Meta Model API as of writing). Real text generation lives on
    /// `muse-spark-1.1` / `muse-spark-1.2`.
    static let imageModel = "muse-image-1.0"

    /// Validates the API key by sending a 1-token chat completion ping to
    /// `muse-spark-1.1` (does not generate an image, so it consumes nothing
    /// of note on the free tier).
    func validate(apiKey: String) async throws -> String {
        let url = URL(string: "\(Self.baseURL)/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": "muse-spark-1.1",
            "messages": [["role": "user", "content": "ping"]],
            "max_tokens": 1,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw MetaMuseError.badResponse("no HTTP response") }
        if http.statusCode == 200 { return "OK · authenticated" }
        let text = String(data: data, encoding: .utf8) ?? ""
        throw MetaMuseError.http(http.statusCode, Self.errorMessage(from: text) ?? String(text.prefix(200)))
    }

    /// Generates one image via `POST /v1/images/generations`. The returned
    /// `Data` is the decoded image bytes (webp by default; honours the API's
    /// `output_format` field).
    func generate(
        apiKey: String,
        prompt: String,
        n: Int = 1,
        size: String? = nil,
        dest: URL,
        timeout: TimeInterval = 180
    ) async throws -> Data {
        let url = URL(string: "\(Self.baseURL)/images/generations")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": Self.imageModel,
            "prompt": prompt,
            "n": max(1, min(10, n)),
            "response_format": "b64_json",
        ]
        if let size, !size.isEmpty { body["size"] = size }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw MetaMuseError.badResponse("no HTTP response") }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard http.statusCode == 200 else {
            throw MetaMuseError.http(http.statusCode, Self.errorMessage(from: text) ?? String(text.prefix(200)))
        }
        return try Self.firstImage(from: data, dest: dest)
    }

    /// Decodes the API response and writes the first image to `dest`. Returns
    /// the image bytes (useful for callers that want to inspect the result).
    @discardableResult
    static func firstImage(from data: Data, dest: URL) throws -> Data {
        let decoded: ImageResponse
        do { decoded = try JSONDecoder().decode(ImageResponse.self, from: data) }
        catch {
            // Fall back: maybe the response is a raw image (Content-Type aside,
            // just in case the API ever flips to returning bytes directly).
            let b = [UInt8](data.prefix(4))
            let looksLikeImage = b.count >= 2 && (
                (b[0] == 0xFF && b[1] == 0xD8) || // JPEG
                (b.count >= 4 && b[0] == 0x89 && b[1] == 0x50) // PNG
            )
            if looksLikeImage {
                try? FileManager.default.removeItem(at: dest)
                try data.write(to: dest)
                return data
            }
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? "\(data.count) binary bytes"
            throw MetaMuseError.badResponse("unrecognized response: \(preview)")
        }
        guard let b64 = decoded.data.first?.b64_json, !b64.isEmpty,
              let bytes = Data(base64Encoded: b64) else {
            throw MetaMuseError.badResponse("no image in response")
        }
        try? FileManager.default.removeItem(at: dest)
        try bytes.write(to: dest)
        return bytes
    }

    static func errorMessage(from body: String) -> String? {
        struct Envelope: Codable {
            struct Err: Codable { var message: String? }
            var error: Err?
        }
        if let e = try? JSONDecoder().decode(Envelope.self, from: Data(body.utf8)),
           let m = e.error?.message, !m.isEmpty { return m }
        return nil
    }

    /// Maps an aspect-ratio string (e.g. "16:9", "1:1") to the API's `size`
    /// parameter. The Muse API uses these values as aspect-ratio hints; the
    /// returned image is rendered at the model's own native resolution.
    static func size(forAspectRatio ratio: String, longEdge: Int = 1024) -> String {
        let parts = ratio.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return "\(longEdge)x\(longEdge)" }
        let w: Int
        let h: Int
        if parts[0] >= parts[1] {
            w = longEdge
            h = max(64, (longEdge * parts[1]) / parts[0])
        } else {
            h = longEdge
            w = max(64, (longEdge * parts[0]) / parts[1])
        }
        return "\(w)x\(h)"
    }
}

/// `POST /v1/images/generations` response shape.
struct MetaMuseImageResponse: Codable, Sendable {
    struct Item: Codable, Sendable {
        var b64_json: String?
        var url: String?
    }
    var created: Int?
    var data: [Item]
    var output_format: String?
    var background: String?
}

/// Alias used by `firstImage` so it doesn't conflict with the per-request
/// response struct elsewhere.
private typealias ImageResponse = MetaMuseImageResponse

enum MetaMuseError: LocalizedError {
    case badURL
    case badResponse(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid Meta Model API URL."
        case .badResponse(let s): return "Meta Muse returned an unexpected response: \(s)"
        case .http(let code, let s): return "Meta Muse error \(code): \(s)"
        }
    }
}
