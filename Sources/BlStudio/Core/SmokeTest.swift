import Foundation

/// Live endpoint smoke test run inside the app binary, so Keychain reads work
/// without extra authorization prompts.
///
///   BlStudio --smoketest        free checks (same endpoints as the Test buttons)
///   BlStudio --smoketest full   adds one small generation per provider
///
/// Paid probes in `full` mode are deliberately tiny: one MiniMax image, one short
/// TTS clip, one free-tier song, one Gemini image, one Hugging Face image.
enum SmokeTest {

    @MainActor
    static func run(full: Bool, only: [String] = []) async -> Int32 {
        // Line-buffer stdout so progress shows up live when piped.
        setvbuf(stdout, nil, _IOLBF, 0)

        let app = AppState()
        var failures = 0

        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            let suffix = detail.isEmpty ? "" : " (\(detail))"
            print("\(ok ? "PASS " : "FAIL ") \(name)\(suffix)")
            if !ok { failures += 1 }
        }
        func note(_ s: String) { print("INFO  \(s)") }
        func include(_ name: String) -> Bool {
            only.isEmpty || only.contains { name.lowercased().contains($0.lowercased()) }
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("blstudio-smoke-\(String(UUID().uuidString.prefix(8)))",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        note(full ? "mode: full (small paid probes included)" : "mode: free checks only")

        // MARK: bl CLI (Bailian default profile)

        if include("bailian") || include("bl") {
            do {
                let v = try await app.client.cliVersion()
                check("bl CLI", true, v)
            } catch {
                check("bl CLI", false, error.localizedDescription)
            }
            do {
                var req = ChatRequest(message: "ping")
                req.maxTokens = 1
                let completion = try await app.client.textChat(req, apiKey: nil, timeoutSeconds: 60)
                check("bl chat ping (default profile)", true, completion.model ?? "ok")
            } catch {
                check("bl chat ping (default profile)", false, error.localizedDescription)
            }
        }

        // MARK: Pollinations (keyless)

        if include("pollinations") {
            do {
                let dest = tmp.appendingPathComponent("pollinations.jpg")
                let url = try await app.pollinations.generate(
                    prompt: "blue circle", model: nil, width: 256, height: 256, seed: 7, dest: dest)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                check("pollinations image (keyless)", size > 0, "\(size) bytes")
            } catch {
                check("pollinations image (keyless)", false, error.localizedDescription)
            }
        }

        // MARK: Stored keys

        note("reading stored keys from the Keychain; if macOS shows a")
        note("\"BlStudio wants to access\" dialog, click Allow (each new")
        note("build asks once per key)")

        let keys = app.keysStore.keys
        if keys.isEmpty { note("no stored keys found") }

        for key in keys {
            let label = "\(key.resolvedProvider.label) [\(key.label)]"
            guard include(key.resolvedProvider.rawValue) || include(key.resolvedProvider.label) else { continue }
            guard let secret = app.keysStore.secret(for: key.id, timeout: 45) else {
                check(label, false, "Keychain read failed (approve the macOS dialog and retry)")
                continue
            }
            switch key.resolvedProvider {
            case .bailian:
                do {
                    var req = ChatRequest(message: "ping")
                    req.maxTokens = 1
                    let completion = try await app.client.textChat(req, apiKey: secret, timeoutSeconds: 60)
                    check(label, true, completion.model ?? "ok")
                } catch { check(label, false, error.localizedDescription) }

            case .minimax:
                do {
                    let msg = try await app.minimax.validate(apiKey: secret)
                    check(label, true, msg)
                } catch { check(label, false, error.localizedDescription) }

                if full {
                    // Token-plan quota (free).
                    do {
                        let q = try await app.mmx.quotaShow(apiKey: secret)
                        check("minimax token-plan quota", true,
                              "\((q.model_remains ?? []).count) model rows")
                    } catch {
                        check("minimax token-plan quota", false, error.localizedDescription)
                    }
                    // One image-01 image.
                    do {
                        let images = try await app.minimax.generate(
                            apiKey: secret, prompt: "a small red apple on a white table",
                            n: 1, aspectRatio: "1:1", promptOptimizer: false)
                        check("minimax image-01", !images.isEmpty, "\(images.count) image(s)")
                    } catch {
                        check("minimax image-01", false, error.localizedDescription)
                    }
                    // One short speech clip.
                    do {
                        let dest = tmp.appendingPathComponent("speech.mp3")
                        _ = try await app.minimax.speechGenerate(
                            apiKey: secret, model: "speech-2.8-hd", text: "Smoke test.",
                            voiceId: "female-shaonv", speed: 1.0, emotion: "happy", dest: dest)
                        check("minimax speech (speech-2.8-hd)", true, "saved \(dest.lastPathComponent)")
                    } catch {
                        check("minimax speech (speech-2.8-hd)", false, error.localizedDescription)
                    }
                    // One free-tier instrumental song. MiniMax has retired the
                    // Music API for new accounts (error 2153), so treat that
                    // specific response as an expected skip, not a failure.
                    do {
                        let dest = tmp.appendingPathComponent("song.mp3")
                        _ = try await app.minimax.musicGenerate(
                            apiKey: secret, model: "music-3.0-free",
                            prompt: "short upbeat jingle", dest: dest)
                        check("minimax music (music-3.0-free)", true, "saved \(dest.lastPathComponent)")
                    } catch {
                        let msg = error.localizedDescription
                        if msg.contains("2153") || msg.contains("no longer available") {
                            note("minimax music: skipped (MiniMax retired the Music API for new accounts)")
                        } else {
                            check("minimax music (music-3.0-free)", false, msg)
                        }
                    }
                }

            case .gemini:
                do {
                    let msg = try await app.gemini.validate(apiKey: secret)
                    check(label, true, msg)
                } catch { check(label, false, error.localizedDescription) }
                if full {
                    do {
                        let dest = tmp.appendingPathComponent("gemini.png")
                        _ = try await app.gemini.generate(
                            apiKey: secret, model: "gemini-2.5-flash-image",
                            prompt: "a tiny red dot", aspectRatio: "1:1", dest: dest)
                        check("\(label) image", true, "saved \(dest.lastPathComponent)")
                    } catch { check("\(label) image", false, error.localizedDescription) }
                }

            case .huggingface:
                do {
                    let msg = try await app.huggingface.validate(apiKey: secret)
                    check(label, true, msg)
                } catch { check(label, false, error.localizedDescription) }

                // Discover which router providers actually serve image models for
                // this token (free; `/v1/models` listing).
                let providers = ["black-forest-labs", "fal-ai", "replicate", "novita",
                                 "hf-inference", "together", "nebius", "deepinfra"]
                var serving: [(String, [String])] = []
                for p in providers {
                    do {
                        let models = try await app.huggingface.listModels(apiKey: secret, provider: p)
                        let image = models.filter {
                            let m = $0.lowercased()
                            return m.contains("flux") || m.contains("stable-diffusion")
                                || m.hasPrefix("sd") || m.contains("imagen")
                        }
                        if !image.isEmpty {
                            serving.append((p, image))
                            note("hf provider \(p): \(image.prefix(6).joined(separator: ", "))\(image.count > 6 ? ", …" : "")")
                        } else {
                            note("hf provider \(p): reachable, no image models listed (\(models.count) models)")
                        }
                    } catch {
                        note("hf provider \(p): \(error.localizedDescription)")
                    }
                }

                if full {
                    // One generation, walking a curated provider/model matrix
                    // until one succeeds (failures are free; the first success
                    // costs one small image). Order: the app's default routing
                    // first, then Klein on deepinfra (which lists it), then the
                    // documented text-to-image provider/model pairs.
                    var attempts: [(String, String)] = []
                    for m in ModelCatalog.huggingFaceImageModels {
                        for p in HuggingFaceClient.providerOrder(model: m, explicit: nil) {
                            attempts.append((p, m))
                        }
                    }
                    attempts += [
                        ("deepinfra", "black-forest-labs/FLUX-2-klein-9b"),
                        ("deepinfra", "black-forest-labs/FLUX-2-klein-4b"),
                        ("fal-ai", "black-forest-labs/FLUX.1-Krea-dev"),
                        ("nscale", "black-forest-labs/FLUX.1-schnell"),
                        ("hf-inference", "stabilityai/stable-diffusion-3-medium-diffusers"),
                    ]
                    attempts += serving.flatMap { p, models in
                        models.prefix(2).map { (p, $0) }
                    }
                    var done = false
                    for (p, m) in attempts.prefix(9) where !done {
                        do {
                            let dest = tmp.appendingPathComponent("huggingface.png")
                            _ = try await app.huggingface.generate(
                                apiKey: secret, provider: p, model: m,
                                prompt: "a tiny red dot", width: 512, height: 512, dest: dest,
                                timeout: 75)
                            check("\(label) image", true, "\(p) / \(m)")
                            done = true
                        } catch {
                            note("hf image attempt \(p) / \(m): \(error.localizedDescription)")
                        }
                    }
                    if !done { check("\(label) image", false, "no provider/model combo worked") }
                }

            case .fish:
                do {
                    let msg = try await app.fish.validate(apiKey: secret)
                    check(label, true, msg)
                } catch { check(label, false, error.localizedDescription) }

            case .cloudflare:
                do {
                    let msg = try await app.cloudflare.validate(apiKey: secret,
                                                                accountId: key.accountId ?? "")
                    check(label, true, msg)
                } catch { check(label, false, error.localizedDescription) }
                if full {
                    do {
                        let dest = tmp.appendingPathComponent("cloudflare.png")
                        _ = try await app.cloudflare.generate(
                            apiKey: secret, accountId: key.accountId ?? "",
                            model: "@cf/black-forest-labs/flux-1-schnell",
                            prompt: "a tiny red dot", width: 512, height: 512,
                            seed: 7, dest: dest)
                        check("\(label) image", true, "saved \(dest.lastPathComponent)")
                    } catch { check("\(label) image", false, error.localizedDescription) }
                }

            case .pollinations:
                check(label, true, "keyless")

            case .meta:
                do {
                    let msg = try await app.metaMuse.validate(apiKey: secret)
                    check(label, true, msg)
                } catch { check(label, false, error.localizedDescription) }
                if full {
                    do {
                        let dest = tmp.appendingPathComponent("metamuse.webp")
                        _ = try await app.metaMuse.generate(
                            apiKey: secret, prompt: "a tiny red dot",
                            n: 1, size: "1024x1024", dest: dest)
                        check("\(label) image", true, "saved \(dest.lastPathComponent)")
                    } catch { check("\(label) image", false, error.localizedDescription) }
                }
            }
        }

        note("artifacts kept in \(tmp.path)")
        print(failures == 0 ? "\nAll smoke checks passed." : "\n\(failures) smoke check(s) FAILED.")
        return failures == 0 ? 0 : 1
    }
}
