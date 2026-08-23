import Foundation

/// HTTP client for Hugging Face Inference Providers text-to-image.
///
/// The router routes each request to a specific inference provider, so the URL
/// is `https://router.huggingface.co/{provider}/v1/images/generations`. The
/// response is OpenAI-compatible: an item carries either a `url` or inline
/// `b64_json`. Free availability depends on the provider and model.
final class HuggingFaceClient: @unchecked Sendable {
    static let baseURL = "https://router.huggingface.co"
    static let defaultProvider = "fal-ai"

    /// Generates an image via the Inference Providers router.
    func generate(
        apiKey: String,
        provider: String?,
        model: String,
        prompt: String,
        width: Int,
        height: Int,
        dest: URL
    ) async throws -> URL {
        let prov = Self.cleaned(provider) ?? Self.defaultProvider
        guard let url = URL(string: "\(Self.baseURL)/\(prov)/v1/images/generations") else {
            throw HuggingFaceError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "width": width,
            "height": height,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw HuggingFaceError.badResponse("no HTTP response") }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard http.statusCode == 200 else {
            throw HuggingFaceError.http(http.statusCode, Self.errorMessage(from: text) ?? String(text.prefix(200)))
        }

        let decoded = try JSONDecoder().decode(HFImageResult.self, from: data)
        guard let item = decoded.data?.first else {
            throw HuggingFaceError.badResponse("no image returned")
        }
        if let b64 = item.b64_json, !b64.isEmpty, let bytes = Data(base64Encoded: b64) {
            try? FileManager.default.removeItem(at: dest)
            try bytes.write(to: dest)
            return dest
        }
        if let urlString = item.url, !urlString.isEmpty {
            return try await downloadImage(urlString, to: dest)
        }
        throw HuggingFaceError.badResponse("no image data in response")
    }

    /// Validates a token via whoami-v2 (consumes no credits).
    func validate(apiKey: String) async throws -> String {
        guard let url = URL(string: "https://huggingface.co/api/whoami-v2") else {
            throw HuggingFaceError.badURL
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw HuggingFaceError.badResponse("no HTTP response") }
        if http.statusCode == 200 {
            return "OK · authenticated"
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        throw HuggingFaceError.http(http.statusCode, Self.errorMessage(from: text) ?? String(text.prefix(160)))
    }

    private static func cleaned(_ s: String?) -> String? {
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    static func errorMessage(from body: String) -> String? {
        struct Envelope: Codable { var error: String? }
        if let e = try? JSONDecoder().decode(Envelope.self, from: Data(body.utf8)),
           let m = e.error, !m.isEmpty {
            return m
        }
        return nil
    }

    private func downloadImage(_ urlString: String, to dest: URL) async throws -> URL {
        guard let u = URL(string: urlString) else { throw HuggingFaceError.badURL }
        let (tmp, response) = try await URLSession.shared.download(from: u)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tmp)
            throw HuggingFaceError.http(http.statusCode, "image download failed")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}

/// OpenAI-compatible images response from the HF router.
struct HFImageResult: Codable, Sendable {
    struct Item: Codable, Sendable {
        var url: String?
        var b64_json: String?
    }
    var data: [Item]?
}

enum HuggingFaceError: LocalizedError {
    case badURL
    case badResponse(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Invalid Hugging Face API URL."
        case .badResponse(let s):
            return "Hugging Face returned an unexpected response: \(s)"
        case .http(let code, let s):
            return "Hugging Face error \(code): \(s)"
        }
    }
}
