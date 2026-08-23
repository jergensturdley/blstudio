# BlStudio

[![CI](https://github.com/jergensturdley/blstudio/actions/workflows/ci.yml/badge.svg)](https://github.com/jergensturdley/blstudio/actions/workflows/ci.yml)
[![Release](https://github.com/jergensturdley/blstudio/actions/workflows/release.yml/badge.svg)](https://github.com/jergensturdley/blstudio/releases)

BlStudio is a native macOS app for working with the **`bl` CLI** ([bailian-cli](https://www.npmjs.com/package/bailian-cli)). It drives Alibaba Cloud Bailian / DashScope from the command line. BlStudio wraps that CLI in a friendly GUI focused on:

- **Image generation**. Prompt editor with style presets, model/size/count/seed/negative-prompt controls, live progress, and a results gallery. Multiple images (1–6) run as parallel single-image requests, so counts work even on models like `qwen-image-3.0` whose API ignores the batch parameter; a fixed seed is offset per image (seed, seed+1, …) so batches stay distinct and reproducible. A dice button fills in a random seed, and the watermark is off by default.
- **Two providers**. Generate through Alibaba Bailian (via the `bl` CLI) or MiniMax (called over HTTP, so no `bl` needed), for both images and video. Switch provider per job. MiniMax returns up to 9 images in a single request with fixed aspect ratios, and renders video with its Hailuo models.
- **Image editing**. Drop source images, describe the edit, get results back.
- **Video generation**. Text-to-video and image-to-video through Bailian (`bl video generate`) or MiniMax Hailuo, with resolution, aspect ratio, duration, and seed controls, live progress, an inline player, and results saved to your library folder.
- **Easy prompting**. Saved favorite prompts and saved negative prompts, one-click style suffixes, an Enhance-with-AI button that rewrites your prompt with a Qwen text model, and quick chat for iterating further.
- **Image receiving**. Generated images are downloaded to your library folder, shown inline, and can be opened, copied, revealed in Finder, or sent straight into the Edit tab.
- **In-app image viewer**. Click any image to open it full-size inside BlStudio, no Preview needed. Pinch or use the zoom buttons to magnify (up to 8×), drag to pan, double-click to toggle fit/2×, and flip through batches with the arrows. Open, Reveal, Copy, Describe, and send-to-Edit are all in the viewer bar.
- **Quota tracking per API key**. Every request is logged locally per key (images, edits, chats, tokens, failures, daily chart). Account-level free-tier quotas and RPM/TPM rate limits are pulled from `bl usage free` / `bl quota check` when your console session is logged in.

## Requirements

- macOS 14+
- Swift 6 toolchain (Xcode 16+ or Command Line Tools)
- `bl` installed and authenticated (`bl auth login`), e.g. `npm i -g bailian-cli`. Required for the Bailian provider and for Chat/Edit/Quota; the MiniMax provider (image and video) works without `bl`.

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
| **Generate** | Text-to-image via the Bailian CLI or the MiniMax API. Pick a provider, then a model, aspect ratio or pixel size, and image count. Bailian supports 1–6 images with optional seed/negative prompt and prompt-extend & watermark toggles (watermark defaults to off). MiniMax returns 1–9 images per request with fixed aspect ratios. Style chips append curated suffixes to your prompt; a dice button sets a random seed, and Enhance with AI rewrites your prompt. |
| **Edit** | Image-to-image via `bl image edit`. Drag & drop or pick source images (local files or URLs), describe the change, optionally choose an edit function for `wanx*-imageedit` models. |
| **Video** | Text-to-video and image-to-video. Bailian runs `bl video generate` (happyhorse / wan2.6 models) with resolution, aspect ratio, duration, seed, and watermark controls. MiniMax runs Hailuo over HTTP with duration and resolution; image-to-video uses a local first frame or an image URL. Results play inline and are saved to your library folder. |
| **Chat** | `bl text chat` with a transcript, system prompt, and per-reply token usage. Handy for prompt brainstorming. |
| **Gallery** | History of every generation, edit, and video with search & filters. Click an image to open the full-size in-app viewer (zoom, pan, batch arrows, Describe, send-to-Edit). Videos play inline. |
| **Quota** | Per-key local usage cards (images, edits, chats, tokens, 14-day chart) + account free-tier quota and rate-limit tables refreshed from the console. |
| **API Keys** | Store multiple API keys in the macOS Keychain, each tagged as Bailian or MiniMax, select the active one, and test them. Without a selected key, BlStudio uses the active `bl` profile. |
| **Settings** | bl binary path override, image library folder, default size/models, timeouts. |

The key selected in the toolbar is passed to `bl` as `--api-key` for image/chat/vision calls.

### Quota tracking, precisely

Two layers, because Bailian quota lives in two places:

1. **Local ledger (per key)**. BlStudio records every call it makes (`~/Library/Application Support/BlStudio/usage.jsonl`): kind, model, timestamp, image count, prompt/completion tokens, duration, success. Aggregations are shown per API key in the Quota tab. This works even when the console session is expired.
2. **Account quota (console session)**. `bl usage free` and `bl quota check` report free-tier balances and RPM/TPM headroom. These use the console credentials of the active `bl` profile (not the per-call API key). If you see *"Console session is not logged in or has expired"*, run `bl auth login --console` in a terminal.

## How it works

BlStudio never talks to the network itself for generation. It shells out to the `bl` binary (`~/.local/bin/bl`, `/opt/homebrew/bin/bl`, `/usr/local/bin/bl`, or `$PATH`, override in Settings) with `--output json` and parses the CLI's JSON contracts:

- `image generate/edit` → `{urls, saved, total, task_id(s)}`
- `video generate` → polls and saves the finished `.mp4` itself (`--download`)
- `text chat` → OpenAI-compatible completion envelope with `usage`
- `usage free`, `quota check`, `quota list`, `auth status`, `config list`
- errors arrive as `{"error": {code, message, hint}}` and surface with the hint text

Live progress lines from `bl`'s stderr are shown while a job runs; long-running async tasks are polled by the CLI itself (`--poll-interval`).

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
- MiniMax Hailuo video accepts duration and resolution only on Hailuo models; renders take a few minutes and are polled automatically. MiniMax image-to-video takes a local first frame (sent as a data URI), while Bailian image-to-video needs a publicly reachable image URL.
- Speech and other `bl` capabilities aren't wrapped yet. The Chat tab plus a terminal cover the rest.
