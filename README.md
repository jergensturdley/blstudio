# BlStudio

[![CI](https://github.com/jergensturdley/blstudio/actions/workflows/ci.yml/badge.svg)](https://github.com/jergensturdley/blstudio/actions/workflows/ci.yml)
[![Release](https://github.com/jergensturdley/blstudio/actions/workflows/release.yml/badge.svg)](https://github.com/jergensturdley/blstudio/releases)

BlStudio is a native macOS app for working with the **`bl` CLI** ([bailian-cli](https://www.npmjs.com/package/bailian-cli)). It drives Alibaba Cloud Bailian / DashScope from the command line. BlStudio wraps that CLI in a friendly GUI focused on:

- **Image generation**. Prompt editor with style presets, model/size/count/seed/negative-prompt controls, live progress, and a results gallery. Multiple images (1–6) run as parallel single-image requests, so counts work even on models like `qwen-image-3.0` whose API ignores the batch parameter; a fixed seed is offset per image (seed, seed+1, …) so batches stay distinct and reproducible. A dice button fills in a random seed, and the watermark is off by default.
- **Multiple providers**. Images through Alibaba Bailian (via the `bl` CLI), MiniMax, Pollinations (free, no API key), Google Gemini (AI Studio key), Cloudflare Workers AI (free tier), or Hugging Face (Inference Providers); video through Bailian and MiniMax (Hailuo 2.3 and MiniMax-H3, via the `mmx` CLI); music and speech through MiniMax, plus speech through Fish Audio. Switch provider per job, and turn providers on or off in Settings. MiniMax returns up to 9 images in a single request with fixed aspect ratios.
- **Free options**. Pollinations needs no API key at all. Cloudflare Workers AI runs FLUX.1-schnell on a free tier of 10,000 neurons per day (it needs a Cloudflare account id and an API token). Google Gemini's `gemini-2.5-flash-image` ("Nano Banana") is available via an AI Studio key, but it is billed per image and isn't reliably covered by the free tier. Hugging Face routes images through an inference provider, so free availability depends on the provider and model.
- **Image editing**. Drop source images, describe the edit, get results back.
- **Video generation**. Text-to-video and image-to-video through Bailian (`bl video generate`) or MiniMax Hailuo, with resolution, aspect ratio, duration, and seed controls, live progress, an inline player, and results saved to your library folder.
- **Music generation**. Compose full songs (with optional lyrics) using MiniMax `music-2.0` / `music-1.5`, then play them inline.
- **Speech / text-to-audio**. Turn text into speech through MiniMax (`speech-2.8-hd` with voice, speed, and emotion controls) or Fish Audio (streams the audio back directly, with an optional reference voice). Generated audio plays inline with a scrubber.
- **Easy prompting**. Saved favorite prompts and saved negative prompts, one-click style suffixes, an Enhance-with-AI button that rewrites your prompt with a Qwen text model, and quick chat for iterating further.
- **Image receiving**. Generated images are downloaded to your library folder, shown inline, and can be opened, copied, revealed in Finder, or sent straight into the Edit tab.
- **In-app image viewer**. Click any image to open it full-size inside BlStudio, no Preview needed. Pinch or use the zoom buttons to magnify (up to 8×), drag to pan, double-click to toggle fit/2×, and flip through batches with the arrows. Open, Reveal, Copy, Describe, and send-to-Edit are all in the viewer bar.
- **Quota tracking per API key**. Every request is logged locally per key (images, edits, chats, tokens, failures, daily chart). Account-level free-tier quotas and RPM/TPM rate limits are pulled from `bl usage free` / `bl quota check` when your console session is logged in.

## Requirements

- macOS 14+
- Swift 6 toolchain (Xcode 16+ or Command Line Tools)
- `bl` installed and authenticated (`bl auth login`), e.g. `npm i -g bailian-cli`. Required for the Bailian provider and for Chat/Edit/Quota; MiniMax images work without it.
- `mmx` (mmx-cli) for MiniMax video (incl. MiniMax-H3) and MiniMax quota lookups: `npm i -g mmx-cli` (or `npm update -g mmx-cli`). MiniMax-H3 needs mmx 1.0.19 or newer.

## Build & run

```sh
make run          # release-build, bundle dist/BlStudio.app, and launch it
make dev          # swift run (debug, no bundle)
make selftest     # headless smoke tests incl. live bl dry-run checks
make test         # XCTest suite (needs full Xcode; falls back to selftest)
```

You can also open `Package.swift` in Xcode and hit Run.

> Sandboxed shells: SwiftPM's build sandbox may be unavailable; use
> `make run SWIFT_FLAGS=--disable-sandbox` (already handled for CI-like environments).

## Install a prebuilt release

Grab the latest `BlStudio-<tag>-macos-universal.zip` from [GitHub Releases](https://github.com/jergensturdley/blstudio/releases), unzip, and drag **BlStudio.app** to `/Applications`. Builds are **universal** (Apple Silicon + Intel) and **ad-hoc signed**. There is no paid Apple Developer ID, so on first launch macOS Gatekeeper blocks a plain double-click. Either:

- right-click → **Open**, or
- `xattr -dr com.apple.quarantine /Applications/BlStudio.app`

You still need the `bl` CLI installed and authenticated (see Requirements).

## Releases & CI

- **CI** (`.github/workflows/ci.yml`) runs on every push/PR to `main`: release build, the XCTest suite (live `bl` integration tests auto-skip where the CLI is absent), the headless `--selftest`, and an offscreen `--viewprobe` render of every pane.
- **Release** (`.github/workflows/release.yml`) runs when you push a tag matching `v*`. It builds a universal binary, bundles `BlStudio.app`, ad-hoc signs it with the hardened runtime, zips it, and publishes a GitHub Release with install notes.

Cut a release with:

```sh
git tag v1.2.0
git push origin v1.2.0     # triggers the Release workflow
```

The version embedded in `Info.plist` is derived from the tag (`v1.2.0` → `1.2.0`).

## Using the app

| Tab | What it does |
| --- | --- |
| **Generate** | Text-to-image via Bailian CLI, MiniMax, Pollinations (free, no key), Google Gemini (AI Studio key, uses credits), Cloudflare Workers AI (free tier), or Hugging Face. Pick a provider, then a model, aspect ratio or pixel size, and image count. Bailian supports 1–6 images with seed/negative/prompt-extend/watermark controls (watermark off by default). MiniMax returns 1–9 per request with fixed aspect ratios. Pollinations, Gemini, Cloudflare, and Hugging Face fan out up to 4. Style chips append suffixes; a dice button sets a random seed; Enhance with AI rewrites your prompt. |
| **Edit** | Image-to-image via `bl image edit`. Drag & drop or pick source images (local files or URLs), describe the change, optionally choose an edit function for `wanx*-imageedit` models. |
| **Video** | Text-to-video and image-to-video. Bailian runs `bl video generate` (happyhorse / wan2.6 models) with resolution, aspect ratio, duration, seed, and watermark controls. MiniMax runs through the `mmx` CLI: MiniMax-H3 (Video Generation V2, 2K output, 4–15 s clips, aspect-ratio control) or Hailuo-2.3; image-to-video takes a local first frame or an image URL. Results play inline and are saved to your library folder. |
| **Music** | Generate full songs with MiniMax `music-3.0` / `music-2.6` (or their `-free` variants). Describe the style, add optional lyrics with [verse]/[chorus] section tags, then play the result inline. Requires a MiniMax key. |
| **Speech** | Text-to-audio. MiniMax `speech-2.8-hd` with voice, speed, and emotion controls, or Fish Audio (streams audio back, optional reference voice id). Plays inline with a scrubber. |
| **Chat** | `bl text chat` with a transcript, system prompt, and per-reply token usage. Handy for prompt brainstorming. |
| **Gallery** | History of every generation, edit, and video with search & filters. Click an image to open the full-size in-app viewer (zoom, pan, batch arrows, Describe, send-to-Edit). Videos play inline. |
| **Quota** | Per-key local usage cards (images, edits, chats, tokens, 14-day chart) + account free-tier quota and rate-limit tables refreshed from the console + MiniMax token-plan quota per model via `mmx quota show`. |
| **API Keys** | Store multiple API keys in the macOS Keychain, each tagged as Bailian, MiniMax, Google Gemini, Fish Audio, Cloudflare Workers AI, or Hugging Face, select the active one, and test them. Cloudflare keys also take an Account ID; Hugging Face keys take an inference provider name. Without a selected key, BlStudio uses the active `bl` profile. |
| **Settings** | bl and mmx binary path overrides, image library folder, default size/models, timeouts, and on/off switches for each provider. Turning a provider off hides it from the Generate, Video, and Speech pickers. |

The key selected in the toolbar is passed to `bl` as `--api-key` for image/chat/vision calls.

### Quota tracking, precisely

Two layers, because Bailian quota lives in two places:

1. **Local ledger (per key)**. BlStudio records every call it makes (`~/Library/Application Support/BlStudio/usage.jsonl`): kind, model, timestamp, image count, prompt/completion tokens, duration, success. Aggregations are shown per API key in the Quota tab. This works even when the console session is expired.
2. **Account quota (console session)**. `bl usage free` and `bl quota check` report free-tier balances and RPM/TPM headroom. These use the console credentials of the active `bl` profile (not the per-call API key). If you see *"Console session is not logged in or has expired"*, run `bl auth login --console` in a terminal.

## How it works

For Bailian, BlStudio shells out to the `bl` binary (`~/.local/bin/bl`, `/opt/homebrew/bin/bl`, `/usr/local/bin/bl`, or `$PATH`, override in Settings) with `--output json` and parses the CLI's JSON contracts:

- `image generate/edit` → `{urls, saved, total, task_id(s)}`
- `video generate` → polls and saves the finished `.mp4` itself (`--download`)
- `text chat` → OpenAI-compatible completion envelope with `usage`
- `usage free`, `quota check`, `quota list`, `auth status`, `config list`
- errors arrive as `{"error": {code, message, hint}}` and surface with the hint text

Live progress lines from `bl`'s stderr are shown while a job runs; long-running async tasks are polled by the CLI itself (`--poll-interval`).

MiniMax video is driven the same way through the `mmx` CLI (`mmx video generate --output json --download <path>`): BlStudio passes the stored MiniMax key with `--api-key`, streams mmx's status lines as progress, and picks up the saved video. This is what unlocks MiniMax-H3 (Video Generation V2, 2K, 4–15 s clips) alongside Hailuo-2.3. `mmx quota show --output json` feeds the MiniMax token-plan card in the Quota tab.

The remaining providers are called directly over HTTP:

- MiniMax `image_generation` (images), `music_generation` (songs), and `t2a_v2` (speech). Audio is requested with `output_format: "url"` and downloaded.
- Pollinations `image.pollinations.ai/prompt/...` (free, keyless images).
- Google Gemini `generateContent` (AI Studio key, base64 inline part; image generation consumes credits).
- Cloudflare Workers AI `accounts/{account}/ai/run/{model}` (FLUX image returned as base64; validated via the models endpoint).
- Hugging Face Inference Providers `router.huggingface.co/{provider}/v1/images/generations` (OpenAI-compatible; result is a URL or base64; the key is validated via `whoami-v2`).
- Fish Audio `v1/tts` (speech returned as a binary stream).

## Project layout

```
Sources/BlStudio/
  Core/      BLClient (process runner + JSON), command wrappers, models,
             stores (settings, keychain keys, usage ledger, history, prompts)
  App/       entry point, AppState container
  Views/     Generate, Edit, Chat, Gallery, Quota, Keys, Settings
Tests/       XCTest parser/integration tests
Tools/       icon generator, Info.plist template
```

## Notes & limitations

- Secrets live in the Keychain (`BlStudio` service); only masked prefixes are shown in the UI.
- The app is unsigned/local-only by design; no App Sandbox (it needs to spawn the `bl`/`node` process and write to your Pictures folder).
- `usage free` / `quota check` reflect the active `bl` profile's console session, not arbitrary API keys. Per-key numbers come from the local ledger.
- MiniMax `image-01` has no seed, negative-prompt, or watermark settings, so those controls are disabled when MiniMax is selected. MiniMax images are delivered as JPEG (1024px at the default resolution) and are logged to the same per-key usage ledger.
- App Transport Security allows arbitrary loads because some image CDNs serve results over plain HTTP.
- MiniMax video requires the `mmx` CLI (`npm i -g mmx-cli`). MiniMax-H3 renders 2K output with 4–15 s clips and aspect-ratio control (it needs mmx 1.0.19 or newer); Hailuo-2.3 uses model defaults. Renders take a few minutes and mmx polls automatically. MiniMax image-to-video takes a local first frame (mmx base64-encodes it) or an image URL, while Bailian image-to-video needs a publicly reachable image URL.
- Pollinations is free and keyless but is a shared public service, so it can be slow or rate-limited at times. Gemini image generation is billed per image and isn't reliably covered by the Gemini free tier, so regular use needs credits/billing enabled.
- MiniMax music generation (`music-3.0` / `music-2.6`, or the `-free` variants) composes a full song synchronously and usually takes about a minute. Leave lyrics empty for an instrumental. The plain models need a Token Plan or paid usage; the `-free` variants are available to all API-key users at a lower rate limit. MiniMax speech uses `speech-2.8-hd` with a system voice id. Both are billed by MiniMax like other MiniMax calls.
- Fish Audio streams speech back directly and is credit-based; the Test button runs a tiny TTS request to confirm a key. Leave the reference id empty to use your account's default voice.
- Cloudflare Workers AI uses your account's free neuron allowance (10,000 neurons per day). It needs both a Cloudflare account id and an API token; the Test button lists models without consuming any neurons. FLUX accepts a seed; negative prompt and watermark are not available.
- Hugging Face routes each image request through an inference provider (default `fal-ai`, changeable per key). Whether a model is free or paid depends on that provider and model, so check your provider's pricing. The Test button calls `whoami-v2` and consumes nothing.
- Other `bl` capabilities aren't wrapped yet. The Chat tab plus a terminal cover the rest.
