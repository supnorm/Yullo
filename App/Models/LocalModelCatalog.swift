import Foundation

// Immutable publisher/runtime-maintainer artifacts. Weights live in Application
// Support, never in the application bundle. Size, SHA-256 and container are checked
// before an installed model can be selected by a task-specific provider.
enum LocalModelCatalog {
    static let additional: [LocalModelDescriptor] = [
        .init(
            id: "sensevoice-small-q8", name: "SenseVoice Small · Q8", fileName: "SenseVoiceSmall-Q8_0.gguf",
            sizeBytes: 252_684_608, sha256: "6c759ee4c9748c9b3f7a5a60ca74f0f7e685fb9d45d1378fce7cfd62f59adf29",
            downloadURL: URL(
                string:
                    "https://huggingface.co/handy-computer/SenseVoiceSmall-gguf/resolve/4a08b8e900b38a977e32eb08d5d0697d6e72ba04/SenseVoiceSmall-Q8_0.gguf"
            )!,
            supportsCantonese: true, runtime: .transcribe),
        .init(
            id: "cohere-transcribe-q4", name: "Cohere Transcribe · Q4",
            fileName: "cohere-transcribe-03-2026-Q4_K_M.gguf",
            sizeBytes: 1_558_162_944, sha256: "0ea56826d8bd5d74b7143a4a04e022dc1bb75452cfae49d98b6acb0c1d16a1fb",
            downloadURL: URL(
                string:
                    "https://huggingface.co/handy-computer/cohere-transcribe-03-2026-gguf/resolve/dfa4adebb64f3076b7b6b90b721275cc069cb421/cohere-transcribe-03-2026-Q4_K_M.gguf"
            )!,
            supportsCantonese: false, runtime: .transcribe),
        .init(
            id: "qwen3-asr-17b-q8", name: "Qwen3 ASR 1.7B · Q8", fileName: "Qwen3-ASR-1.7B-Q8_0.gguf",
            sizeBytes: 2_185_030_624, sha256: "9a0d81792dfea2d5f278b8a63deb3ea6e02139ce42c2301f32ea19c4f77526b7",
            downloadURL: URL(
                string:
                    "https://huggingface.co/handy-computer/Qwen3-ASR-1.7B-gguf/resolve/0e0a596e3959c3f3f2ab7d443a5b6f0f4a4bba6f/Qwen3-ASR-1.7B-Q8_0.gguf"
            )!,
            supportsCantonese: true, runtime: .transcribe),
        .init(
            id: "parakeet-ultra-q4", name: "Parakeet Ultra · Q4", fileName: "parakeet-ultra-Q4_K_M.gguf",
            sizeBytes: 486_280_096, sha256: "c69b7a5f9071a7afd8a1818ef7ae542c386c4b01ed0cac380c19a99947646bf9",
            downloadURL: URL(
                string:
                    "https://huggingface.co/handy-computer/parakeet-ultra-gguf/resolve/a1539be1b849ea7463b88343e5277b373d0c4ea9/parakeet-ultra-Q4_K_M.gguf"
            )!,
            supportsCantonese: false, runtime: .transcribe),
        .init(
            id: "hy-mt2-18b-q4", name: "Hy-MT2 1.8B · Q4", fileName: "Hy-MT2-1.8B-Q4_K_M.gguf",
            sizeBytes: 1_133_080_448, sha256: "dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699",
            downloadURL: URL(
                string:
                    "https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/a0c709d9fac510f2c807aa3af52872340dc37a4a/Hy-MT2-1.8B-Q4_K_M.gguf"
            )!,
            supportsCantonese: true, runtime: .llama),
        .init(
            id: "qwen3-4b-instruct-q4", name: "Qwen3 4B Instruct 2507 · Q4",
            fileName: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
            sizeBytes: 2_497_280_448, sha256: "8cdb57cbb880d313736a9bc4e3d3d2485f145b5e19cf33783746e753e82641fc",
            downloadURL: URL(
                string:
                    "https://huggingface.co/lmstudio-community/Qwen3-4B-Instruct-2507-GGUF/resolve/4edb920b6f14e3b9284d4502a6485103d72cde05/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
            )!,
            supportsCantonese: true, runtime: .llama),
        .init(
            id: "translategemma-4b-q4", name: "TranslateGemma 4B · Q4", fileName: "translategemma-4b-it-Q4_K_M.gguf",
            sizeBytes: 2_489_909_312, sha256: "7f7357c14abd9da4eb200b38b05da502cd6e10d7e1d403fbc9f78c19f3209b72",
            downloadURL: URL(
                string:
                    "https://huggingface.co/bullerwins/translategemma-4b-it-GGUF/resolve/7c938465a870d8624bcfa98a8e4a3510053c19a8/translategemma-4b-it-Q4_K_M.gguf"
            )!,
            supportsCantonese: false, runtime: .llama),
        .init(
            id: "kokoro-82m-q8", name: "Kokoro 82M · Q8", fileName: "kokoro-82m-q8_0.gguf",
            sizeBytes: 189_550_976, sha256: "9a4ca6176460cdc8c7845b804c0bbe85a4791ee3ffff568a3fdadbb708c63f47",
            downloadURL: URL(
                string:
                    "https://huggingface.co/audio-cpp/audio.cpp-gguf/resolve/ef1ab2598f6d4d101486e4c5b9e605c687f20642/Kokoro-82M-GGUF/kokoro-82m-q8_0.gguf"
            )!,
            supportsCantonese: false, runtime: .audioSpeech),
        .init(
            id: "qwen3-tts-customvoice-q8", name: "Qwen3 TTS 1.7B CustomVoice · Q8",
            fileName: "qwen3-tts-12hz-1.7b-customvoice-q8_0.gguf",
            sizeBytes: 2_817_055_200, sha256: "c8ac3f94b6e73f137c0e7ecc9270bc8faec7a476ff799b87e48844d1d0987ac3",
            downloadURL: URL(
                string:
                    "https://huggingface.co/audio-cpp/audio.cpp-gguf/resolve/ef1ab2598f6d4d101486e4c5b9e605c687f20642/Qwen3-TTS-12Hz-1.7B-CustomVoice-GGUF/qwen3-tts-12hz-1.7b-customvoice-q8_0.gguf"
            )!,
            supportsCantonese: false, runtime: .audioSpeech),
        .init(
            id: "cosyvoice3-q8", name: "CosyVoice 3 · Q8", fileName: "cosyvoice3-q8_0.gguf",
            sizeBytes: 2_257_658_336, sha256: "d13bd731ead92d6d514d5749d9b59ea1b3ae735569fa46978250caaf5c983133",
            downloadURL: URL(
                string:
                    "https://huggingface.co/audio-cpp/audio.cpp-gguf/resolve/ef1ab2598f6d4d101486e4c5b9e605c687f20642/CosyVoice3-GGUF/cosyvoice3-q8_0.gguf"
            )!,
            supportsCantonese: true, runtime: .audioSpeech)
    ]
}
