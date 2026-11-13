import Foundation

struct WritingReview: Sendable {
    let notice: String?
    let completionNotice: String?

    // This lexical check is separate from model quality. It never rewrites a
    // result or claims to verify its meaning. Large passages stay off the UI.
    static func inspect(
        source: String, result: String, vocabulary: CoreVocabularyConfiguration,
        vocabularyContext: RefinementVocabularyContext? = nil
    ) async throws -> WritingReview {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            var names: [CoreWritingProtectedName] = []
            if vocabulary.enabled {
                let snapshot = try CoreVocabularyProcessor.shared.snapshot(for: vocabulary)
                let protectedTerms =
                    vocabularyContext.map {
                        snapshot.translatedRefinementTerms(
                            in: $0.originalSource, targetLanguage: $0.targetLanguage, translatedText: source)
                    } ?? snapshot.refinementTerms(in: source)
                let relevant = Set(protectedTerms.map(\.source))
                if vocabularyContext != nil {
                    names = protectedTerms.prefix(CoreWritingIntegrity.maximumProtectedNames).map {
                        .init(name: $0.source, boundary: .wholeTerm)
                    }
                }
                for entry in vocabulary.entries where entry.enabled && relevant.contains(entry.canonical) {
                    if let index = names.firstIndex(where: { $0.name == entry.canonical }) {
                        if entry.boundary == .wholeTerm {
                            names[index] = .init(name: entry.canonical, boundary: .wholeTerm)
                        }
                    } else if names.count < CoreWritingIntegrity.maximumProtectedNames {
                        names.append(.init(name: entry.canonical, boundary: entry.boundary))
                    }
                }
            }
            try Task.checkCancellation()
            return try CoreWritingIntegrity.analyze(source: source, result: result, protectedNames: names)
        }
        do {
            let report = try await withTaskCancellationHandler(
                operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            guard case .checked = report.status else { return quiet }
            let changedNames = !report.missingProtectedNames.isEmpty
            let key: String?
            let completion: String?
            switch (report.numericLiteralsChanged, changedNames) {
            case (true, true):
                key = "Review changed numbers, dates, names or terms."
                completion = "Inserted · check key details"
            case (true, false):
                key = "Review changed numbers or dates."
                completion = "Inserted · check numbers or dates"
            case (false, true):
                key = "Review changed names or terms."
                completion = "Inserted · check names or terms"
            case (false, false):
                key = nil
                completion = nil
            }
            return .init(notice: key.map(L10n.tr), completionNotice: completion.map(L10n.tr))
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            return quiet
        }
    }
    private static var quiet: WritingReview {
        .init(notice: nil, completionNotice: nil)
    }
}
