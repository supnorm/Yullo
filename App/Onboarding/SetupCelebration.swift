import AppKit
import SwiftUI

// Finishing setup ends in a short burst of squares and hairlines in Yullo's
// colours, thrown up from the setup window and falling away, as on yullo.me. It plays in
// its own click-through panel so it outlives the closing Settings window, and
// is skipped when Reduce Motion is on. The panel sits above every Yullo window,
// including the recording indicator, and the window Settings returns to waits
// until the burst has mostly fallen (see `returnDelay`).
@MainActor enum SetupCelebration {
    private static var panel: NSPanel?
    private static var startedAt: TimeInterval?
    static let duration: TimeInterval = 1.3
    static let size = CGSize(width: 760, height: 560)
    // Above the translator and selection panels (.floating) and the
    // recording indicator (.statusBar); it never takes clicks or focus.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    // Pieces start fading at 70% of their flight; a window coming back after
    // that lets the burst read on its own, and its fading tail stays on top.
    static let returnAfter: TimeInterval = duration * 0.7

    // Time left before a window may return over the burst; zero when none plays.
    static var returnDelay: TimeInterval {
        guard panel != nil, let startedAt else { return 0 }
        return max(0, startedAt + returnAfter - ProcessInfo.processInfo.systemUptime)
    }

    // The burst rises from just below the middle of the setup window, so it
    // fills the window rather than starting at Done in its corner.
    static func playFromCurrentEvent() {
        guard let frame = (NSApp.keyWindow ?? NSApp.mainWindow)?.frame else { return }
        play(at: origin(in: frame))
    }
    static func origin(in windowFrame: CGRect) -> CGPoint {
        CGPoint(x: windowFrame.midX, y: windowFrame.midY - min(80, windowFrame.height / 6))
    }

    // `point` is in screen coordinates (origin at the bottom). The burst's
    // origin sits a quarter of the panel above its bottom edge, which is
    // three quarters down in the panel's own top-down coordinates.
    static func panelFrame(at point: CGPoint) -> CGRect {
        CGRect(x: point.x - size.width / 2, y: point.y - size.height * 0.25, width: size.width, height: size.height)
    }
    static func play(at point: CGPoint) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        panel?.close()
        let frame = panelFrame(at: point)
        let panel = NSPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.contentView = NSHostingView(
            rootView: SetupCelebrationBurst(
                origin: CGPoint(x: size.width / 2, y: size.height * 0.75), pieces: SetupCelebrationPiece.burst()))
        panel.orderFrontRegardless()
        self.panel = panel
        startedAt = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.25) { [weak panel] in
            guard let panel, Self.panel === panel else { return }
            panel.close()
            Self.panel = nil
            startedAt = nil
        }
    }
}

struct SetupCelebrationPiece {
    let size: CGSize
    let color: Color
    let offset: CGSize
    let rotation: Double
    let delay: TimeInterval

    static func burst(count: Int = 42) -> [SetupCelebrationPiece] {
        let colors = [Palette.accent, Palette.accent, Color.primary, Color.secondary]
        return (0..<count).map { index in
            let angle = Double.pi * (1.05 + .random(in: 0...0.9))
            let reach = 90 + Double.random(in: 0...260)
            let line = index % 3 == 0
            return SetupCelebrationPiece(
                size: line
                    ? CGSize(width: 2, height: 12 + .random(in: 0...8))
                    : CGSize(width: 6 + .random(in: 0...4), height: 6 + .random(in: 0...4)),
                color: colors[index % colors.count],
                offset: CGSize(width: cos(angle) * reach, height: sin(angle) * reach * 0.8 + 40),
                rotation: .random(in: -270...270), delay: .random(in: 0...0.12))
        }
    }
}

struct SetupCelebrationBurst: View {
    let origin: CGPoint
    let pieces: [SetupCelebrationPiece]
    @State private var start = Date()
    private static let curve = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.15, y: 0.7), endControlPoint: UnitPoint(x: 0.3, y: 1))

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(start)
            ZStack(alignment: .topLeading) {
                ForEach(pieces.indices, id: \.self) { index in
                    let piece = pieces[index]
                    let t = min(1, max(0, (elapsed - piece.delay) / SetupCelebration.duration))
                    let eased = Self.curve.value(at: t)
                    Rectangle().fill(piece.color)
                        .frame(width: piece.size.width, height: piece.size.height)
                        .rotationEffect(.degrees(piece.rotation * eased))
                        .position(
                            x: origin.x + piece.offset.width * eased, y: origin.y + piece.offset.height * eased
                        )
                        .opacity(elapsed < piece.delay ? 0 : t < 0.7 ? 1 : (1 - t) / 0.3)
                }
            }
        }.frame(width: SetupCelebration.size.width, height: SetupCelebration.size.height)
            .accessibilityHidden(true)
    }
}
