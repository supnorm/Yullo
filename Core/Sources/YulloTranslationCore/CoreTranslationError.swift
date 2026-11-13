import Foundation

// Hosts can preserve failures that require attention instead of silently
// replacing the selected provider. Core does not inspect credentials or the OS.
public protocol CoreFallbackError: Error {
    var allowsAutomaticFallback: Bool { get }
}

// Domain failures are values. Each application supplies its own localized UI.
public enum CoreTranslationError: Error, Equatable, Sendable {
    case invalidEndpoint, missingModel, invalidLanguage
    case http(Int)
    case invalidResponse, refused, truncated, empty
}
