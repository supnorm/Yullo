# Shared translation logic, independent of application frameworks. This folder also builds as an
# independent Swift package; the macOS app compiles it into the same executable.
YULLO_TRANSLATION_CORE_SOURCES=(
  Core/Sources/YulloTranslationCore/CoreTranslationError.swift
  Core/Sources/YulloTranslationCore/CoreTranslationPrompt.swift
  Core/Sources/YulloTranslationCore/CoreLongTranslationPlan.swift
  Core/Sources/YulloTranslationCore/CoreLiteralScanner.swift
  Core/Sources/YulloTranslationCore/CoreTechnicalTextPlan.swift
  Core/Sources/YulloTranslationCore/CoreJSONTranslationPlan.swift
  Core/Sources/YulloTranslationCore/CoreJSONTranslationBatch.swift
  Core/Sources/YulloTranslationCore/ChatCompletionsProtocol.swift
  Core/Sources/YulloTranslationCore/ChatCompletionsStreamDecoder.swift
  Core/Sources/YulloTranslationCore/CoreTranslationRoute.swift
  Core/Sources/YulloTranslationCore/CoreLanguageDirectionLearning.swift
  Core/Sources/YulloTranslationCore/CoreRomanizedInput.swift
  Core/Sources/YulloTranslationCore/CoreWritingPrompt.swift
  Core/Sources/YulloTranslationCore/CorePresetInstructions.swift
  Core/Sources/YulloTranslationCore/CorePresetDescription.swift
  Core/Sources/YulloTranslationCore/CoreWritingIntegrity.swift
  Core/Sources/YulloTranslationCore/CoreVoiceEditPrompt.swift
  Core/Sources/YulloTranslationCore/CoreWriterOutput.swift
  Core/Sources/YulloTranslationCore/CoreLanguageConventions.swift
  Core/Sources/YulloTranslationCore/CoreLetterScaffold.swift
  Core/Sources/YulloTranslationCore/CoreVoiceEditExamples.swift
  Core/Sources/YulloTranslationCore/CoreFormatExamples.swift
  Core/Sources/YulloTranslationCore/CoreVocabulary.swift
  Core/Sources/YulloTranslationCore/CoreTermProtection.swift
  Core/Sources/YulloTranslationCore/CoreAppPreferences.swift
  Core/Sources/YulloTranslationCore/CoreDictationPresets.swift
  Core/Sources/YulloTranslationCore/CoreOutputs.swift
  Core/Sources/YulloTranslationCore/CoreOutputPlaces.swift
  Core/Sources/YulloTranslationCore/CoreSameLanguageGate.swift
  Core/Sources/YulloTranslationCore/CoreOllama.swift
  Core/Sources/YulloTranslationCore/CoreAppleWriter.swift
  Core/Sources/YulloTranslationCore/CoreHistoryRetention.swift
  Core/Sources/YulloTranslationCore/CoreHistoryFilter.swift
)
# The current app's error presentation and credential adapter, kept out of Core.
YULLO_APP_API_SOURCES=(
  App/Services/APIErrorPresentation.swift
  App/Services/KeyStore.swift
  App/Services/OllamaClient.swift
)
# Header-only C compatibility shim for legacy file-Keychain UI control.
YULLO_KEYCHAIN_FLAGS=(-import-objc-header App/Services/KeychainInteraction.h)
