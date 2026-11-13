import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public enum CoreTranslationRoute {
    public struct Result: Equatable, Sendable {
        public let text: String
        public let usedLocal: Bool
        public init(text: String, usedLocal: Bool) {
            self.text = text
            self.usedLocal = usedLocal
        }
    }
    public struct Failure: Error {
        public let remote: Error
        public let local: Error
        public init(remote: Error, local: Error) {
            self.remote = remote
            self.local = local
        }
    }

    /// Providers receive their current request through the caller's closures.
    /// Cancellation never starts a second provider or publishes a late success.
    public static func run(
        localOnly: Bool, offline: Bool, fallback: Bool,
        remote: () async throws -> String, local: () async throws -> String
    ) async throws -> Result {
        try Task.checkCancellation()
        if localOnly || (offline && fallback) {
            let text = try await local()
            try Task.checkCancellation()
            return Result(text: text, usedLocal: true)
        }
        do {
            let text = try await remote()
            try Task.checkCancellation()
            return Result(text: text, usedLocal: false)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            guard fallback, (error as? CoreFallbackError)?.allowsAutomaticFallback != false else { throw error }
            do {
                let text = try await local()
                try Task.checkCancellation()
                return Result(text: text, usedLocal: true)
            } catch let fallbackError {
                try Task.checkCancellation()
                if fallbackError is CancellationError || (fallbackError as? URLError)?.code == .cancelled {
                    throw fallbackError
                }
                throw Failure(remote: error, local: fallbackError)
            }
        }
    }
}
