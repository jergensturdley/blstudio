import Foundation

/// HTTP client for Fish Audio text-to-speech.
///
/// Unlike MiniMax, Fish returns the audio directly as the response body
/// (a binary stream), so `tts` writes `data` straight to disk. Errors come
/// back as JSON with a `message` field.
final class FishClient: @unchecked Sendable {
    static let baseURL = "https://api.fish.audio"

    /// Generates speech via POST /v1/tts and saves it to `dest`.
    /// `referenceId` selects a Fish voice model; pass nil for the default voice.
    func tts(
        apiKey: String,
        text: String,
        referenceId: String?,
        dest: URL
    ) async throws -> URL {
        guard let url = URL(string: "\(Self.baseURL)/v1/tts") else { throw FishError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [
            "text": text,
            "format": "mp3",
            "normalize": true,
            "latency": "normal",
        ]
        if let ref = referenceId?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty {
            payload["reference_id"] = ref
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw FishError.badResponse("no HTTP response") }

        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let msg = Self.errorMessage(from: body) ?? String(body.prefix(200))
            throw FishError.http(http.statusCode, msg)
        }

        guard !data.isEmpty else { throw FishError.badResponse("empty audio") }
        try? FileManager.default.removeItem(at: dest)
        try data.write(to: dest)
        return dest
    }

    /// Validates a key by running a tiny TTS request and discarding the audio.
    /// This consumes a negligible amount of credits but is the only reliable
    /// way to confirm a Fish key, since unauthenticated routes return 404.
    func validate(apiKey: String) async throws -> String {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fish-validate-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try await tts(apiKey: apiKey, text: "Hi.", referenceId: nil, dest: tmp)
        return "OK · authenticated"
    }

    private static func errorMessage(from body: String) -> String? {
        struct Envelope: Codable { var message: String? }
        if let e = try? JSONDecoder().decode(Envelope.self, from: Data(body.utf8)),
           let m = e.message, !m.isEmpty {
            return m
        }
        return nil
    }
}

enum FishError: LocalizedError {
    case badURL
    case badResponse(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Invalid Fish Audio API URL."
        case .badResponse(let s):
            return "Fish Audio returned an unexpected response: \(s)"
        case .http(let code, let s):
            return "Fish Audio error \(code): \(s)"
        }
    }
}
