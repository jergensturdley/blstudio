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

    /// MiniMax text-to-video models (Hailuo).
    static let videoT2VModelsMiniMax = [
        "MiniMax-Hailuo-2.3",
        "T2V-01",
    ]

    /// MiniMax image-to-video models.
    static let videoI2VModelsMiniMax = [
        "I2V-01",
    ]

    /// MiniMax Hailuo accepts duration 6 or 10 and resolution 768P/1080P.
    static let videoDurationsMiniMax = [6, 10]
    static let videoResolutionsMiniMax = ["768P", "1080P"]

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

    /// MiniMax music models.
    static let musicModels = [
        "music-2.0",
        "music-1.5",
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
