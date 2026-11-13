import Foundation

// Captured editor offsets are UTF-16 positions, not Character counts. Preserve
// scalar-aligned native selections (including combining marks and CRLF), but
// never form a String index from malformed bounds or half a surrogate pair.
enum TextMutationRange {
    static func validated(_ range: NSRange, in text: String) -> Range<String.Index>? {
        let units = text.utf16
        let count = units.count
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
            range.location <= count, range.length <= count - range.location
        else { return nil }
        let lower = units.index(units.startIndex, offsetBy: range.location)
        let upper = units.index(lower, offsetBy: range.length)
        guard let start = lower.samePosition(in: text.unicodeScalars),
            let end = upper.samePosition(in: text.unicodeScalars)
        else { return nil }
        return start..<end
    }

    // Swift String == permits canonical equivalence. That equivalence cannot
    // authorize reuse of offsets captured from a different code-unit sequence.
    static func identical(_ lhs: String, _ rhs: String) -> Bool {
        // Equal code units imply equal lengths. Compare the length each storage
        // knows in O(1) before walking a large native or bridged editor string.
        let native = lhs.isContiguousUTF8
        if native == rhs.isContiguousUTF8,
            native ? lhs.utf8.count != rhs.utf8.count : lhs.utf16.count != rhs.utf16.count
        {
            return false
        }
        return lhs.utf16.elementsEqual(rhs.utf16)
    }
}
