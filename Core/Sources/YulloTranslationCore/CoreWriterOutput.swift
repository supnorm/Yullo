import Foundation

// What any writer returns, without what it must not add: line breaks written
// as the characters "\\n", quotation marks around the whole text, and a
// lead-in label alone on the first line. Each is removed only when the input
// itself didn't have it, so real quotations, code and labels stay.
public enum CoreWriterOutput {
    static let labels = [
        "here is the rewritten text:", "here's the rewritten text:", "rewritten text:", "edited text:",
        "here is the translation:", "here's the translation:", "translation:", "here is the email:",
        "here's the email:", "revised text:", "result:", "改写后的文本：", "改写后：", "翻译：", "译文：",
        "überarbeiteter text:", "übersetzung:", "texte révisé :", "texte révisé:", "traduction :", "traduction:"
    ]

    public static func tidy(_ output: String, input: String) -> String {
        var text = CoreAppleWriterCorrection.realBreaks(output, input: input)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let original = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first {
            let line = firstLine.trimmingCharacters(in: .whitespaces).lowercased()
            if labels.contains(line), !original.lowercased().hasPrefix(line) {
                text = String(text.dropFirst(firstLine.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if CoreVoiceEditPrompt.unquotedText(original) == nil, let inner = CoreVoiceEditPrompt.unquotedText(text) {
            text = inner
        }
        return CoreLanguageConventions.repaired(text, input: input)
    }
}

// Hesitation sounds a recognizer writes down. A dictation made only of them
// is no speech, never text to insert; short real words ("OK", "Thanks") stay.
public enum CoreSpokenFiller {
    static let sounds: Set<String> = [
        "um", "umm", "uh", "uhm", "hmm", "hm", "mm", "er", "erm", "äh", "ähm", "euh", "嗯", "呃", "额", "えーと", "えー", "음",
        "эм"
    ]
    public static func isOnlyFiller(_ text: String) -> Bool {
        let words = text.lowercased().split { $0.isWhitespace || $0.isPunctuation }.map(String.init)
        return !words.isEmpty && words.allSatisfy { sounds.contains($0) || $0.allSatisfy { "嗯呃额".contains($0) } }
    }
}
