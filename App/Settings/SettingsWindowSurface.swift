import AppKit
import Combine
import SwiftUI

// Window style: Liquid Glass, or Solid, the same layout on opaque surfaces.
// Only the material changes, so switching moves nothing. One shared value so
// every open window, panel and sheet switches together, live, like Theme.
// Settings previews its draft here before committing.
@MainActor final class WindowStyleState: ObservableObject {
    static let shared = WindowStyleState()
    @Published private(set) var solid = false
    func apply(solid: Bool) {
        if self.solid != solid { self.solid = solid }
    }
}

private struct SolidWindowStyleKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var solidWindowStyle: Bool {
        get { self[SolidWindowStyleKey.self] }
        set { self[SolidWindowStyleKey.self] = newValue }
    }
}

// Yullo's one glass material: untinted Liquid Glass under a colour layer of
// its own, heavy enough that the desktop reads as a soft hue rather than
// shapes. The tint is a separate layer because macOS drops a glass view's
// own tint while its window is inactive, which would turn the surface pale
// and see-through behind other apps. Reduce Transparency swaps the glass for
// a solid fill; Increase Contrast thickens the colour layer. Content sits on
// white card surfaces, never on a second layer of glass. In Solid, the same
// surface is opaque and the glass is not drawn.
@MainActor class YulloGlassView: NSView {
    enum Role {
        // Settings, Welcome, the guide, voice editing and comparison.
        case window
        // Floating panels over work: the translator and Scenario, a visible
        // step lighter than windows.
        case panel
        // Sheets lift off their parent: lighter, with a rim.
        case sheet
    }
    struct Look: Equatable {
        let role: Role
        let solid: Bool
        let reduceTransparency: Bool
        let increaseContrast: Bool
        let dark: Bool
        var showsGlass: Bool { !solid && !reduceTransparency }
        var fill: NSColor {
            if solid {
                switch role {
                case .window: return dark ? Self.rgb(0x1C, 0x1C, 0x1E) : Self.rgb(0xEF, 0xF0, 0xF3)
                case .panel: return dark ? Self.rgb(0x23, 0x23, 0x26) : Self.rgb(0xEF, 0xF0, 0xF3)
                case .sheet: return dark ? Self.rgb(0x2A, 0x2A, 0x2D) : Self.rgb(0xF7, 0xF8, 0xFA)
                }
            }
            if reduceTransparency {
                switch role {
                case .sheet: return dark ? Self.rgb(0x2C, 0x2C, 0x2F) : Self.rgb(0xF2, 0xF3, 0xF6)
                case .window, .panel: return dark ? Self.rgb(0x22, 0x23, 0x26) : Self.rgb(0xE3, 0xE5, 0xEA)
                }
            }
            switch role {
            case .sheet:
                let base = dark ? Self.rgb(0x2A, 0x2A, 0x2D) : Self.rgb(0xF0, 0xF1, 0xF4)
                return base.withAlphaComponent(min(0.98, (dark ? 0.94 : 0.92) + (increaseContrast ? 0.04 : 0)))
            case .window, .panel:
                let base = dark ? Self.rgb(0x1E, 0x1E, 0x21) : Self.rgb(0xDF, 0xE2, 0xE8)
                let alpha: CGFloat = role == .window ? (dark ? 0.92 : 0.85) : (dark ? 0.85 : 0.72)
                return base.withAlphaComponent(min(0.98, alpha + (increaseContrast ? 0.08 : 0)))
            }
        }
        // Sheets carry a rim that separates them from their parent. Solid
        // windows and panels get one in light only, so a light surface keeps
        // its edge over a white page; in dark, macOS draws the window rim.
        var rim: (color: NSColor, width: CGFloat)? {
            guard role == .sheet || (solid && !dark) else { return nil }
            let alpha: CGFloat = increaseContrast ? (dark ? 0.28 : 0.20) : (dark ? 0.10 : 0.08)
            return ((dark ? NSColor.white : .black).withAlphaComponent(alpha), increaseContrast ? 1 : 0.5)
        }
        static func == (lhs: Look, rhs: Look) -> Bool {
            lhs.role == rhs.role && lhs.solid == rhs.solid && lhs.reduceTransparency == rhs.reduceTransparency
                && lhs.increaseContrast == rhs.increaseContrast && lhs.dark == rhs.dark
        }
        private static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> NSColor {
            NSColor(
                srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        }
    }

    // macOS 26 sheet and window corners; the rim follows them.
    static let sheetCornerRadius: CGFloat = 16
    static let windowCornerRadius: CGFloat = 16

    let role: Role
    // The shape's corner radius where the surface is clipped by its owner,
    // such as the translator's rounded panel.
    var cornerRadius: CGFloat?
    private let glass = NSGlassEffectView()
    private let tint = NSView()
    private var observers: [NSObjectProtocol] = []
    private var styleObserver: AnyCancellable?

    init(role: Role = .window) {
        self.role = role
        super.init(frame: .zero)
        glass.style = .regular
        tint.wantsLayer = true
        for view in [glass, tint] { pin(view) }
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        styleObserver = WindowStyleState.shared.$solid.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Use init(role:)") }
    deinit {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
    func pin(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    var look: Look {
        let workspace = NSWorkspace.shared
        let reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        let increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        return Look(
            role: role, solid: WindowStyleState.shared.solid, reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast,
            dark: (window?.effectiveAppearance ?? effectiveAppearance).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }
    func refresh() {
        let look = look
        glass.isHidden = !look.showsGlass
        let appearance = window?.effectiveAppearance ?? effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            tint.layer?.backgroundColor = look.fill.cgColor
            tint.layer?.borderColor = look.rim?.color.cgColor
        }
        tint.layer?.borderWidth = look.rim?.width ?? 0
        tint.layer?.cornerRadius =
            cornerRadius ?? (role == .sheet ? Self.sheetCornerRadius : role == .window ? Self.windowCornerRadius : 0)
        tint.layer?.cornerCurve = .continuous
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }
}

// The glass as a SwiftUI background.
struct YulloGlassBackground: NSViewRepresentable {
    var role: YulloGlassView.Role = .window
    var cornerRadius: CGFloat?
    // Read so a style switch updates the surface.
    @Environment(\.solidWindowStyle) private var solid
    func makeNSView(context: Context) -> YulloGlassView {
        let view = YulloGlassView(role: role)
        view.cornerRadius = cornerRadius
        return view
    }
    func updateNSView(_ view: YulloGlassView, context: Context) {
        view.cornerRadius = cornerRadius
        view.refresh()
    }
}

// The translator's rounded surface.
struct YulloPanelBackground: View {
    let cornerRadius: CGFloat
    var body: some View {
        YulloGlassBackground(role: .panel, cornerRadius: cornerRadius)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    // Lists never paint an opaque slab over the surface: their rows sit on
    // the card surface instead.
    func glassList() -> some View { scrollContentBackground(.hidden).settingsCard() }
    // Settings sheets lift off the window on a lighter surface with a rim,
    // and use the same cards.
    func glassSheet() -> some View {
        presentationBackground { YulloGlassBackground(role: .sheet) }.groupBoxStyle(SettingsCardGroupBoxStyle())
    }
}

// Window chrome: content runs under a transparent title bar over a clear
// window, so the traffic lights sit on the surface in both styles.
@MainActor enum GlassWindowChrome {
    static func apply(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
    }
}

// Settings fills its whole window with the glass, behind the SwiftUI root.
@MainActor final class SettingsWindowSurface: YulloGlassView, AppThemeHosting {
    let content: NSView

    static func install(_ content: NSView, in window: NSWindow) {
        GlassWindowChrome.apply(window)
        window.contentView = SettingsWindowSurface(content: content)
    }

    init(content: NSView) {
        self.content = content
        super.init(role: .window)
        frame = content.frame
        pin(content)
    }
    required init?(coder: NSCoder) { fatalError("Use init(content:)") }

    func setTheme(_ value: String) { (content as? AppThemeHosting)?.setTheme(value) }
    func synchronizeTheme() { (content as? AppThemeHosting)?.synchronizeTheme() }
}
