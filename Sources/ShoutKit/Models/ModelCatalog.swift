import Foundation

public enum ModelKind: String, Codable, Sendable {
    case speech, language
    /// A language model's image reader (its mmproj file): downloaded on its own, not chosen on its own.
    case vision
}

/// Which runtime executes a model.
public enum EngineType: String, Codable, Sendable {
    case whisper          // whisper.cpp Whisper (ggml .bin)
    case parakeet         // whisper.cpp Parakeet (ggml .bin)
    case appleSpeech      // macOS 26 SpeechAnalyzer (system managed)
    case llama            // llama.cpp GGUF
    case ollama           // local Ollama / OpenAI-compatible server
    case appleIntelligence // macOS 26 Foundation Models (system managed)
}

public struct ModelInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: ModelKind
    public let engine: EngineType
    public let name: String
    public let summary: String
    public let fileName: String?
    public let url: URL?
    public let sizeBytes: Int64
    public let sha256: String?
    public let badge: String?

    public var isDownloadable: Bool { url != nil }
    /// Good enough for Prompt mode's screenshots (`ModelCatalog.screenshotPromptModelIDs`).
    public var handlesPromptScreenshots: Bool { ModelCatalog.screenshotPromptModelIDs.contains(id) }
    /// The file that lets this language model look at pictures, if it can.
    public var imageReader: ModelInfo? { ModelCatalog.imageReaderIDs[id].flatMap(ModelCatalog.model(id:)) }
    public var sizeDescription: String {
        sizeBytes > 0 ? ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) : ""
    }
}

public enum ModelCatalog {
    private static func hf(_ repo: String, _ file: String) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")!
    }

    public static let speech: [ModelInfo] = [
        ModelInfo(id: "parakeet-v3-q8", kind: .speech, engine: .parakeet,
                  name: "Parakeet TDT 0.6B v3",
                  summary: "Fastest and most accurate for English and 24 European languages. Punctuates on its own and detects the language automatically.",
                  fileName: "ggml-parakeet-tdt-0.6b-v3-q8_0.bin",
                  url: hf("ggml-org/parakeet-GGUF", "ggml-parakeet-tdt-0.6b-v3-q8_0.bin"),
                  sizeBytes: 668_757_119,
                  sha256: "4d64e9e96c2792186d072fde0034df0ad670cf680a2f53069052ead827fd600e",
                  badge: "Recommended"),
        ModelInfo(id: "whisper-large-v3-turbo-q5", kind: .speech, engine: .whisper,
                  name: "Whisper Large v3 Turbo",
                  summary: "99 languages. Uses your dictionary as spelling hints while it listens.",
                  fileName: "ggml-large-v3-turbo-q5_0.bin",
                  url: hf("ggerganov/whisper.cpp", "ggml-large-v3-turbo-q5_0.bin"),
                  sizeBytes: 574_041_195,
                  sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
                  badge: "Multilingual"),
        ModelInfo(id: "whisper-large-v3-turbo-q8", kind: .speech, engine: .whisper,
                  name: "Whisper Large v3 Turbo (8-bit)",
                  summary: "Slightly higher accuracy than the default Turbo build, at a larger size.",
                  fileName: "ggml-large-v3-turbo-q8_0.bin",
                  url: hf("ggerganov/whisper.cpp", "ggml-large-v3-turbo-q8_0.bin"),
                  sizeBytes: 874_188_075,
                  sha256: "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1",
                  badge: nil),
        ModelInfo(id: "whisper-small-q5", kind: .speech, engine: .whisper,
                  name: "Whisper Small",
                  summary: "Lightweight multilingual model for older Macs.",
                  fileName: "ggml-small-q5_1.bin",
                  url: hf("ggerganov/whisper.cpp", "ggml-small-q5_1.bin"),
                  sizeBytes: 190_085_487,
                  sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb",
                  badge: nil),
        ModelInfo(id: "whisper-base-en-q5", kind: .speech, engine: .whisper,
                  name: "Whisper Base (English)",
                  summary: "Tiny English-only model. Lowest memory use, lowest accuracy.",
                  fileName: "ggml-base.en-q5_1.bin",
                  url: hf("ggerganov/whisper.cpp", "ggml-base.en-q5_1.bin"),
                  sizeBytes: 59_721_011,
                  sha256: "4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f",
                  badge: nil),
        ModelInfo(id: "apple-speech", kind: .speech, engine: .appleSpeech,
                  name: "Apple Speech",
                  summary: "macOS 26 on-device recognizer. No download; macOS manages the language packs.",
                  fileName: nil, url: nil, sizeBytes: 0, sha256: nil, badge: "Built in"),
    ]

    public static let language: [ModelInfo] = [
        ModelInfo(id: "qwen3-4b-instruct-q4", kind: .language, engine: .llama,
                  name: "Qwen3 4B Instruct",
                  summary: "Best balance of speed and editing quality for cleanup, styles and Command Mode.",
                  fileName: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
                  url: hf("unsloth/Qwen3-4B-Instruct-2507-GGUF", "Qwen3-4B-Instruct-2507-Q4_K_M.gguf"),
                  sizeBytes: 2_497_281_120,
                  sha256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597",
                  badge: "Recommended"),
        ModelInfo(id: "qwen3.5-2b-q4", kind: .language, engine: .llama,
                  name: "Qwen3.5 2B",
                  summary: "Smallest and fastest. Good for light cleanup on 8 GB Macs.",
                  fileName: "Qwen3.5-2B-Q4_K_M.gguf",
                  url: hf("unsloth/Qwen3.5-2B-GGUF", "Qwen3.5-2B-Q4_K_M.gguf"),
                  sizeBytes: 1_280_835_840,
                  sha256: "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223",
                  badge: "Fast"),
        ModelInfo(id: "qwen3.5-4b-q4", kind: .language, engine: .llama,
                  name: "Qwen3.5 4B",
                  summary: "Newer 4B model with stronger multilingual editing. Can look at Prompt mode's screenshots.",
                  fileName: "Qwen3.5-4B-Q4_K_M.gguf",
                  url: hf("unsloth/Qwen3.5-4B-GGUF", "Qwen3.5-4B-Q4_K_M.gguf"),
                  sizeBytes: 2_740_937_888,
                  sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",
                  badge: nil),
        ModelInfo(id: "qwen3.5-9b-q4", kind: .language, engine: .llama,
                  name: "Qwen3.5 9B",
                  summary: "Highest quality rewrites for Command Mode, and can look at Prompt mode's screenshots. Slower; needs 16 GB of memory or more.",
                  fileName: "Qwen3.5-9B-Q4_K_M.gguf",
                  url: hf("unsloth/Qwen3.5-9B-GGUF", "Qwen3.5-9B-Q4_K_M.gguf"),
                  sizeBytes: 5_680_522_464,
                  sha256: "03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8",
                  badge: "Quality"),
        ModelInfo(id: "ollama", kind: .language, engine: .ollama,
                  name: "Ollama (local server)",
                  summary: "Use any model you already run in Ollama or another OpenAI-compatible server on this Mac.",
                  fileName: nil, url: nil, sizeBytes: 0, sha256: nil, badge: "External"),
        ModelInfo(id: "apple-intelligence", kind: .language, engine: .appleIntelligence,
                  name: "Apple Intelligence",
                  summary: "macOS 26 on-device model. Requires Apple Intelligence to be turned on.",
                  fileName: nil, url: nil, sizeBytes: 0, sha256: nil, badge: "Built in"),
    ]

    /// Image readers for the language models that can look at pictures (`ModelInfo.imageReader`). Prompt mode shows
    /// them the screenshots, so "this icon" can become "the gear icon at the top right".
    public static let vision: [ModelInfo] = [
        ModelInfo(id: "qwen3.5-4b-vision", kind: .vision, engine: .llama,
                  name: "Qwen3.5 4B image reader",
                  summary: "Lets Qwen3.5 4B look at Prompt mode's screenshots.",
                  fileName: "Qwen3.5-4B-mmproj-F16.gguf",
                  url: hf("unsloth/Qwen3.5-4B-GGUF", "mmproj-F16.gguf"),
                  sizeBytes: 672_423_616,
                  sha256: "cd88edcf8d031894960bb0c9c5b9b7e1fea6ebee02b9f7ce925a00d12891f864",
                  badge: nil),
        ModelInfo(id: "qwen3.5-9b-vision", kind: .vision, engine: .llama,
                  name: "Qwen3.5 9B image reader",
                  summary: "Lets Qwen3.5 9B look at Prompt mode's screenshots.",
                  fileName: "Qwen3.5-9B-mmproj-F16.gguf",
                  url: hf("unsloth/Qwen3.5-9B-GGUF", "mmproj-F16.gguf"),
                  sizeBytes: 918_166_080,
                  sha256: "f70dc3509053962b0d0d3ee8a7eacebf5d60aa560cad78254ae8698516ae029f",
                  badge: nil),
    ]
    static let imageReaderIDs = ["qwen3.5-4b-q4": "qwen3.5-4b-vision", "qwen3.5-9b-q4": "qwen3.5-9b-vision"]

    public static var all: [ModelInfo] { speech + language + vision }
    public static func model(id: String) -> ModelInfo? { all.first { $0.id == id } }
    public static let defaultSpeechModelID = "parakeet-v3-q8"
    public static let defaultLanguageModelID = "qwen3-4b-instruct-q4"

    /// Language models that write Prompt mode's screenshot prompts well: they name what each screenshot points at and
    /// keep the user's words (measured with `shout-cli prompt --shots`). Smaller models (Qwen3.5 2B), Apple
    /// Intelligence and Ollama models aren't verified, so screenshots are off with them.
    public static let screenshotPromptModelIDs: Set<String> = ["qwen3-4b-instruct-q4", "qwen3.5-4b-q4", "qwen3.5-9b-q4"]
}
