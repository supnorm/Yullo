import Foundation
import Security

enum APIError: LocalizedError, CoreFallbackError {
    case invalidEndpoint, missingModel, invalidLanguage, http(Int), invalidResponse, refused, truncated, empty,
        keychain(OSStatus)
    var allowsAutomaticFallback: Bool {
        if case .keychain = self { return false }
        return true
    }
    // Only TranslationRoute may recover saved-key failures through an already
    // approved Apple fallback. Speech/writing keep the generic gate closed.
    var isKeyAccessFailure: Bool {
        if case .keychain = self { return true }
        return false
    }
    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return L10n.tr("Use an HTTPS API URL, or HTTP for localhost. Leave out credentials and query parameters.")
        case .invalidLanguage: return L10n.tr("Choose a supported source and target language.")
        case .missingModel: return L10n.tr("Enter the model ID from your provider.")
        case .http(let status):
            switch status {
            case 401: return L10n.tr("API key not accepted (401). Check or replace it in Settings.")
            case 403: return L10n.tr("Access denied (403). Check your provider’s account and model permissions.")
            case 404: return L10n.tr("Endpoint or model not found (404). Check the URL and model ID.")
            case 413: return L10n.tr("This text is too long for the service (413). Translate a shorter passage.")
            case 408, 504:
                return L10n.format("The service timed out (%ld). Try again or translate a shorter passage.", status)
            case 500, 502, 503:
                return L10n.format("The service is temporarily unavailable (%ld). Try again later.", status)
            case 429: return L10n.tr("Usage limit reached (429). Check your quota or try again later.")
            default:
                return L10n.format(
                    "The service returned an error (HTTP %ld). Try again or check the API URL.", status)
            }
        case .invalidResponse: return L10n.tr("The server didn’t return a compatible Chat Completions response.")
        case .refused: return L10n.tr("The model declined this translation. Try another model or language.")
        case .truncated:
            return L10n.tr(
                "The model’s output limit cut off the translation. Try another model or a shorter passage."
            )
        case .empty: return L10n.tr("The model returned no translated text.")
        case .keychain(let status):
            if status == errSecNotAvailable { return L10n.tr("Keychain unavailable. Try again.") }
            if status == errSecItemNotFound { return L10n.tr("No saved key.") }
            if status == errSecUserCanceled || status == errSecAuthFailed || status == errSecInteractionNotAllowed
                || status == errSecInteractionRequired
            {
                return L10n.tr("API key access needed.")
            }
            return L10n.tr("Couldn’t read the saved key.")
        }
    }
}

extension APIError {
    init(_ error: CoreTranslationError) {
        switch error {
        case .invalidEndpoint: self = .invalidEndpoint
        case .missingModel: self = .missingModel
        case .invalidLanguage: self = .invalidLanguage
        case .http(let status): self = .http(status)
        case .invalidResponse: self = .invalidResponse
        case .refused: self = .refused
        case .truncated: self = .truncated
        case .empty: self = .empty
        }
    }
}
