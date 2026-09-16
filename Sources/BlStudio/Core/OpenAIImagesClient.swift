import Foundation

/// Client for OpenAI-compatible `POST {base}/images/generations` endpoints.
/// One client, three providers:
///
///   DeepInfra    https://api.deepinfra.com         b64_json only
///   SiliconFlow  https://api.siliconflow.cn        url or b64_json
///   Custom       user-supplied base URL (OpenAI,   url or b64_json
///                Together, LocalAI, OpenRouter, …)
///
/// SiliconFlow differs in the request schema (image_size / batch_size);
/// the others speak the standard OpenAI images schema. Responses return
/// either a URL (downloaded to `dest`) or base64 (decoded to `dest`).
final class OpenAIImagesClient: @unchecked Sendable {

    enum Provider {
        case deepinfra
        case siliconflow
        case custom(baseURL: String)

        /// Default endpoint when the user configured no base URL override.
        var defaultBaseURL: String {
            switch self {
            case .deepinfra: return "https://api.deepinfra.com"
            case .siliconflow: return "https://api.siliconflow.cn"
            case .custom(let b): return b
            }
        }
    }

    struct Request {
        var model: String
        var prompt: String
        var size: String            // "WxH", e.g. "1024x1024"
        var n: Int
        var seed: Int? = nil
    }

    /// Generates images and writes each one to `dest` (suffix -1, -2, … when
    /// multiple). Returns the saved file URLs in order.
    func generate(
        provider: Provider,
        apiKey: String,
        request: Request,
        dest: URL
    ) async throws -> [URL] {
        let base = provider.defaultBaseURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(base)/v1/images/generations") else {
            throw OpenAIImagesError.badURL
        }

        var body: [String: Any]
        if case .siliconflow = provider {
            // SiliconFlow request schema.
            body = [
                "model": request.model,
                "prompt": request.prompt,
                "image_size": request.size,
                "batch_size": max(1, request.n),
            ]
            if let s = request.seed { body["seed"] = s }
        } else {
            // Standard OpenAI images schema.
            body = [
                "model": request.model,
                "prompt": request.prompt,
                "size": request.size,
                "n": max(1, request.n),
                "response_format": "b64_json",
            ]
            if let s = request.seed { body["seed"] = s }
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIImagesError.badResponse("no HTTP response")
        }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw OpenAIImagesError.http(http.statusCode, String(msg.prefix(220)))
        }

        let decoded: ImagesResponse
        do {
            decoded = try JSONDecoder().decode(ImagesResponse.self, from: data)
        } catch {
            throw OpenAIImagesError.badResponse(
                String((String(data: data, encoding: .utf8) ?? "").prefix(200)))
        }
        guard !decoded.data.isEmpty else { throw OpenAIImagesError.noImage }

        var saved: [URL] = []
        for (i, item) in decoded.data.enumerated() {
            let target: URL
            if i == 0 {
                target = dest
            } else {
                let ext = dest.pathExtension
                target = dest.deletingLastPathComponent()
                    .appendingPathComponent("\(dest.deletingPathExtension().lastPathComponent)-\(i + 1).\(ext)")
            }
            try? FileManager.default.removeItem(at: target)
            if let b64 = item.b64_json, !b64.isEmpty, let img = Data(base64Encoded: b64) {
                try img.write(to: target)
            } else if let u = item.url, let remote = URL(string: u) {
                let (bytes, dlResp) = try await URLSession.shared.data(from: remote)
                guard let h = dlResp as? HTTPURLResponse, h.statusCode == 200, !bytes.isEmpty else {
                    throw OpenAIImagesError.badResponse("image download failed")
                }
                try bytes.write(to: target)
            } else {
                throw OpenAIImagesError.noImage
            }
            saved.append(target)
        }
        return saved
    }

    /// Cheap key validation. SiliconFlow and OpenAI-compatible gateways gate
    /// GET /v1/models behind the key, so a 200 there proves the key. DeepInfra's
    /// model list is public, so instead run a one-image FLUX-schnell probe at
    /// 256×256 (~$0.0003) — the only request that genuinely exercises the key.
    func validate(provider: Provider, apiKey: String) async throws -> String {
        if case .deepinfra = provider {
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("blstudio-di-validate-\(UUID().uuidString.prefix(6)).png")
            defer { try? FileManager.default.removeItem(at: dest) }
            _ = try await generate(
                provider: provider, apiKey: apiKey,
                request: Request(model: "black-forest-labs/FLUX-1-schnell",
                                 prompt: "a tiny red dot", size: "256x256", n: 1),
                dest: dest)
            return "OK · generated 256×256 probe"
        }

        let base = provider.defaultBaseURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(base)/v1/models") else {
            throw OpenAIImagesError.badURL
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIImagesError.badResponse("no HTTP response")
        }
        if http.statusCode == 200 { return "OK · authenticated" }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw OpenAIImagesError.http(http.statusCode, "key rejected")
        }
        let msg = String(data: data, encoding: .utf8) ?? ""
        throw OpenAIImagesError.http(http.statusCode, String(msg.prefix(180)))
    }

    /// Best-effort image-capable model suggestions from GET /v1/models.
    /// The OpenAI images list doesn't tag capabilities, so filter on known
    /// image-model name patterns and fall back to a curated set.
    func listImageModels(provider: Provider, apiKey: String) async -> [String] {
        var curated: [String]
        switch provider {
        case .deepinfra:
            curated = ModelCatalog.deepInfraImageModels
        case .siliconflow:
            curated = ModelCatalog.siliconFlowImageModels
        case .custom:
            curated = []
        }
        let base = provider.defaultBaseURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(base)/v1/models") else { return curated }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(ModelsResponse.self, from: data) else {
            return curated
        }
        let imageish = decoded.data.map(\.id).filter { id in
            let m = id.lowercased()
            return m.contains("flux") || m.contains("stable-diffusion")
                || m.contains("sdxl") || m.hasPrefix("sd")
                || m.contains("kolors") || m.contains("qwen-image")
                || m.contains("imagen") || m.contains("dall-e")
                || m.contains("seedance") || m.contains("gpt-image")
                || m.contains("irag") || m.contains("klein")
        }
        let merged = curated + imageish
        var seen = Set<String>()
        return merged.filter { seen.insert($0).inserted }
    }
}

// MARK: - Response models

struct ImagesResponse: Codable, Sendable {
    struct Item: Codable, Sendable {
        var url: String?
        var b64_json: String?
    }
    var data: [Item]
    struct APIError: Codable, Sendable {
        var message: String?
        var code: String?
    }
    var error: APIError?
}

struct ModelsResponse: Codable, Sendable {
    struct Item: Codable, Sendable {
        var id: String
    }
    var data: [Item]
}

// MARK: - Errors

enum OpenAIImagesError: LocalizedError {
    case badURL
    case noImage
    case badResponse(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Invalid image API URL (check the base URL in the API Keys tab)."
        case .noImage:
            return "The provider returned no image data."
        case .badResponse(let head):
            return "Could not parse image API response: \(head)"
        case .http(let code, let body):
            return "Image API HTTP \(code): \(body)"
        }
    }
}
