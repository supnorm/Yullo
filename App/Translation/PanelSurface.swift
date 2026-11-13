import SwiftUI
import AppKit

// The Yullo window's surface pieces, shared by every window drawn as it:
// the translator, the selection window and the Edit with voice review.

struct WindowDragRegion: NSViewRepresentable {
    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
}

struct BrandMark: View {
    var size: CGFloat = 16
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Image(nsImage: BrandArtwork.templateImage).resizable().renderingMode(.template)
            .interpolation(.high).frame(width: size, height: size)
            .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.94) : Palette.button)
            .accessibilityHidden(true)
    }
}

// One rounded pane: lighter where input sits, quieter under the result.
struct PaneSurface: View {
    var vertical = false
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        let input = colorScheme == .dark ? Color.white.opacity(0.025) : Color.white.opacity(0.58)
        let output = colorScheme == .dark ? Color.black.opacity(0.12) : Color.white.opacity(0.34)
        LinearGradient(
            stops: [
                .init(color: input, location: 0),
                .init(color: input, location: vertical ? 0.22 : 0.40),
                .init(color: output, location: vertical ? 0.45 : 0.60),
                .init(color: output, location: 1)
            ], startPoint: vertical ? .top : .leading, endPoint: vertical ? .bottom : .trailing)
    }
}
