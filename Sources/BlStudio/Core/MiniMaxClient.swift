import Foundation

/// Minimal native client for the MiniMax image API (https://api.minimax.io).
/// Unlike the Bailian path, this talks HTTP directly and does not need the `bl`
/// CLI. Generation is synchronous: one POST returns the final image URLs.
final class MiniMaxClient: @unchecked Sendable {
    var baseURL = "https://api.minimax.io"
    var timeoutSeconds: Int = 600

    /// POST /v1/image_generation. Returns the generated image URLs.
    func generate(
        apiKey: String,
        prompt: String,
        n: Int,
        aspectRatio: String,
        promptOptimizer: Bool,
        model: String = "image-01"
    ) async throws -> [String] {
        guard let url = URL(string: "\(baseURL)/v1/image_generation") else {
            throw MiniMaxError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = TimeInterval(timeoutSeconds)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "n": max(1, min(9, n)),
            "aspect_ratio": aspectRatio,
            "prompt_optimizer": promptOptimizer,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw MiniMaxError.badResponse("no HTTP response")
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard http.statusCode == 200 else {
            throw MiniMaxError.http(http.statusCode, String(text.prefix(200)))
        }
        let decoded = try Self.decode(data)
        if let br = decoded.base_resp, br.status_code != 0 {
            throw MiniMaxError.api(status: br.status_code,
                                   message: br.status_msg ?? "unknown error")
        }
        guard let urls = decoded.data?.image_urls, !urls.isEmpty else {
            throw MiniMaxError.noImages
        }
        return urls
    }

    /// Downloads one generated image into `dir` as `<prefix>-<index>.jpg`.
    @discardableResult
    func downloadImage(_ urlString: String, to dir: URL, prefix: String, index: Int) async throws -> URL {
        guard let u = URL(string: urlString) else {
            throw MiniMaxError.badResponse("invalid image URL")
        }
        let (tmp, response) = try await URLSession.shared.download(from: u)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tmp)
            throw MiniMaxError.http(http.statusCode, "image download failed")
        }
        let dest = dir.appendingPathComponent("\(prefix)-\(index).jpg")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Cheap key validation that consumes no credits: fetches a dummy file id.
    /// Authentication failures throw; any other outcome means the key was accepted.
    func validate(apiKey: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/v1/files/retrieve?file_id=blstudio-key-check") else {
            throw MiniMaxError.badURL
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        let envelope = try JSONDecoder().decode(MiniMaxBaseEnvelope.self, from: data)
        if let br = envelope.base_resp, [1004, 1008].contains(br.status_code) {
            throw MiniMaxError.api(status: br.status_code,
                                   message: br.status_msg ?? "authentication failed")
        }
        return "OK · authenticated"
    }

    /// Parses a /v1/image_generation response body. Exposed for self-tests.
    static func decode(_ data: Data) throws -> MiniMaxImageResult {
        do {
            return try JSONDecoder().decode(MiniMaxImageResult.self, from: data)
        } catch {
            let head = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw MiniMaxError.badResponse(head)
        }
    }
}

/// Generic envelope used where only `base_resp` matters.
struct MiniMaxBaseEnvelope: Codable, Sendable {
    var base_resp: MiniMaxImageResult.BaseResp?
}

/// Response envelope for /v1/image_generation.
struct MiniMaxImageResult: Codable, Sendable {
    struct BaseResp: Codable, Sendable {
        var status_code: Int
        var status_msg: String?
    }
    struct Payload: Codable, Sendable {
        var image_urls: [String]?
    }
    var base_resp: BaseResp?
    var data: Payload?
}

enum MiniMaxError: LocalizedError {
    case badURL
    case api(status: Int, message: String)
    case noImages
    case badResponse(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Invalid MiniMax API URL."
        case .api(let status, let message):
            return "MiniMax error \(status): \(message)"
        case .noImages:
            return "MiniMax returned no images."
        case .badResponse(let head):
            return "Could not parse MiniMax response: \(head)"
        case .http(let code, let body):
            return "MiniMax HTTP \(code): \(body)"
        }
    }
}
