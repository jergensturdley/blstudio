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

    static let editFunctions = [
        "description_edit",
        "stylization_all",
        "stylization_local",
        "background_generation",
        "remove_watermark",
    ]
}
