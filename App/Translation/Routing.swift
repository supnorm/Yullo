import Foundation

// Compatibility adapter for the macOS application. The portable route speaks
// only in remote/local providers; Apple naming remains at this boundary.
struct TranslationRoute {
    enum Recovery: Equatable, Sendable { case apiKeyAccess }
    struct Result: Sendable {
        let text: String
        let usedApple: Bool
        let terminologyUnavailable: Bool
        let preferredProviderDeferred: Bool
        let usedMixedProviders: Bool
        let recovery: Recovery?
        // The text was already in the target language and went in unchanged.
        var alreadyInTarget = false
        // Part of the source came back untranslated, also after a second try.
        var incomplete = false
        // The chosen model on this Mac, named, when Apple stood in because it isn't downloaded yet.
        var appleStoodInFor: String? = nil
        var usedAnyApple: Bool { usedApple || usedMixedProviders }
        var appleFallbackNoticeKey: String {
            if recovery == .apiKeyAccess {
                return usedMixedProviders
                    ? "Some parts were translated with Apple. API key access was unavailable."
                    : "Translated with Apple. API key access was unavailable."
            }
            if usedMixedProviders { return "Some parts were translated with Apple." }
            return preferredProviderDeferred
                ? "Translated with Apple after a recent API failure." : "Translated with Apple"
        }
        // What every result surface says when Apple translated in place of the chosen service.
        var appleFallbackNotice: String {
            if let model = appleStoodInFor, recovery == nil, !usedMixedProviders {
                return L10n.format("Translated with Apple until %@ is downloaded.", StandInName.unbroken(model))
            }
            return L10n.tr(appleFallbackNoticeKey)
        }
        init(
            text: String, usedApple: Bool, terminologyUnavailable: Bool = false,
            preferredProviderDeferred: Bool = false, usedMixedProviders: Bool = false, recovery: Recovery? = nil
        ) {
            self.text = text
            self.usedApple = usedApple
            self.terminologyUnavailable = terminologyUnavailable
            self.preferredProviderDeferred = preferredProviderDeferred
            self.usedMixedProviders = usedMixedProviders
            self.recovery = recovery
        }
    }
    struct Failure: Error {
        let api: Error
        let apple: Error
    }
    static func run(
        appleOnly: Bool, offline: Bool, fallback: Bool,
        api: () async throws -> String, apple: () async throws -> String
    ) async throws -> Result {
        do {
            let result = try await CoreTranslationRoute.run(
                localOnly: appleOnly, offline: offline,
                fallback: fallback, remote: api, local: apple)
            return Result(text: result.text, usedApple: result.usedLocal)
        } catch let failure as CoreTranslationRoute.Failure {
            throw Failure(api: failure.remote, apple: failure.local)
        } catch let issue as APIError where !appleOnly && !offline && fallback && issue.isKeyAccessFailure {
            // The generic error remains non-fallback for speech/writing. Only
            // this translation route has explicit permission to try Apple.
            try Task.checkCancellation()
            do {
                let text = try await apple()
                try Task.checkCancellation()
                return Result(text: text, usedApple: true, recovery: .apiKeyAccess)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                throw Failure(api: issue, apple: error)
            }
        }
    }
}

// A name never splits across lines in a two-line notice.
enum StandInName {
    static func unbroken(_ name: String) -> String { name.replacingOccurrences(of: " ", with: "\u{00A0}") }
}
