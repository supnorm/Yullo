import Foundation
import Translation
import NaturalLanguage

enum AppleTranslationIssue: LocalizedError {
    case unsupported, downloadRequired, unidentified
    var errorDescription: String? {
        switch self {
        case .unsupported:
            return L10n.tr(
                "This language pair isn’t available with Apple. Choose another translation service in Settings.")
        case .downloadRequired: return L10n.tr("These languages aren’t downloaded yet.")
        case .unidentified: return L10n.tr("Choose a source language.")
        }
    }
}

@available(macOS 26.0, *)
enum AppleTranslator {
    static func language(_ code: String) -> Locale.Language {
        Locale.Language(identifier: code == "zh" ? "zh-Hans" : code)
    }
    static func sourceLanguage(text: String, code: String) throws -> Locale.Language {
        if code != "auto" { return language(code) }
        // The system recognizer often assigns Latin-script phonetic input to
        // an unrelated language. Resolve only the bounded, unambiguous cues
        // already used by input analysis; keep the literal source unchanged.
        if let romanized = CoreRomanizedInput.language(in: text) { return language(romanized) }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let detected = recognizer.dominantLanguage else { throw AppleTranslationIssue.unidentified }
        return Locale.Language(identifier: detected.rawValue)
    }
    static func isSameLanguage(_ source: Locale.Language, _ target: Locale.Language) -> Bool {
        source.languageCode == target.languageCode && source.script == target.script
    }
    typealias BatchOperation =
        @Sendable (
            Locale.Language, Locale.Language, [TranslationSession.Request]
        ) async throws -> [TranslationSession.Response]

    static func translateJSONBatch(
        _ batch: CoreJSONTranslationBatch.Batch, source: String, target: String,
        operation: BatchOperation = { from, to, requests in
            try await installedBatch(from: from, to: to, requests: requests)
        }
    ) async throws -> String {
        try Task.checkCancellation()
        guard source != "auto" else { throw AppleTranslationIssue.unidentified }
        guard source != "yue", target != "yue" else { throw AppleTranslationIssue.unsupported }
        let from = language(source), to = language(target)
        var values: [String: String] = [:]
        if isSameLanguage(from, to) {
            values = Dictionary(uniqueKeysWithValues: batch.entries.map { ($0.id, $0.text) })
        } else {
            let requests = batch.entries.map {
                TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id)
            }
            let responses = try await operation(from, to, requests)
            try Task.checkCancellation()
            let originals = Dictionary(uniqueKeysWithValues: batch.entries.map { ($0.id, $0.text) })
            guard responses.count == batch.entries.count else { throw CoreJSONTranslationPlan.Issue.incomplete }
            for response in responses {
                guard let id = response.clientIdentifier, let original = originals[id], values[id] == nil,
                    original.utf8.elementsEqual(response.sourceText.utf8)
                else { throw CoreJSONTranslationPlan.Issue.incomplete }
                values[id] = response.targetText
            }
        }
        return String(decoding: try batch.encodedResponse(values), as: UTF8.self)
    }
    private static func installedBatch(
        from: Locale.Language, to: Locale.Language, requests: [TranslationSession.Request]
    ) async throws -> [TranslationSession.Response] {
        try Task.checkCancellation()
        let status = await LanguageAvailability().status(from: from, to: to)
        try Task.checkCancellation()
        guard status != .unsupported else { throw AppleTranslationIssue.unsupported }
        guard status == .installed else { throw AppleTranslationIssue.downloadRequired }
        let session = TranslationSession(installedSource: from, target: to)
        return try await withTaskCancellationHandler {
            try await session.translations(from: requests)
        } onCancel: {
            session.cancel()
        }
    }

    static func translate(text: String, source: String, target: String) async throws -> String {
        try Task.checkCancellation()
        guard source != "yue", target != "yue" else { throw AppleTranslationIssue.unsupported }
        let from = try sourceLanguage(text: text, code: source)
        let to = language(target)
        try Task.checkCancellation()
        if isSameLanguage(from, to) { return text }
        let status = await LanguageAvailability().status(from: from, to: to)
        try Task.checkCancellation()
        guard status != .unsupported else { throw AppleTranslationIssue.unsupported }
        guard status == .installed else { throw AppleTranslationIssue.downloadRequired }
        let session = TranslationSession(installedSource: from, target: to)
        return try await withTaskCancellationHandler {
            try await session.translate(text).targetText
        } onCancel: {
            session.cancel()
        }
    }
}
