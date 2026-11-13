import Foundation

struct AzureSpeech {
    static let voices = Dictionary(
        uniqueKeysWithValues: Language.catalog.compactMap { language in
            language.azureVoice.map { (language.id, $0) }
        })
    static func region(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.range(of: "^[a-z][a-z0-9]{1,40}$", options: .regularExpression) != nil else { throw Issue.region }
        return value
    }
    static func keyAccount(_ region: String) -> String { "yullo.azure.speech/" + region }
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
    enum Issue: LocalizedError {
        case region
        var errorDescription: String? { L10n.tr("Enter your Azure region, for example, westeurope.") }
    }
}
