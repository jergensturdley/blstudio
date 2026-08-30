import Foundation

/// HTTP client for Cloudflare Workers AI image generation (free tier).
///
/// Workers AI needs both an account id and an API token; the route is
/// account-scoped. `generate` runs a text-to-image model and returns the
/// result as base64, which we decode and save to disk.
final class CloudflareClient: @unchecked Sendable {
    static let baseURL = "https://api.cloudflare.com/client/v4"

    /// Generates an image via POST /accounts/{account}/ai/run/{model}.
    ///
    /// Each Workers AI model validates its input strictly, so the body is built
    /// per model: FLUX only accepts `prompt`/`steps`/`seed`, while SDXL
    /// Lightning takes `width`/`height`/`num_steps`/`negative_prompt`/`seed`.
    func generate(
        apiKey: String,
        accountId: String,
        model: String,
        prompt: String,
        negativePrompt: String? = nil,
        width: Int,
        height: Int,
        seed: Int? = nil,
        dest: URL
    ) async throws -> URL {
        let account = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty else { throw CloudflareError.badURL }
        guard let url = URL(string: "\(Self.baseURL)/accounts/\(account)/ai/run/\(model)") else {
            throw CloudflareError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["prompt": prompt]
        if model.contains("flux") {
            body["steps"] = 4
        } else {
            // FLUX expects dimensions that are multiples of 8.
            body["width"] = max(64, (width / 8) * 8)
            body["height"] = max(64, (height / 8) * 8)
            body["num_steps"] = 4
            if let seed { body["seed"] = seed }
            let np = negativePrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !np.isEmpty { body["negative_prompt"] = np }
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw CloudflareError.badResponse("no HTTP response") }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard http.statusCode == 200 else {
            throw CloudflareError.http(http.statusCode, Self.errorMessage(from: text) ?? String(text.prefix(200)))
        }
        // Workers AI image models return one of two shapes: a JSON envelope
        // `{"result": {"image": "<base64>"}}` (FLUX) or the raw image bytes
        // (SDXL Lightning). Handle both.
        if let bytes = Self.imageBytes(from: data) {
            try? FileManager.default.removeItem(at: dest)
            try bytes.write(to: dest)
            return dest
        }
        // Not raw image bytes: try the JSON envelope.
        if let decoded = try? JSONDecoder().decode(CloudflareImageResult.self, from: data) {
            if decoded.success == false {
                throw CloudflareError.api(decoded.errors?.first?.message ?? "request failed")
            }
            if let b64 = decoded.result?.image, !b64.isEmpty,
               let bytes = Data(base64Encoded: b64) {
                try? FileManager.default.removeItem(at: dest)
                try bytes.write(to: dest)
                return dest
            }
            throw CloudflareError.badResponse("no image returned")
        }
        let preview = String(data: data.prefix(200), encoding: .utf8) ?? "\(data.count) binary bytes"
        throw CloudflareError.badResponse("unrecognized response: \(preview)")
    }

    /// Returns the payload directly if it already is raw image data
    /// (JPEG / PNG / WebP magic bytes), otherwise nil.
    private static func imageBytes(from data: Data) -> Data? {
        guard data.count > 8 else { return nil }
        let b = [UInt8](data.prefix(12))
        let isJPEG = b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF
        let isPNG = b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47
        let isWebP = b.count >= 12 && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46
            && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50
        return (isJPEG || isPNG || isWebP) ? data : nil
    }

    /// Validates the account id + token by listing models (consumes no credits).
    func validate(apiKey: String, accountId: String) async throws -> String {
        let account = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty else {
            throw CloudflareError.api("Missing Cloudflare account id")
        }
        guard let url = URL(string: "\(Self.baseURL)/accounts/\(account)/ai/models/search?per_page=1") else {
            throw CloudflareError.badURL
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw CloudflareError.badResponse("no HTTP response") }
        if http.statusCode == 200 {
            return "OK · authenticated"
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        throw CloudflareError.http(http.statusCode, Self.errorMessage(from: text) ?? String(text.prefix(160)))
    }

    static func errorMessage(from body: String) -> String? {
        struct Envelope: Codable {
            struct Err: Codable { var message: String? }
            var errors: [Err]?
        }
        if let e = try? JSONDecoder().decode(Envelope.self, from: Data(body.utf8)),
           let m = e.errors?.first?.message, !m.isEmpty {
            return m
        }
        return nil
    }
}

/// Response envelope for POST /accounts/{account}/ai/run/{model}.
struct CloudflareImageResult: Codable, Sendable {
    struct Err: Codable, Sendable {
        var code: Int?
        var message: String?
    }
    struct Payload: Codable, Sendable {
        var image: String?
    }
    var result: Payload?
    var success: Bool?
    var errors: [Err]?
}

enum CloudflareError: LocalizedError {
    case badURL
    case badResponse(String)
    case api(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Invalid Cloudflare API URL. Check the account id."
        case .badResponse(let s):
            return "Cloudflare returned an unexpected response: \(s)"
        case .api(let s):
            return "Cloudflare error: \(s)"
        case .http(let code, let s):
            return "Cloudflare error \(code): \(s)"
        }
    }
}
