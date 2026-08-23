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

    // MARK: Video (Hailuo)

    /// POST /v1/video_generation. Returns the async task id.
    func videoGenerate(
        apiKey: String,
        model: String,
        prompt: String,
        firstFrameImage: String? = nil,
        duration: Int? = nil,
        resolution: String? = nil
    ) async throws -> String {
        guard let url = URL(string: "\(baseURL)/v1/video_generation") else { throw MiniMaxError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["model": model, "prompt": prompt]
        if let f = firstFrameImage, !f.isEmpty { payload["first_frame_image"] = f }
        if let d = duration { payload["duration"] = d }
        if let r = resolution, !r.isEmpty { payload["resolution"] = r }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.checkHTTP(response, data: data)
        let decoded = try JSONDecoder().decode(MiniMaxVideoTask.self, from: data)
        if let br = decoded.base_resp, br.status_code != 0 {
            throw MiniMaxError.api(status: br.status_code,
                                   message: br.status_msg ?? "video submit failed")
        }
        guard let taskId = decoded.task_id, !taskId.isEmpty else {
            throw MiniMaxError.badResponse("missing task_id")
        }
        return taskId
    }

    /// GET /v1/query/video_generation?task_id=...
    func queryVideo(apiKey: String, taskId: String) async throws -> MiniMaxVideoQuery {
        guard let url = URL(string: "\(baseURL)/v1/query/video_generation?task_id=\(taskId)") else {
            throw MiniMaxError.badURL
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.checkHTTP(response, data: data)
        let decoded = try JSONDecoder().decode(MiniMaxVideoQuery.self, from: data)
        if let br = decoded.base_resp, br.status_code != 0 {
            throw MiniMaxError.api(status: br.status_code,
                                   message: br.status_msg ?? "video query failed")
        }
        return decoded
    }

    /// GET /v1/files/retrieve?file_id=... Returns the download URL.
    func retrieveFileURL(apiKey: String, fileId: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/v1/files/retrieve?file_id=\(fileId)") else {
            throw MiniMaxError.badURL
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.checkHTTP(response, data: data)
        let decoded = try JSONDecoder().decode(MiniMaxFileRetrieve.self, from: data)
        if let br = decoded.base_resp, br.status_code != 0 {
            throw MiniMaxError.api(status: br.status_code,
                                   message: br.status_msg ?? "file retrieve failed")
        }
        guard let dl = decoded.file?.download_url, !dl.isEmpty else {
            throw MiniMaxError.badResponse("missing download_url")
        }
        return dl
    }

    /// Downloads a video file to `dest`.
    @discardableResult
    func downloadVideo(_ urlString: String, to dest: URL) async throws -> URL {
        guard let u = URL(string: urlString) else { throw MiniMaxError.badResponse("invalid video URL") }
        let (tmp, response) = try await URLSession.shared.download(from: u)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tmp)
            throw MiniMaxError.http(http.statusCode, "video download failed")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    // MARK: Music

    /// Generates a song synchronously via POST /v1/music_generation.
    /// `dest` is where the mp3 is written; returns the saved file.
    func musicGenerate(
        apiKey: String,
        model: String,
        prompt: String,
        lyrics: String? = nil,
        dest: URL
    ) async throws -> URL {
        guard let url = URL(string: "\(baseURL)/v1/music_generation") else { throw MiniMaxError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "audio_setting": ["sample_rate": 44100, "bitrate": 256000, "format": "mp3", "channel": 2],
            "output_format": "url",
        ]
        if let lyrics = lyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !lyrics.isEmpty {
            body["lyrics"] = lyrics
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw MiniMaxError.badResponse("no HTTP response") }

        let text = String(data: data, encoding: .utf8) ?? ""
        guard http.statusCode == 200 else { throw MiniMaxError.http(http.statusCode, String(text.prefix(200))) }
        let decoded = try JSONDecoder().decode(MiniMaxAudioResult.self, from: data)
        if let br = decoded.base_resp, br.status_code != 0 {
            throw MiniMaxError.api(status: br.status_code, message: br.status_msg ?? "unknown error")
        }
        guard let audio = decoded.data?.audio, !audio.isEmpty else {
            throw MiniMaxError.badResponse("no audio returned")
        }
        return try await saveMiniMaxAudio(audio, to: dest)
    }

    // MARK: Speech (text-to-audio)

    /// Converts text to speech synchronously via POST /v1/t2a_v2.
    /// `dest` is where the audio file is written; returns the saved file.
    func speechGenerate(
        apiKey: String,
        model: String,
        text: String,
        voiceId: String,
        speed: Double,
        emotion: String,
        dest: URL
    ) async throws -> URL {
        guard let url = URL(string: "\(baseURL)/v1/t2a_v2") else { throw MiniMaxError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 180
        let body: [String: Any] = [
            "model": model,
            "text": text,
            "voice_setting": [
                "voice_id": voiceId,
                "speed": speed,
                "vol": 1.0,
                "pitch": 0,
                "emotion": emotion,
            ],
            "audio_setting": ["sample_rate": 32000, "bitrate": 128000, "format": "mp3", "channel": 1],
            "language_boost": "auto",
            "output_format": "url",
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw MiniMaxError.badResponse("no HTTP response") }

        let text = String(data: data, encoding: .utf8) ?? ""
        guard http.statusCode == 200 else { throw MiniMaxError.http(http.statusCode, String(text.prefix(200))) }
        let decoded = try JSONDecoder().decode(MiniMaxAudioResult.self, from: data)
        if let br = decoded.base_resp, br.status_code != 0 {
            throw MiniMaxError.api(status: br.status_code, message: br.status_msg ?? "unknown error")
        }
        guard let audio = decoded.data?.audio, !audio.isEmpty else {
            throw MiniMaxError.badResponse("no audio returned")
        }
        return try await saveMiniMaxAudio(audio, to: dest)
    }

    /// Saves a MiniMax audio payload. With `output_format: "url"` the value is a
    /// downloadable URL; otherwise MiniMax returns the audio hex-encoded.
    private func saveMiniMaxAudio(_ audio: String, to dest: URL) async throws -> URL {
        let trimmed = audio.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("http") {
            return try await downloadVideo(trimmed, to: dest)
        }
        guard let bytes = Self.hexToData(trimmed) else {
            throw MiniMaxError.badResponse("could not decode audio payload")
        }
        try? FileManager.default.removeItem(at: dest)
        try bytes.write(to: dest)
        return dest
    }

    static func hexToData(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            guard let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex),
                  let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            data.append(byte)
            idx = next
        }
        return data
    }

    /// Submits a video task, polls until it finishes, then downloads it to `dest`.
    /// `Task.sleep` propagates cancellation, so wrapping this in a cancellable
    /// task gives cancel support.
    func generateVideoAndWait(
        apiKey: String,
        model: String,
        prompt: String,
        firstFrameImage: String? = nil,
        duration: Int? = nil,
        resolution: String? = nil,
        dest: URL,
        pollSeconds: Int = 10,
        maxWaitSeconds: Int = 1500,
        onStatus: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        let taskId = try await videoGenerate(apiKey: apiKey, model: model, prompt: prompt,
                                             firstFrameImage: firstFrameImage,
                                             duration: duration, resolution: resolution)
        onStatus?("Submitted video task…")
        let deadline = Date().addingTimeInterval(TimeInterval(maxWaitSeconds))
        while true {
            try await Task.sleep(nanoseconds: UInt64(pollSeconds) * 1_000_000_000)
            if Date() > deadline { throw MiniMaxError.timeout }
            let q = try await queryVideo(apiKey: apiKey, taskId: taskId)
            let status = q.status ?? ""
            onStatus?("Video \(status)…")
            if status == "Fail" {
                throw MiniMaxError.api(status: q.base_resp?.status_code ?? -1,
                                       message: "video generation failed")
            }
            if status == "Success" {
                guard let fileId = q.file_id else { throw MiniMaxError.badResponse("missing file_id") }
                let dl = try await retrieveFileURL(apiKey: apiKey, fileId: fileId)
                return try await downloadVideo(dl, to: dest)
            }
        }
    }

    /// Shared HTTP status check.
    private static func checkHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw MiniMaxError.badResponse("no HTTP response") }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MiniMaxError.http(http.statusCode, String(body.prefix(200)))
        }
    }
}

/// Response for POST /v1/video_generation.
struct MiniMaxVideoTask: Codable, Sendable {
    var task_id: String?
    var base_resp: MiniMaxImageResult.BaseResp?
}

/// Response for GET /v1/query/video_generation.
struct MiniMaxVideoQuery: Codable, Sendable {
    var status: String?
    var file_id: String?
    var base_resp: MiniMaxImageResult.BaseResp?
}

/// Response for GET /v1/files/retrieve.
struct MiniMaxFileRetrieve: Codable, Sendable {
    struct FileInfo: Codable, Sendable {
        var download_url: String?
        var filename: String?
    }
    var file: FileInfo?
    var base_resp: MiniMaxImageResult.BaseResp?
}

/// Generic envelope used where only `base_resp` matters.
struct MiniMaxBaseEnvelope: Codable, Sendable {
    var base_resp: MiniMaxImageResult.BaseResp?
}

/// Response envelope for /v1/music_generation and /v1/t2a_v2.
/// `data.audio` is a URL when `output_format: "url"` was requested,
/// otherwise the raw audio hex-encoded.
struct MiniMaxAudioResult: Codable, Sendable {
    struct Payload: Codable, Sendable {
        var audio: String?
        var extra_info: String?
    }
    var base_resp: MiniMaxImageResult.BaseResp?
    var data: Payload?
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
    case noVideo
    case timeout
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
        case .noVideo:
            return "MiniMax returned no video."
        case .timeout:
            return "MiniMax video generation timed out."
        case .badResponse(let head):
            return "Could not parse MiniMax response: \(head)"
        case .http(let code, let body):
            return "MiniMax HTTP \(code): \(body)"
        }
    }
}
