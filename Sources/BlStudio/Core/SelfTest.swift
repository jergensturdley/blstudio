import Foundation
import SwiftUI

/// Headless smoke tests runnable via `BlStudio --selftest` (no XCTest required).
/// Returns a process exit code: 0 = all passed.
enum SelfTest {

    static func run() async -> Int32 {
        var failures = 0

        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("PASS  \(name)")
            } else {
                print("FAIL  \(name)")
                failures += 1
            }
        }

        // 1. Image result decoding
        let imageJSON = """
        {"urls":["https://example.com/a.png"],"saved":["/tmp/images/a.png"],"total":1,"task_id":"abc"}
        """
        if let r = try? BLClient.decode(ImageGenerationResult.self,
                                        from: BLProcessOutput(stdout: imageJSON, stderr: "", exitCode: 0)) {
            check("image result decode", r.saved == ["/tmp/images/a.png"] && r.total == 1)
        } else {
            check("image result decode", false)
        }

        // 2. Error envelope → apiError
        let errJSON = """
        {"error":{"code":3,"message":"Console session is not logged in or has expired.","hint":"Run `bl auth login --console`."}}
        """
        do {
            _ = try BLClient.decode([FreeTierQuota].self,
                                    from: BLProcessOutput(stdout: errJSON, stderr: "", exitCode: 1))
            check("error envelope detection", false)
        } catch BLClientError.apiError(let code, _, _) {
            check("error envelope detection", code == 3)
        } catch {
            check("error envelope detection", false)
        }

        // 3. Chat completion decoding
        let chatJSON = """
        {"id":"x","model":"qwen3.8-max",
         "choices":[{"index":0,"message":{"role":"assistant","reasoning_content":"r","content":"OK"},"finish_reason":"stop"}],
         "usage":{"prompt_tokens":50,"completion_tokens":23,"total_tokens":73}}
        """
        if let c = try? BLClient.decode(ChatCompletion.self,
                                        from: BLProcessOutput(stdout: chatJSON, stderr: "", exitCode: 0)) {
            check("chat completion decode", c.content == "OK" && c.usage?.total_tokens == 73)
        } else {
            check("chat completion decode", false)
        }

        // 4. Usage-free array decoding
        let usageJSON = """
        [{"model":"qwen-image-3.0","type":"Image","remaining":12,"total":50,
          "usagePercent":76.0,"remainingPercent":24.0,"expires":null,"autoStop":null}]
        """
        if let u = try? BLClient.decode([FreeTierQuota].self,
                                        from: BLProcessOutput(stdout: usageJSON, stderr: "", exitCode: 0)) {
            check("usage free decode", u.first?.remaining == 12 && u.first?.autoStop == nil)
        } else {
            check("usage free decode", false)
        }

        // 5. JSON extraction from noisy stdout
        let noisy = """
        {"urls":[],"saved":[],"total":0}

          Update available: 1.14.2 → 1.17.1
        """
        check("noisy stdout extraction", BLJSON.extract(noisy) != nil)
        check("no-json rejection", BLJSON.extract("no json") == nil)

        // 6. Key masking
        check("key masking", maskAPIKey("sk-1234567890abcdef") == "sk-123…cdef")

        // 7. Prefix helper
        let prefix = AppState.outPrefix(for: "A cat in a spacesuit!", kind: "img")
        check("out prefix", prefix.hasPrefix("a-cat-in-"))

        // 7b. Seed parsing/validation
        do {
            let off = try parseSeed(enabled: false, text: "")
            let on = try parseSeed(enabled: true, text: "42")
            check("seed parsing", off == nil && on == 42)
        } catch {
            check("seed parsing", false)
        }
        var badSeedRejected = false
        do { _ = try parseSeed(enabled: true, text: "12.5") } catch { badSeedRejected = true }
        check("seed validation rejects non-integer", badSeedRejected)
        var emptySeedRejected = false
        do { _ = try parseSeed(enabled: true, text: "  ") } catch { emptySeedRejected = true }
        check("seed validation rejects empty", emptySeedRejected)

        // 7c. MiniMax response decoding
        let mmOK = """
        {"base_resp":{"status_code":0,"status_msg":"success"},
         "data":{"image_urls":["https://example.com/a.jpg","https://example.com/b.jpg"]}}
        """
        if let r = try? MiniMaxClient.decode(Data(mmOK.utf8)) {
            check("minimax success decode",
                  r.base_resp?.status_code == 0 && r.data?.image_urls?.count == 2)
        } else {
            check("minimax success decode", false)
        }
        let mmErr = """
        {"base_resp":{"status_code":1004,"status_msg":"login fail"}}
        """
        if let r = try? MiniMaxClient.decode(Data(mmErr.utf8)) {
            check("minimax error decode", r.base_resp?.status_code == 1004)
        } else {
            check("minimax error decode", false)
        }

        // 7b. MiniMax video response decoding.
        let mvTask = """
        {"base_resp":{"status_code":0,"status_msg":"success"},"task_id":"abc123"}
        """
        if let t = try? JSONDecoder().decode(MiniMaxVideoTask.self, from: Data(mvTask.utf8)) {
            check("minimax video task decode", t.task_id == "abc123" && t.base_resp?.status_code == 0)
        } else {
            check("minimax video task decode", false)
        }
        let mvQuery = """
        {"base_resp":{"status_code":0,"status_msg":"success"},"status":"Success","file_id":"file_42"}
        """
        if let q = try? JSONDecoder().decode(MiniMaxVideoQuery.self, from: Data(mvQuery.utf8)) {
            check("minimax video query decode", q.status == "Success" && q.file_id == "file_42")
        } else {
            check("minimax video query decode", false)
        }
        let mvFile = """
        {"base_resp":{"status_code":0,"status_msg":"success"},
         "file":{"download_url":"https://cdn.minimax.io/v/xyz.mp4","filename":"video.mp4"}}
        """
        if let f = try? JSONDecoder().decode(MiniMaxFileRetrieve.self, from: Data(mvFile.utf8)) {
            check("minimax file retrieve decode", f.file?.download_url?.hasSuffix(".mp4") == true)
        } else {
            check("minimax file retrieve decode", false)
        }

        // 7c. Gemini image response decoding (base64 inline image part).
        let geminiOK = """
        {"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"image/png","data":"aGVsbG8="}}]},
         "finishReason":"STOP"}]}
        """
        if let g = try? JSONDecoder().decode(GeminiGenResponse.self, from: Data(geminiOK.utf8)) {
            let part = g.candidates?.first?.content?.parts?.first
            check("gemini image decode",
                  part?.inlineData?.mimeType == "image/png" && part?.inlineData?.data == "aGVsbG8=")
        } else {
            check("gemini image decode", false)
        }

        // 7d. MiniMax audio response decoding (music / speech). URL mode and hex mode.
        let audioURL = """
        {"data":{"audio":"https://cdn.minimax.io/song.mp3"},
         "base_resp":{"status_code":0,"status_msg":"success"}}
        """
        if let a = try? JSONDecoder().decode(MiniMaxAudioResult.self, from: Data(audioURL.utf8)) {
            check("minimax audio decode (url)", a.data?.audio?.hasPrefix("https://") == true)
        } else {
            check("minimax audio decode (url)", false)
        }
        let hexBytes = MiniMaxClient.hexToData("deadbeef")
        check("minimax hex audio decode", hexBytes == Data([0xde, 0xad, 0xbe, 0xef]))

        // 8. Live integration (only if bl is installed): dry-run + auth status
        let client = BLClient()
        if let _ = try? client.resolveBinary() {
            do {
                let version = try await client.cliVersion()
                check("bl --version", version.contains("bl"))
            } catch {
                check("bl --version (\(error.localizedDescription))", false)
            }
            do {
                let out = try await client.run(arguments: [
                    "image", "generate", "--prompt", "selftest", "--dry-run", "--output", "json",
                ], timeoutSeconds: 60)
                check("bl image generate --dry-run",
                      out.exitCode == 0 && out.stdout.contains("selftest"))
            } catch {
                check("bl image generate --dry-run (\(error.localizedDescription))", false)
            }
            do {
                let status = try await client.authStatus()
                check("bl auth status decode", status.authenticated != nil || status.error != nil)
            } catch {
                check("bl auth status decode (\(error.localizedDescription))", false)
            }
        } else {
            print("SKIP  live bl integration (binary not found)")
        }

        print(failures == 0 ? "\nAll self-tests passed." : "\n\(failures) self-test(s) FAILED.")
        return failures == 0 ? 0 : 1
    }

    /// Offscreen render of every feature view to force body evaluation.
    /// Must run on the main thread (call from `--viewprobe` mode).
    @MainActor
    static func runViewProbe() -> Int32 {
        var fails = 0
        let state = AppState()
        let named: [(String, AnyView)] = [
            ("GenerateView", AnyView(GenerateView().environment(state))),
            ("EditView", AnyView(EditView().environment(state))),
            ("VideoView", AnyView(VideoView().environment(state))),
            ("MusicView", AnyView(MusicView().environment(state))),
            ("SpeechView", AnyView(SpeechView().environment(state))),
            ("ChatView", AnyView(ChatView().environment(state))),
            ("GalleryView", AnyView(GalleryView().environment(state))),
            ("QuotaView", AnyView(QuotaView().environment(state))),
            ("KeysView", AnyView(KeysView().environment(state))),
            ("SettingsView", AnyView(SettingsView().environment(state))),
            ("RootView", AnyView(RootView().environment(state))),
        ]
        for (name, view) in named {
            let renderer = ImageRenderer(content: view.frame(width: 1120, height: 720))
            renderer.scale = 1.0
            if renderer.nsImage != nil {
                print("PASS  render \(name)")
            } else {
                print("FAIL  render \(name)")
                fails += 1
            }
        }
        print(fails == 0 ? "\nAll view probes passed." : "\n\(fails) view probe(s) FAILED.")
        return fails == 0 ? 0 : 1
    }
}
