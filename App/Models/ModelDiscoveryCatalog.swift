import Foundation

// Discovery metadata and presentation only. All listed artifacts install through
// ModelLibrary and resolve to the task-specific bundled native runtime.
// ModelTask is shared with installation and task-specific selection.

struct ModelDiscoveryEntry: Identifiable, Sendable {
    let id: String
    let task: ModelDiscoveryTask
    let name: String
    let summaryKey: String
    let sourceURL: URL
    let filesURL: URL
    let setupURL: URL?
    let formatLabel: String
    let licenseLabel: String
    let licenseURL: URL
    // A single artifact's weight bytes, or nil for a multi-file/gated bundle.
    // This is not installation size or peak memory use.
    let downloadBytes: Int64?
    let languageIDs: [String]
    let languageListComplete: Bool
    let managedModelIDs: [String]
    let compatibilityKey: String
    let accessNoteKey: String?
    // Practical limits and extra coverage shown under Details; summaries say
    // only what a model is for, and languages come from `languageIDs`.
    var detailNoteKeys: [String] = []
}

// Relative 1–5 ratings within one task, scored from each model's published
// evaluations. Ratings rank and describe catalog artifacts only; they never
// install or select a model.
struct ModelRating: Equatable, Sendable {
    let speed: Int
    let accuracy: Int
    // Shown on a 3.0–5.0 scale: each band adds 0.5, keeping the cited bands'
    // order and spacing while every listed model reads as a usable choice.
    // Ranking and recommendations use the 1–5 bands, never these values.
    static let displayScores: [Double] = [3.0, 3.5, 4.0, 4.5, 5.0]
    static func displayScore(_ band: Int) -> Double { displayScores[min(5, max(1, band)) - 1] }
    var displaySpeed: Double { Self.displayScore(speed) }
    var displayAccuracy: Double { Self.displayScore(accuracy) }
}

enum ModelDiscoveryCatalog {
    static let reviewedOn = "2026-10-24"
    static let ratings: [String: ModelRating] = [
        "whisper-base-q5": .init(speed: 5, accuracy: 1), "whisper-small-q5": .init(speed: 4, accuracy: 2),
        "whisper-turbo-q5": .init(speed: 2, accuracy: 4), "whisper-turbo-q8": .init(speed: 2, accuracy: 4),
        "whisper-large-v3-q5": .init(speed: 1, accuracy: 4),
        "qwen3-asr-06b-q4": .init(speed: 4, accuracy: 4), "nemotron-35-q4": .init(speed: 4, accuracy: 2),
        "parakeet-v3-q4": .init(speed: 5, accuracy: 4), "sensevoice-small-q8": .init(speed: 5, accuracy: 3),
        "cohere-transcribe-q4": .init(speed: 3, accuracy: 5), "qwen3-asr-17b-q8": .init(speed: 3, accuracy: 5),
        "parakeet-ultra-q4": .init(speed: 5, accuracy: 5),
        "hy-mt2-18b-q4": .init(speed: 5, accuracy: 4),
        "qwen3-4b-instruct-q4": .init(speed: 4, accuracy: 3),
        "translategemma-4b-q4": .init(speed: 4, accuracy: 4),
        "kokoro-82m-q8": .init(speed: 5, accuracy: 3), "qwen3-tts-customvoice-q8": .init(speed: 1, accuracy: 5),
        "cosyvoice3-q8": .init(speed: 2, accuracy: 4)
    ]
    // A maintainer pick is recommended only where hardware, runtime and the
    // requested languages fit; otherwise the best balanced rating wins.
    static let preferredModelIDs: [ModelTask: String] = [.dictation: "qwen3-asr-06b-q4"]
    static func rating(for modelID: String) -> ModelRating? { ratings[modelID] }
    static let entries: [ModelDiscoveryEntry] = {
        func url(_ value: String) -> URL { URL(string: value)! }
        func managed(
            _ id: String, _ name: String, _ summary: String, _ original: String, _ license: String,
            _ ids: [String], _ languages: [String], files: String? = nil,
            setup: String = "https://github.com/ggml-org/whisper.cpp", format: String = "Whisper GGML",
            complete: Bool = true, note: String? = nil, task: ModelTask = .dictation, licenseURL: String? = nil,
            details: [String] = []
        ) -> ModelDiscoveryEntry {
            .init(
                id: id, task: task, name: name, summaryKey: summary, sourceURL: url(original),
                filesURL: url(
                    files ?? "https://huggingface.co/ggerganov/whisper.cpp/tree/" + ModelLibrary.repositoryRevision),
                setupURL: url(setup), formatLabel: format, licenseLabel: license,
                licenseURL: url(licenseURL ?? original),
                downloadBytes: ids.count == 1 ? ModelLibrary.catalog.first { $0.id == ids[0] }?.sizeBytes : nil,
                languageIDs: languages, languageListComplete: complete, managedModelIDs: ids,
                compatibilityKey: "Available in Yullo", accessNoteKey: note, detailNoteKeys: details)
        }
        let whisper =
            "en zh de es ru ko fr ja pt tr pl ca nl ar sv it id hi fi vi he uk el ms cs ro da hu ta nb th ur hr bg lt la mi ml cy sk te fa lv bn sr az sl kn et mk br eu is hy ne mn bs kk sq sw gl mr pa si km sn yo so af oc ka be tg sd gu am yi lo uz fo ht ps tk nn mt sa lb my bo fil mg as tt haw ln ha ba jw su"
            .split(separator: " ").map(String.init)
        let qwenASR = "zh en yue ar de fr es pt id it ko ru th vi ja tr hi ms nl sv da fi pl cs fil fa el hu mk ro"
            .split(separator: " ").map(String.init)
        let parakeet = "bg hr cs da nl en et fi fr de el hu it lv lt mt pl pt ro sk sl es sv ru uk".split(
            separator: " "
        ).map(String.init)
        let qwenText =
            "af sq ar hy az eu bn bs bg yue ca zh zh-Hant hr cs da nl en et fil fi fr gl ka de el gu he hi hu is id ga it ja kk ko lv lt mk ms mt mr ne nb fa pl pt pa ro ru sr si sk sl es sw sv ta te th tr uk ur uz vi cy"
            .split(separator: " ").map(String.init)
        let hyMT =
            "zh zh-Hant en fr pt es ja tr ru ar ko th it de vi ms id fil hi pl cs nl km my fa gu ur te mr he bn ta uk bo kk mn ug yue"
            .split(separator: " ").map(String.init)
        return [
            managed(
                "whisper-turbo", "Whisper Large v3 Turbo", "A practical starting point for multilingual dictation.",
                "https://huggingface.co/openai/whisper-large-v3-turbo", "MIT", ["whisper-turbo-q5", "whisper-turbo-q8"],
                whisper + ["yue"], licenseURL: "https://github.com/openai/whisper/blob/main/LICENSE"),
            managed(
                "whisper-base", "Whisper Base", "A small download for lightweight dictation.",
                "https://huggingface.co/openai/whisper-base", "MIT", ["whisper-base-q5"], whisper,
                licenseURL: "https://github.com/openai/whisper/blob/main/LICENSE"),
            managed(
                "whisper-small", "Whisper Small", "A compact alternative to the larger Whisper models.",
                "https://huggingface.co/openai/whisper-small", "MIT", ["whisper-small-q5"], whisper,
                licenseURL: "https://github.com/openai/whisper/blob/main/LICENSE"),
            managed(
                "whisper-large-v3", "Whisper Large v3",
                "The full v3 model. Compare its quality and speed with Turbo.",
                "https://huggingface.co/openai/whisper-large-v3", "MIT", ["whisper-large-v3-q5"], whisper + ["yue"],
                licenseURL: "https://github.com/openai/whisper/blob/main/LICENSE"),
            managed(
                "qwen3-asr", "Qwen3 ASR 0.6B", "Fast, accurate recognition for everyday dictation.",
                "https://huggingface.co/Qwen/Qwen3-ASR-0.6B", "Apache-2.0", ["qwen3-asr-06b-q4"], qwenASR,
                files:
                    "https://huggingface.co/handy-computer/Qwen3-ASR-0.6B-gguf/tree/7e7c69a577fa2725dfedbe34b5e999336e30a19b",
                setup: "https://github.com/handy-computer/transcribe.cpp/blob/v0.4.1/docs/models/qwen3-asr-0.6b.md",
                format: "GGUF · Q4_K_M", note: "Converted for transcribe.cpp by its maintainers.",
                details: ["Also recognizes 22 Chinese dialects."]),
            managed(
                "qwen3-asr-17b", "Qwen3 ASR 1.7B",
                "More accurate multilingual recognition. Slower than Qwen3 ASR 0.6B.",
                "https://huggingface.co/Qwen/Qwen3-ASR-1.7B", "Apache-2.0", ["qwen3-asr-17b-q8"], qwenASR,
                files:
                    "https://huggingface.co/handy-computer/Qwen3-ASR-1.7B-gguf/tree/0e0a596e3959c3f3f2ab7d443a5b6f0f4a4bba6f",
                setup: "https://github.com/handy-computer/transcribe.cpp/blob/v0.4.1/docs/models/qwen3-asr-1.7b.md",
                format: "GGUF · Q8_0", note: "Converted for transcribe.cpp by its maintainers."),
            managed(
                "nemotron-35-asr", "Nemotron 3.5 ASR 0.6B",
                "Recognition built to keep up as you speak.",
                "https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b", "OpenMDW-1.1", ["nemotron-35-q4"],
                "en es fr it pt nl de tr ru ar hi ja ko vi uk pl sv cs nb da bg fi hr sk zh hu ro et"
                    .split(separator: " ").map(String.init),
                files:
                    "https://huggingface.co/handy-computer/nemotron-3.5-asr-streaming-0.6b-gguf/tree/53ce288f69326b415aeef030cfcb02a08a8096dd",
                setup:
                    "https://github.com/handy-computer/transcribe.cpp/blob/v0.4.1/docs/models/nemotron-3.5-asr-streaming-0.6b.md",
                format: "GGUF · Q4_K_M", note: "Converted for transcribe.cpp by its maintainers."),
            managed(
                "parakeet-v3", "Parakeet TDT 0.6B v3",
                "Very fast, accurate recognition.",
                "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3", "CC-BY-4.0", ["parakeet-v3-q4"], parakeet,
                files:
                    "https://huggingface.co/handy-computer/parakeet-tdt-0.6b-v3-gguf/tree/d8d8c32cb2017c57e5307767343e97870f8a7f53",
                setup:
                    "https://github.com/handy-computer/transcribe.cpp/blob/v0.4.1/docs/models/parakeet-tdt-0.6b-v3.md",
                format: "GGUF · Q4_K_M", note: "Converted for transcribe.cpp by its maintainers."),
            managed(
                "parakeet-ultra", "Parakeet Ultra",
                "A retrained Parakeet v3 with fewer recognition errors at the same speed.",
                "https://huggingface.co/moondream/parakeet-ultra", "CC-BY-4.0", ["parakeet-ultra-q4"], parakeet,
                files:
                    "https://huggingface.co/handy-computer/parakeet-ultra-gguf/tree/a1539be1b849ea7463b88343e5277b373d0c4ea9",
                setup: "https://github.com/handy-computer/transcribe.cpp/blob/v0.4.1/docs/models/parakeet-ultra.md",
                format: "GGUF · Q4_K_M", note: "Converted for transcribe.cpp by its maintainers."),
            managed(
                "sensevoice-small", "SenseVoice Small",
                "Compact, very fast recognition.",
                "https://huggingface.co/FunAudioLLM/SenseVoiceSmall", "FunASR Model License", ["sensevoice-small-q8"],
                ["zh", "yue", "en", "ja", "ko"],
                files:
                    "https://huggingface.co/handy-computer/SenseVoiceSmall-gguf/tree/4a08b8e900b38a977e32eb08d5d0697d6e72ba04",
                setup: "https://github.com/handy-computer/transcribe.cpp/blob/v0.4.1/docs/models/sensevoice-small.md",
                format: "GGUF · Q8_0", note: "Converted for transcribe.cpp by its maintainers.",
                licenseURL:
                    "https://github.com/modelscope/FunASR/blob/fbbfe01800a8c4c9103cb2150fb1a5d06cc64758/MODEL_LICENSE",
                details: ["Recordings up to 30 seconds."]),
            managed(
                "cohere-transcribe", "Cohere Transcribe",
                "Highly accurate recognition.",
                "https://huggingface.co/CohereLabs/cohere-transcribe-03-2026", "Apache-2.0", ["cohere-transcribe-q4"],
                ["en", "fr", "de", "es", "pt", "it", "nl", "pl", "el", "ar", "ja", "ko", "zh", "vi"],
                files:
                    "https://huggingface.co/handy-computer/cohere-transcribe-03-2026-gguf/tree/dfa4adebb64f3076b7b6b90b721275cc069cb421",
                setup:
                    "https://github.com/handy-computer/transcribe.cpp/blob/v0.4.1/docs/models/cohere-transcribe-03-2026.md",
                format: "GGUF · Q4_K_M", note: "Converted for transcribe.cpp by its maintainers.",
                details: ["Choose the spoken language in Dictation settings."]),
            managed(
                "hy-mt2", "Hy-MT2 1.8B", "A compact, fast translation model.",
                "https://huggingface.co/tencent/Hy-MT2-1.8B", "Apache-2.0", ["hy-mt2-18b-q4"], hyMT,
                files: "https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/tree/a0c709d9fac510f2c807aa3af52872340dc37a4a",
                setup: "https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF", format: "GGUF · Q4_K_M", task: .translation,
                licenseURL:
                    "https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/blob/a0c709d9fac510f2c807aa3af52872340dc37a4a/LICENSE.txt"
            ),
            managed(
                "qwen3-instruct", "Qwen3 4B Instruct 2507",
                "A general text model that translates without extended reasoning.",
                "https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507", "Apache-2.0", ["qwen3-4b-instruct-q4"], qwenText,
                files:
                    "https://huggingface.co/lmstudio-community/Qwen3-4B-Instruct-2507-GGUF/tree/4edb920b6f14e3b9284d4502a6485103d72cde05",
                setup: "https://github.com/ggml-org/llama.cpp", format: "GGUF · Q4_K_M", complete: false,
                note: "GGUF conversion by LM Studio.", task: .translation),
            managed(
                "translategemma", "TranslateGemma 4B",
                "A translation-specific model with a dedicated language template.",
                "https://huggingface.co/google/translategemma-4b-it", "Gemma terms", ["translategemma-4b-q4"],
                // The card states 55 languages without a list; these are the
                // WMT24++ languages it was evaluated on.
                "en ar bg bn ca cs da de el es et fa fi fil fr gu he hi hr hu id is it ja kn ko lt lv ml mr nl nb pa pl pt ro ru sk sl sr sv sw ta te th tr uk ur vi zh zh-Hant zu"
                    .split(separator: " ").map(String.init),
                files:
                    "https://huggingface.co/bullerwins/translategemma-4b-it-GGUF/tree/7c938465a870d8624bcfa98a8e4a3510053c19a8",
                setup: "https://github.com/ggml-org/llama.cpp", format: "GGUF · Q4_K_M", complete: false,
                note: "Community GGUF conversion by bullerwins. Gemma terms apply.", task: .translation,
                licenseURL: "https://ai.google.dev/gemma/terms"),
            managed(
                "kokoro", "Kokoro 82M", "Compact, fast speech with many preset voices.",
                "https://huggingface.co/hexgrad/Kokoro-82M", "Apache-2.0", ["kokoro-82m-q8"],
                ["en", "zh", "es", "fr", "hi", "it", "pt"],
                files:
                    "https://huggingface.co/audio-cpp/audio.cpp-gguf/tree/ef1ab2598f6d4d101486e4c5b9e605c687f20642/Kokoro-82M-GGUF",
                setup: "https://github.com/0xShug0/audio.cpp", format: "GGUF · Q8_0",
                note: "Model and voice files packaged by the audio.cpp maintainers.", task: .readAloud,
                details: [
                    "Portuguese voices are Brazilian.",
                    "Japanese needs a dictionary this model file doesn’t include."
                ]),
            managed(
                "qwen3-tts", "Qwen3 TTS 1.7B CustomVoice",
                "Natural speech with nine preset voices.",
                "https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice", "Apache-2.0",
                ["qwen3-tts-customvoice-q8"], ["zh", "en", "ja", "ko", "de", "fr", "ru", "pt", "es", "it"],
                files:
                    "https://huggingface.co/audio-cpp/audio.cpp-gguf/tree/ef1ab2598f6d4d101486e4c5b9e605c687f20642/Qwen3-TTS-12Hz-1.7B-CustomVoice-GGUF",
                setup: "https://github.com/0xShug0/audio.cpp", format: "GGUF · Q8_0",
                note: "Model and voice files packaged by the audio.cpp maintainers.", task: .readAloud,
                details: ["Includes Beijing and Sichuan dialect voices."]),
            managed(
                "cosyvoice3", "CosyVoice 3 0.5B",
                "Expressive speech that can follow a reference voice.",
                "https://huggingface.co/FunAudioLLM/Fun-CosyVoice3-0.5B-2512", "Apache-2.0", ["cosyvoice3-q8"],
                ["zh", "en", "ja", "ko", "de", "es", "fr", "it", "ru", "yue"],
                files:
                    "https://huggingface.co/audio-cpp/audio.cpp-gguf/tree/ef1ab2598f6d4d101486e4c5b9e605c687f20642/CosyVoice3-GGUF",
                setup: "https://github.com/0xShug0/audio.cpp", format: "GGUF · Q8_0", complete: false,
                note: "Packaged by the audio.cpp maintainers. Includes a sample voice.", task: .readAloud,
                details: ["Also speaks more than 18 Chinese dialects."])

        ]
    }()
}
