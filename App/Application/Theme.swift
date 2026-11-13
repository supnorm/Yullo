import SwiftUI
import AppKit
import CoreText
import Combine

struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content
    let isExpanded: Binding<Bool>?
    let summary: String?
    let nested: Bool
    let collapsible: Bool
    init(
        _ title: String, isExpanded: Binding<Bool>? = nil, summary: String? = nil, nested: Bool = false,
        collapsible: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.isExpanded = isExpanded
        self.summary = summary
        self.nested = nested
        self.collapsible = collapsible
        self.content = content()
    }
    private var expanded: Bool { !collapsible || (isExpanded?.wrappedValue ?? true) }
    var body: some View {
        if let isExpanded {
            VStack(alignment: .leading, spacing: expanded ? 6 : 0) {
                Group {
                    if collapsible {
                        DisclosureGroup(isExpanded: isExpanded) {
                            EmptyView()
                        } label: {
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(title).font(.system(size: 13, weight: .semibold)).fixedSize()
                                    Spacer(minLength: 0)
                                    if !isExpanded.wrappedValue, let summary, !summary.isEmpty {
                                        Text(summary).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
                                    }
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(title).font(.system(size: 13, weight: .semibold))
                                    if !isExpanded.wrappedValue, let summary, !summary.isEmpty {
                                        Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                    } else {
                        Text(title).font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                // Keep form/session identity and drafts while hiding every
                // interactive and accessibility surface of a closed section.
                Group {
                    if nested {
                        content
                    } else {
                        GroupBox { content.frame(maxWidth: .infinity, alignment: .leading) }
                    }
                }
                .frame(height: expanded ? nil : 0, alignment: .top).clipped()
                .opacity(expanded ? 1 : 0)
                .disabled(!expanded)
                .allowsHitTesting(expanded).accessibilityHidden(!expanded)
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            GroupBox {
                content.frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text(title).font(.system(size: 13, weight: .semibold))
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// The white surface every Settings card and the selected sidebar row sit on,
// over the window's one surface. Solid uses the same shape on opaque white.
struct SettingsCardSurface: ViewModifier {
    var cornerRadius: CGFloat = 12
    var darkFill = 0.07
    var solidDarkFill = 0.07
    // Cards sit a step above the window tint rather than glowing white.
    var lightFill = 0.75
    var solidLightFill = 0.85
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.solidWindowStyle) private var solid
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let increased = contrast == .increased
        let dark = colorScheme == .dark
        let light = increased ? 1 : solid ? solidLightFill : lightFill
        let fill = dark ? (solid ? solidDarkFill : darkFill) + (increased ? 0.03 : 0) : light
        let rim = increased ? (dark ? 0.28 : 0.20) : solid ? 0.08 : (dark ? 0.10 : 0.07)
        content.background(Color.white.opacity(fill), in: shape)
            .overlay { shape.strokeBorder(Color.primary.opacity(rim), lineWidth: increased ? 1 : 0.5) }
    }
}
extension View {
    func settingsCard(cornerRadius: CGFloat = 12) -> some View {
        modifier(SettingsCardSurface(cornerRadius: cornerRadius))
    }
}
struct SettingsCardGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            configuration.label
            configuration.content.padding(.horizontal, 14).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading).settingsCard()
        }
    }
}

// Establish one native/SwiftUI theme before a hosting tree can draw. System
// mode stays inherited after attachment and follows AppKit appearance changes.
@MainActor enum AppTheme {
    static func nativeAppearance(_ value: String) -> NSAppearance? {
        value == "dark" ? NSAppearance(named: .darkAqua) : value == "light" ? NSAppearance(named: .aqua) : nil
    }
    static func colorScheme(_ appearance: NSAppearance) -> ColorScheme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
    static func apply(_ value: String, to window: NSWindow) {
        window.appearance = nativeAppearance(value)
        (window.contentView as? AppThemeHosting)?.setTheme(value)
    }
}

@MainActor protocol AppThemeHosting: AnyObject {
    func setTheme(_ value: String)
    func synchronizeTheme()
}
@MainActor final class AppThemeState: ObservableObject {
    @Published var colorScheme: ColorScheme
    init(_ appearance: NSAppearance) { colorScheme = AppTheme.colorScheme(appearance) }
}
@MainActor struct AppThemeContent<Content: View>: View {
    let content: Content
    @ObservedObject var theme: AppThemeState
    @ObservedObject private var windowStyle = WindowStyleState.shared
    var body: some View {
        content.environment(\.colorScheme, theme.colorScheme)
            .environment(\.solidWindowStyle, windowStyle.solid)
    }
}

@MainActor final class ThemeHostingView<Content: View>: NSHostingView<AppThemeContent<Content>>, AppThemeHosting {
    private let theme: AppThemeState
    private var preference: String
    init(rootView: Content, theme value: String, inheritedAppearance: NSAppearance) {
        let initial = AppTheme.nativeAppearance(value) ?? inheritedAppearance
        theme = AppThemeState(initial)
        preference = value
        super.init(rootView: AppThemeContent(content: rootView, theme: theme))
        // Detached hosting trees cannot yet inherit their destination window.
        // Seed native controls too, then release this seed on attachment.
        appearance = initial
    }
    required init(rootView: AppThemeContent<Content>) {
        theme = rootView.theme
        preference = "system"
        super.init(rootView: rootView)
    }
    required init?(coder: NSCoder) { fatalError("Use init(rootView:theme:inheritedAppearance:)") }
    func setTheme(_ value: String) {
        preference = value
        appearance = AppTheme.nativeAppearance(value) ?? (window == nil ? NSApp.effectiveAppearance : nil)
        synchronizeTheme()
    }
    func synchronizeTheme() {
        let resolved = AppTheme.nativeAppearance(preference) ?? window?.effectiveAppearance ?? effectiveAppearance
        let scheme = AppTheme.colorScheme(resolved)
        if theme.colorScheme != scheme { theme.colorScheme = scheme }
    }
    override func viewDidMoveToWindow() {
        if preference == "system", window != nil { appearance = nil }
        synchronizeTheme()
        super.viewDidMoveToWindow()
    }
    override func viewDidChangeEffectiveAppearance() {
        synchronizeTheme()
        super.viewDidChangeEffectiveAppearance()
    }
}

enum BrandTypography {
    static func wordmark(size: CGFloat) -> Font {
        guard let installed = NSFont(name: "HelveticaNeue-Medium", size: size) else {
            return .system(size: size, weight: .medium)
        }
        return Font(installed as CTFont)
    }
    // Register only this app's bundled OFL font, only in this process. The
    // cached base font avoids file access/registration during view updates;
    // CoreText's normal cascade supplies glyphs outside Plex Mono's coverage.
    private static let annotationBase: CTFont? = {
        guard
            let url = Bundle.main.url(forResource: "IBMPlexMono-Regular", withExtension: "otf", subdirectory: "Fonts"),
            let descriptor = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first
        else { return nil }
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return CTFontCreateWithFontDescriptor(descriptor, 12, nil)
    }()
    static func annotation(size: CGFloat) -> Font {
        guard let base = annotationBase else { return .system(size: size, design: .monospaced) }
        return Font(CTFontCreateCopyWithAttributes(base, size, nil, nil))
    }
}

enum Palette {
    static let accent = Color(
        nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(srgbRed: 137 / 255, green: 161 / 255, blue: 255 / 255, alpha: 1)
            }
            return BrandArtwork.blueColor
        })
    static let button = Color(nsColor: BrandArtwork.blueColor)
}

// Settings rows: the label on the left, a small switch on the shared trailing
// edge. A dependent switch is hidden while its parent is off, so none is dimmed here.
struct SettingsRowToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsRowToggle(configuration: configuration)
    }
}

private struct SettingsRowToggle: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(isEnabled ? .primary : .tertiary)
            Toggle("", isOn: configuration.$isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
    }
}

// Shared widths, so every card's controls start and end on the same columns.
enum SettingsControl {
    // A single pop-up, segmented control, field or slider group.
    static let width: CGFloat = 220
}
extension View {
    // Native pop-ups and segmented controls hug their title unless told to fill;
    // here they fill the shared control column.
    func settingsControlWidth(_ width: CGFloat = SettingsControl.width) -> some View {
        buttonSizing(.flexible).frame(width: width)
    }
}

// The rows of one card: each at least 34 pt tall, a hairline between rows.
// A child marked `settingsRowAttached()` (feedback, a status line) follows the
// row above it without a hairline; `settingsGroupLabel()` names the rows under it.
struct SettingsRows<Content: View>: View {
    @ViewBuilder var content: Content
    // On a page with removable rows, every other row ends this far in, so the whole
    // page shares one trailing edge; a row with its own remove slot fills the width.
    @Environment(\.settingsTrailingInset) private var trailingInset
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.element.id) { index, row in
                    let role = row.containerValues.settingsRowRole
                    let previous = index > 0 ? subviews[index - 1].containerValues.settingsRowRole : .label
                    if role == .row, previous != .label { Divider() }
                    switch role {
                    case .attached:
                        row.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
                    case .label:
                        row.frame(maxWidth: .infinity, alignment: .leading).padding(.top, index == 0 ? 8 : 14)
                            .padding(.bottom, 2)
                    case .row:
                        row.frame(maxWidth: .infinity, minHeight: 34, alignment: .leading).padding(.vertical, 5)
                            .padding(.trailing, row.containerValues.settingsRowOwnsTrailing ? 0 : trailingInset)
                    }
                }
            }
        }.font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
    }
}
enum SettingsRowRole { case row, attached, label }
extension ContainerValues {
    @Entry var settingsRowRole = SettingsRowRole.row
    @Entry var settingsRowOwnsTrailing = false
}
extension EnvironmentValues {
    @Entry var settingsTrailingInset: CGFloat = 0
}
extension View {
    func settingsRowAttached() -> some View { containerValue(\.settingsRowRole, .attached) }
    func settingsGroupLabel() -> some View { containerValue(\.settingsRowRole, .label) }
    // A row that ends with its own remove slot.
    func settingsRowOwnsTrailing() -> some View { containerValue(\.settingsRowOwnsTrailing, true) }
}

// A slider with its value on the shared control column.
struct SettingsSliderControl: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String
    let text: String
    var onEditingChanged: (Bool) -> Void = { _ in }
    var body: some View {
        HStack(spacing: 8) {
            Slider(value: $value, in: range, step: step, onEditingChanged: onEditingChanged).controlSize(.small)
                .accessibilityLabel(label).accessibilityValue(text)
            Text(text).monospacedDigit().frame(width: 44, alignment: .trailing)
        }.frame(width: SettingsControl.width)
    }
}

// A row inside a card that shows or hides the rows under it. Closed on every
// visit; search opens it through the page's revealed sections.
struct SettingsDisclosureRow: View {
    let title: String
    var summary: String? = nil
    @Binding var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                // The title never truncates; the summary gives way first.
                Text(title).lineLimit(1).fixedSize()
                Spacer(minLength: 8)
                if let summary, !summary.isEmpty, !isExpanded {
                    Text(summary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary).rotationEffect(.degrees(isExpanded ? 90 : 0))
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(isExpanded ? .isSelected : [])
    }
}

// Output pop-ups share one width, so Format and Language line up as columns in every row.
enum SettingsOutputColumns {
    static let popup: CGFloat = 134
    static let connector: CGFloat = 22
    // The trailing slot a row's remove control takes; rows without one keep it empty.
    static let remove: CGFloat = 18
    // Every other control in a card with removable rows ends this far in, on one column.
    static let removeInset: CGFloat = remove + 8
    static var pair: CGFloat { popup * 2 + connector + 8 }
}
