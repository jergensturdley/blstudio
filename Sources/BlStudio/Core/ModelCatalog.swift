import Foundation

enum ModelCatalog {
    static let imageModels = [
        "qwen-image-3.0",
        "qwen-image-2.0-pro",
        "wan2.7-image",
        "wan2.6-t2i",
        "z-image-turbo",
        "wanx2.0-t2i-turbo",
    ]

    static let editModels = [
        "qwen-image-3.0",
        "qwen-image-2.0-pro",
        "wan2.7-image",
        "wan2.5-i2i-preview",
        "wanx2.1-imageedit",
    ]

    static let chatModels = [
        "qwen3.8-max",
        "qwen3.6-plus",
        "qwen3.6-flash",
        "qwen3.5-plus",
        "qwen3.5-flash",
        "qwen-turbo",
    ]

    static let sizes = ["1:1", "3:4", "4:3", "16:9", "9:16", "custom"]

    // MARK: MiniMax

    static let minimaxImageModels = [
        "image-01",
    ]

    /// Aspect ratios accepted by MiniMax image-01.
    static let minimaxAspectRatios = [
        "1:1", "16:9", "4:3", "3:2", "2:3", "3:4", "9:16", "21:9",
    ]

    // MARK: Video

    /// Bailian text-to-video models.
    static let videoT2VModelsBailian = [
        "happyhorse-1.1-t2v",
        "wan2.6-t2v",
    ]

    /// Bailian image-to-video models.
    static let videoI2VModelsBailian = [
        "happyhorse-1.1-i2v",
    ]

    static let videoResolutionsBailian = ["1080P", "720P"]
    static let videoRatiosBailian = ["16:9", "9:16", "1:1"]
    static let videoDurationsBailian = [5, 10]

    /// MiniMax text-to-video models (run through the mmx CLI). MiniMax-H3 is the
    /// Video Generation V2 model with 2K output; Hailuo-2.3 is the legacy T2V model.
    static let videoT2VModelsMiniMax = [
        "MiniMax-H3",
        "MiniMax-Hailuo-2.3",
    ]

    /// MiniMax image-to-video models (run through the mmx CLI). Hailuo-2.3-Fast
    /// is the fast I2V variant and requires a first frame.
    static let videoI2VModelsMiniMax = [
        "MiniMax-H3",
        "MiniMax-Hailuo-2.3",
        "MiniMax-Hailuo-2.3-Fast",
    ]

    /// MiniMax-H3 aspect ratios (Video Generation V2).
    static let h3Ratios = ["adaptive", "21:9", "16:9", "4:3", "1:1", "3:4", "9:16"]

    /// MiniMax-H3 per-clip duration in seconds.
    static let h3DurationRange = 4...15

    // MARK: Free image providers

    /// Pollinations.ai (keyless) models.
    static let pollinationsModels = [
        "flux",
        "turbo",
        "sana",
    ]

    /// Google Gemini image models (AI Studio key; image generation consumes credits).
    static let geminiImageModels = [
        "gemini-2.5-flash-image",
    ]

    /// Cloudflare Workers AI image models (free tier: 10,000 neurons/day).
    static let cloudflareImageModels = [
        "@cf/black-forest-labs/flux-1-schnell",
        "@cf/bytedance/stable-diffusion-xl-lightning",
    ]

    /// Hugging Face Inference Providers image models. BlStudio routes each
    /// model to a router provider documented as serving it (see
    /// HuggingFaceClient.providersByModel); availability and pricing depend on
    /// the provider and your HF account. The FLUX.2 Klein models are the
    /// reliably-available ones on the default (fal-ai) provider.
    static let huggingFaceImageModels = [
        "black-forest-labs/FLUX.2-klein-4B",
        "black-forest-labs/FLUX.2-klein-9B",
        "black-forest-labs/FLUX.1-dev",
    ]

    /// Meta Muse Image models served by Meta Model API ($0.01 per image).
    /// `muse-image-1.0` is the only image model advertised on the API as of
    /// writing; the entry is left here so users can paste newer ids when they
    /// ship.
    static let metaMuseImageModels = [
        MetaMuseClient.imageModel,
    ]

    /// Aspect ratios shared by the free providers.
    static let freeAspectRatios = [
        "1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3",
    ]

    /// Maps an aspect-ratio string to pixel dimensions with the given long edge.
    /// Used by providers that take width/height instead of a ratio.
    static func pixelSize(forAspectRatio ratio: String, longEdge: Int = 1024) -> (Int, Int) {
        let parts = ratio.split(separator: ":")
        guard parts.count == 2,
              let w = Double(parts[0]), let h = Double(parts[1]),
              w > 0, h > 0 else {
            return (longEdge, longEdge)
        }
        if w >= h {
            let height = Int((Double(longEdge) * h / w).rounded())
            return (longEdge, max(height, 64))
        } else {
            let width = Int((Double(longEdge) * w / h).rounded())
            return (max(width, 64), longEdge)
        }
    }

    // MARK: Music

    /// MiniMax music models. The `-free` variants are available to all API-key
    /// users at a lower rate limit; the plain models need a Token Plan or paid
    /// usage.
    static let musicModels = [
        "music-3.0",
        "music-3.0-free",
        "music-2.6",
        "music-2.6-free",
    ]

    // MARK: Speech (text-to-audio)

    /// MiniMax speech models.
    static let speechModels = [
        "speech-2.8-hd",
        "speech-02-hd",
        "speech-02-turbo",
    ]

    /// A practical set of MiniMax system voice ids.
    static let ttsVoices = [
        "female-shaonv",
        "female-yujie",
        "female-chengshu",
        "female-tianmei",
        "president_male",
        "male-qn-qingse",
        "audiobook_female_1",
        "audiobook_male_1",
        "cute_boy",
        "Charming_Lady",
    ]

    static let ttsEmotions = [
        "happy", "sad", "angry", "fearful", "disgusted", "surprised", "neutral",
    ]

    static let editFunctions = [
        "description_edit",
        "stylization_all",
        "stylization_local",
        "background_generation",
        "remove_watermark",
    ]
}
