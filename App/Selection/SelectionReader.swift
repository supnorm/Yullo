import Foundation
import ApplicationServices

// Only values leave the AX worker. The optional token refers to one temporary
// selection; its AX handles and original text never enter the view model.
enum SelectionReader {
    struct Result {
        let text: String
        let bounds: CGRect?
        var replacementToken: UUID? = nil
        // The selection's last character on screen, where a result is shown near.
        var endBounds: CGRect? = nil
    }
    // What a selection shortcut found: text, a focused field with nothing selected,
    // or nothing Yullo could read (no Accessibility text, a protected field, an error).
    enum Outcome {
        case selection(Result)
        case empty
        case unreadable
        var selection: Result? {
            if case .selection(let result) = self { return result }
            return nil
        }
        // Empty selected text is only "nothing selected" when the selected range agrees;
        // some editors report empty text for a selection they do have.
        static func forEmptyText(selectedLength: Int?) -> Outcome {
            (selectedLength ?? 0) > 0 ? .unreadable : .empty
        }
    }
    static func capture(in processID: Int32? = nil) async -> Result? {
        await SelectionReplacement.capture(in: processID)
    }
    static func captureOutcome(in processID: Int32? = nil) async -> Outcome {
        await SelectionReplacement.captureOutcome(in: processID)
    }
}

// Where a selection is on screen, for placing the chip beneath it.
enum SelectionGeometry {
    struct Screen {
        let frame: CGRect
        let visible: CGRect
    }

    // A long selection's rectangle runs past its scrolled field (measured in
    // TextEdit, Safari and Chrome text areas). Keep the part the field shows;
    // a rectangle outside a valid frame is bogus or scrolled away.
    static func visible(_ rect: CGRect?, within frames: [CGRect]) -> CGRect? {
        guard var shown = rect.flatMap(valid) else { return nil }
        for frame in frames.compactMap(valid) {
            guard shown.intersects(frame) else { return nil }
            shown = shown.intersection(frame)
        }
        return valid(shown)
    }

    // Selection bounds are accessibility coordinates: top-left of the primary
    // display, y down. The result is an AppKit origin: bottom-left, y up.
    // Below the selection's visible part, else above it, else by the pointer.
    static func chipOrigin(
        size: CGSize, below bounds: CGRect?, screens: [Screen], mouse: CGPoint, gap: CGFloat = 8,
        margin: CGFloat = 8
    ) -> CGPoint {
        guard let primary = screens.first else { return mouse }
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { max(low, min(value, high)) }
        if let bounds = bounds.flatMap(valid) {
            let rect = CGRect(
                x: bounds.minX, y: primary.frame.maxY - bounds.maxY, width: bounds.width, height: bounds.height)
            let area = { (screen: Screen) -> CGFloat in
                let shared = rect.intersection(screen.visible)
                return shared.isNull ? 0 : shared.width * shared.height
            }
            if let screen = screens.max(by: { area($0) < area($1) }), area(screen) > 0 {
                let shown = rect.intersection(screen.visible), room = screen.visible
                let x = clamp(shown.minX, room.minX + margin, room.maxX - size.width - margin)
                if shown.minY - gap - size.height >= room.minY + margin {
                    return CGPoint(x: x, y: shown.minY - gap - size.height)
                }
                if shown.maxY + gap + size.height <= room.maxY - margin {
                    return CGPoint(x: x, y: shown.maxY + gap)
                }
            }
        }
        let room = (screens.first { $0.frame.contains(mouse) } ?? primary).visible
        return CGPoint(
            x: clamp(mouse.x - size.width / 2, room.minX + margin, room.maxX - size.width - margin),
            y: clamp(mouse.y - size.height - 24, room.minY + margin, room.maxY - size.height - margin))
    }

    private static func valid(_ rect: CGRect) -> CGRect? {
        guard !rect.isNull, rect.width > 0, rect.height > 0, rect.minX.isFinite, rect.minY.isFinite,
            rect.width.isFinite, rect.height.isFinite
        else { return nil }
        return rect
    }
}
