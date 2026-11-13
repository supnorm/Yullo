import AppKit
import SwiftUI

// Attach once inside each ScrollView's document; nested sizing owners are not supported.
// Size only its native vertical bar;
// AppKit continues to own overlay/legacy style, visibility, hover and dragging.
@MainActor struct NativeSmallScrollerSizing: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView(frame: .zero) }
    func updateNSView(_ view: ProbeView, context: Context) { view.updateSizing() }
    static func dismantleNSView(_ view: ProbeView, coordinator: ()) { view.stop() }

    final class ProbeView: NSView {
        private weak var owner: NSScrollView?
        private weak var appliedScroller: NSScroller?
        private var originalSize: NSControl.ControlSize = .regular
        private var observer: NSObjectProtocol?
        private var active = true
        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(false)
            observer = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                // AppKit may replace the scroller while changing style.
                Task { @MainActor [weak self] in self?.updateSizing() }
            }
        }
        required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateSizing()
        }
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            updateSizing()
        }
        override func layout() {
            super.layout()
            updateSizing()
        }
        func updateSizing() {
            guard active, window != nil, let scroll = enclosingScrollView, let bar = scroll.verticalScroller else {
                restore()
                return
            }
            if owner !== scroll || appliedScroller !== bar {
                // A replacement can inherit our small size from the old bar.
                // Retain the original owner size so leaving this page restores it.
                let inheritedSize = owner === scroll && bar.controlSize == .small ? originalSize : bar.controlSize
                restore()
                owner = scroll
                appliedScroller = bar
                originalSize = inheritedSize
            }
            if bar.controlSize != .small {
                bar.controlSize = .small
                scroll.tile()
            }
        }
        func stop() {
            active = false
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            restore()
        }
        private func restore() {
            if let bar = appliedScroller, bar.controlSize == .small {
                bar.controlSize = originalSize
                if owner?.verticalScroller === bar { owner?.tile() }
            }
            appliedScroller = nil
            owner = nil
        }
    }
}

extension View {
    func smallNativeScrollbars() -> some View {
        background(NativeSmallScrollerSizing().allowsHitTesting(false).accessibilityHidden(true))
    }
    // A scroll view's own trailing lane for the overlay scroller; content never sits under it.
    func settingsScrollGutter() -> some View {
        contentMargins(.trailing, NativeScrollGutter.width, for: .scrollContent)
    }
}

// TextEditor leaves AppKit's autohidesScrollers off even with automatic SwiftUI
// indicators. Apply the fitting-content policy only to this editor's backing
// scroll view. AppKit still chooses style, gutter, visibility and scrollability.
@MainActor private struct NativeTextEditorAutohiding: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView(frame: .zero) }
    func updateNSView(_ view: ProbeView, context: Context) { view.updateOwner() }
    static func dismantleNSView(_ view: ProbeView, coordinator: ()) { view.stop() }

    final class ProbeView: NSView {
        private weak var owner: NSScrollView?
        private var originalAutohiding = false
        private var active = true
        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateOwner()
            DispatchQueue.main.async { [weak self] in self?.updateOwner() }
        }
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            updateOwner()
        }
        override func layout() {
            super.layout()
            updateOwner()
        }
        private func matches(_ scroll: NSScrollView) -> Bool {
            guard scroll.window === window, !scroll.isHiddenOrHasHiddenAncestor,
                let editor = scroll.documentView as? NSTextView, editor.isEditable
            else { return false }
            let editorFrame = scroll.convert(scroll.bounds, to: nil)
            let ownFrame = convert(bounds, to: nil)
            return abs(editorFrame.minX - ownFrame.minX) < 1 && abs(editorFrame.minY - ownFrame.minY) < 1
                && abs(editorFrame.width - ownFrame.width) < 1 && abs(editorFrame.height - ownFrame.height) < 1
        }
        private func candidates(in view: NSView) -> [NSScrollView] {
            if let scroll = view as? NSScrollView { return matches(scroll) ? [scroll] : [] }
            return view.subviews.flatMap { candidates(in: $0) }
        }
        func updateOwner() {
            guard active, window != nil, bounds.width > 0, bounds.height > 0 else {
                restore()
                return
            }
            if let owner, matches(owner) {
                if !owner.autohidesScrollers {
                    owner.autohidesScrollers = true
                    owner.tile()
                }
                return
            }
            restore()
            var ancestor = superview
            while let view = ancestor {
                let matches = candidates(in: view)
                if matches.count == 1, let scroll = matches.first {
                    owner = scroll
                    originalAutohiding = scroll.autohidesScrollers
                    if !scroll.autohidesScrollers {
                        scroll.autohidesScrollers = true
                        scroll.tile()
                    }
                    return
                }
                if view === window?.contentView { break }
                ancestor = view.superview
            }
        }
        func stop() {
            active = false
            restore()
        }
        private func restore() {
            let previous = owner
            owner = nil
            if let previous, previous.autohidesScrollers, !originalAutohiding {
                previous.autohidesScrollers = false
                previous.tile()
            }
        }
    }
}

extension View {
    func autohidingTextEditorScrollbars() -> some View {
        background(NativeTextEditorAutohiding().allowsHitTesting(false).accessibilityHidden(true))
    }
}

enum NativeScrollGutter {
    // The small overlay scroller's track plus a hairline.
    static let width: CGFloat = 16
}
