import Foundation

/// Client for Pollinations.ai, a free, keyless text-to-image API.
/// A GET to /prompt/<text> returns raw image bytes. Multiple images are
/// produced by fanning out with different seeds (done by the caller).
final class PollinationsClient: @unchecked Sendable {
    static let baseURL = "https://image.pollinations.ai"

    /// Generates a single image and saves it to `dest`. Returns `dest`.
    func generate(
        prompt: String,
        model: String?,
        width: Int,
        height: Int,
        seed: Int?,
        dest: URL
    ) async throws -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encodedPrompt = prompt.addingPercentEncoding(withAllowedCharacters: allowed) ?? prompt

        var query: [String] = []
        if let m = model, !m.isEmpty { query.append("model=\(m)") }
        query.append("width=\(width)")
        query.append("height=\(height)")
        query.append("nologo=true")
        if let s = seed { query.append("seed=\(s)") }

        let urlString = "\(Self.baseURL)/prompt/\(encodedPrompt)?\(query.joined(separator: "&"))"
        guard let url = URL(string: urlString) else { throw PollinationsError.badURL }

        var req = URLRequest(url: url)
        req.timeoutInterval = 240

        let (tmp, response) = try await URLSession.shared.download(for: req)
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: tmp)
            throw PollinationsError.badResponse("no HTTP response")
        }
        guard http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tmp)
            throw PollinationsError.http(http.statusCode)
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}

enum PollinationsError: LocalizedError {
    case badURL
    case badResponse(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Invalid Pollinations URL."
        case .badResponse(let head):
            return "Could not read Pollinations response: \(head)"
        case .http(let code):
            return "Pollinations HTTP \(code). The free service may be busy; try again."
        }
    }
}

// MARK: - Public model catalog

/// Pulls the live model catalog from Pollinations' public `/models` endpoint.
/// The endpoint is keyless; the catalog is a JSON array of strings. Used by
/// the Generate tab's "Refresh models" button.
enum PollinationsModelCatalog {
    static let modelsURL = URL(string: "https://image.pollinations.ai/models")!

    static func fetch(timeoutSeconds: TimeInterval = 15) async throws -> [String] {
        var req = URLRequest(url: modelsURL)
        req.timeoutInterval = timeoutSeconds
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw PollinationsError.http(code)
        }
        // Some deployments wrap the list in `{models: [...]}` or return a bare
        // array; accept either.
        if let arr = try? JSONDecoder().decode([String].self, from: data) {
            return arr
        }
        if let obj = try? JSONDecoder().decode(Wrapper.self, from: data) {
            return obj.models
        }
        let preview = String(data: data.prefix(160), encoding: .utf8) ?? ""
        throw PollinationsError.badResponse(preview)
    }

    private struct Wrapper: Decodable {
        var models: [String]
    }
}
