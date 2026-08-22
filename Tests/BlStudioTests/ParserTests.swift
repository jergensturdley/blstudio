import XCTest
@testable import BlStudio

final class ParserTests: XCTestCase {

    // MARK: Image generation result

    func testDecodeImageResult() throws {
        let json = """
        {"urls":["https://example.com/a.png"],"saved":["/tmp/images/a.png"],"total":1,"task_id":"abc"}
        """
        let out = BLProcessOutput(stdout: json, stderr: "", exitCode: 0)
        let result = try BLClient.decode(ImageGenerationResult.self, from: out)
        XCTAssertEqual(result.urls, ["https://example.com/a.png"])
        XCTAssertEqual(result.saved, ["/tmp/images/a.png"])
        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.task_id, "abc")
    }

    func testDecodeImageResultMultiple() throws {
        let json = """
        {"urls":["u1","u2","u3"],"saved":["s1","s2","s3"],"total":3,"task_ids":["t1","t2","t3"]}
        """
        let out = BLProcessOutput(stdout: json, stderr: "", exitCode: 0)
        let result = try BLClient.decode(ImageGenerationResult.self, from: out)
        XCTAssertEqual(result.total, 3)
        XCTAssertEqual(result.task_ids?.count, 3)
    }

    // MARK: Error envelope

    func testDecodeErrorEnvelopeThrowsAPIError() {
        let json = """
        {"error":{"code":3,"message":"Console session is not logged in or has expired.","hint":"Run `bl auth login --console`."}}
        """
        let out = BLProcessOutput(stdout: json, stderr: "", exitCode: 1)
        XCTAssertThrowsError(try BLClient.decode([FreeTierQuota].self, from: out)) { error in
            guard case BLClientError.apiError(let code, let message, let hint) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(code, 3)
            XCTAssertTrue(message.contains("Console session"))
            XCTAssertNotNil(hint)
        }
    }

    func testErrorEnvelopeDetectedEvenWithExitZero() {
        let json = """
        {"error":{"code":7,"message":"quota exhausted","hint":null}}
        """
        let out = BLProcessOutput(stdout: json, stderr: "", exitCode: 0)
        XCTAssertThrowsError(try BLClient.decode(ChatCompletion.self, from: out))
    }

    // MARK: Chat completion

    func testDecodeChatCompletion() throws {
        let json = """
        {
          "id": "chatcmpl-1",
          "object": "chat.completion",
          "created": 1787379065,
          "model": "qwen3.8-max",
          "choices": [{
            "index": 0,
            "message": {"role": "assistant", "reasoning_content": "think", "content": "OK"},
            "finish_reason": "stop",
            "logprobs": null
          }],
          "usage": {
            "prompt_tokens": 50,
            "total_tokens": 73,
            "completion_tokens": 23
          }
        }
        """
        let out = BLProcessOutput(stdout: json, stderr: "", exitCode: 0)
        let result = try BLClient.decode(ChatCompletion.self, from: out)
        XCTAssertEqual(result.content, "OK")
        XCTAssertEqual(result.reasoning, "think")
        XCTAssertEqual(result.usage?.total_tokens, 73)
        XCTAssertEqual(result.model, "qwen3.8-max")
    }

    // MARK: Usage free

    func testDecodeUsageFree() throws {
        let json = """
        [
          {"model":"qwen3-max","type":"Text","remaining":900000,"total":1000000,
           "usagePercent":10.0,"remainingPercent":90.0,"expires":"2026-12-31","autoStop":true},
          {"model":"qwen-image-3.0","type":"Image","remaining":12,"total":50,
           "usagePercent":76.0,"remainingPercent":24.0,"expires":null,"autoStop":null}
        ]
        """
        let out = BLProcessOutput(stdout: json, stderr: "", exitCode: 0)
        let result = try BLClient.decode([FreeTierQuota].self, from: out)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[1].model, "qwen-image-3.0")
        XCTAssertEqual(result[1].remaining, 12)
        XCTAssertNil(result[1].autoStop)
        XCTAssertEqual(result[0].autoStop, true)
    }

    // MARK: Auth status

    func testDecodeAuthStatus() throws {
        let json = """
        {
          "authenticated": true,
          "config": "default",
          "api_key": {"source":"config","masked":"sk-w...EyMg","base_url":"https://x"},
          "console": {"source":"config","masked":"c352...b7ca","region":"ap-southeast-1","site":"international"}
        }
        """
        let out = BLProcessOutput(stdout: json, stderr: "", exitCode: 0)
        let result = try BLClient.decode(AuthStatus.self, from: out)
        XCTAssertEqual(result.authenticated, true)
        XCTAssertEqual(result.api_key?.masked, "sk-w...EyMg")
    }

    // MARK: JSON extraction from noisy output

    func testExtractJSONWithTrailingBanner() {
        let noisy = """
        {"urls":[],"saved":[],"total":0}

          Update available: 1.14.2 → 1.17.1
          Run bl update to upgrade
        """
        let data = BLJSON.extract(noisy)
        XCTAssertNotNil(data)
        let decoded = try? JSONDecoder().decode(ImageGenerationResult.self, from: data!)
        XCTAssertEqual(decoded?.total, 0)
    }

    func testExtractJSONLeadingGarbageIsHandledWhenStartingWithBrace() {
        // bl writes progress to stderr; stdout should start with the document.
        XCTAssertNil(BLJSON.extract("no json here"))
        XCTAssertNil(BLJSON.extract(""))
    }

    // MARK: Key masking

    func testMaskAPIKey() {
        XCTAssertEqual(maskAPIKey("sk-1234567890abcdef"), "sk-123…cdef")
        XCTAssertEqual(maskAPIKey("short"), "•••••")
    }

    // MARK: Seed parsing

    func testParseSeed() throws {
        XCTAssertNil(try parseSeed(enabled: false, text: "ignored"))
        XCTAssertEqual(try parseSeed(enabled: true, text: "42"), 42)
        XCTAssertEqual(try parseSeed(enabled: true, text: " 7 "), 7)
        XCTAssertThrowsError(try parseSeed(enabled: true, text: ""))
        XCTAssertThrowsError(try parseSeed(enabled: true, text: "12.5"))
        XCTAssertThrowsError(try parseSeed(enabled: true, text: "-1"))
        XCTAssertThrowsError(try parseSeed(enabled: true, text: "2147483648"))
        XCTAssertEqual(try parseSeed(enabled: true, text: "2147483647"), 2_147_483_647)
    }

    // MARK: Prefix generation

    @MainActor
    func testOutPrefix() {
        let p = AppState.outPrefix(for: "A cat in a spacesuit!", kind: "img")
        XCTAssertTrue(p.hasPrefix("a-cat-in-") || p.hasPrefix("img-"), "got \(p)")
        XCTAssertTrue(p.contains("-"))
    }
}

final class LedgerTests: XCTestCase {

    @MainActor
    func testSummaryAggregation() {
        let ledger = UsageLedger(fileURL: AppPaths.makeTempUsageFile())
        ledger.record(UsageEvent(keyId: nil, kind: .imageGenerate, model: "m", at: Date(),
                                 images: 2, promptTokens: 0, completionTokens: 0,
                                 durationMs: 100, ok: true))
        ledger.record(UsageEvent(keyId: nil, kind: .chat, model: "m", at: Date(),
                                 images: 0, promptTokens: 10, completionTokens: 5,
                                 durationMs: 100, ok: true))
        let s = ledger.summary(keyId: nil)
        XCTAssertEqual(s.images, 2)
        XCTAssertEqual(s.chats, 1)
        XCTAssertEqual(s.totalTokens, 15)
        let series = ledger.dailySeries(keyId: nil)
        XCTAssertEqual(series.count, 14)
        XCTAssertEqual(series.last?.images, 2)
    }
}
