import Foundation

// Error-recovery text is never a finalized result or automatic delivery.
struct VoiceRecognitionRecoverySnapshot: Equatable, Sendable {
    enum Coverage: Equatable, Sendable { case finalizedSpans, latestWords }
    static let maximumBytes = 262_144
    let text: String
    let coverage: Coverage
    let truncated: Bool
    init?(text: String, coverage: Coverage, truncated: Bool = false) {
        var bytes = Array(text.utf8.prefix(Self.maximumBytes + 1))
        let clipped = bytes.count > Self.maximumBytes
        if clipped { bytes.removeLast() }
        while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        let value = String(bytes: bytes, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        self.text = value
        self.coverage = coverage
        self.truncated = truncated || clipped
    }
}

// Bounded provisional context shared by recognition adapters and the HUD.
// This buffer never becomes a finalized transcript or a delivery authority.
enum VoiceLiveTextBuffer {
    static let maximumBytes = 8_192
    static func suffix(_ text: String) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        var bytes = Array(text.utf8.suffix(maximumBytes))
        // A suffix can begin inside a UTF-8 scalar; discard only its incomplete
        // leading bytes, never replace them with a fabricated character.
        while let first = bytes.first, first & 0xc0 == 0x80 { bytes.removeFirst() }
        return String(decoding: bytes, as: UTF8.self)
    }
}
