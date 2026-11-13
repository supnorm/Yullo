import SwiftUI

#if YULLO_TESTING
    struct WelcomeAttachedActions {
        let startSetup: () -> Void
        let notNow: () -> Void
    }
#endif

// How a new user gets back into a menu-bar app, as plain values from the app
// owner. Welcome never reads Preferences, Keychain, permissions or models.
// A key is present only for an assigned global shortcut that registered;
// nil hides that key cap and the description still stands alone.
struct WelcomeEntryPoints: Equatable {
    struct Key: Equatable {
        var label: String
        var spokenLabel: String
    }
    var showYullo: Key?
    var translateSelection: Key?
    var dictation: Key?
    var refineSelection: Key?
    var menuBarItemVisible = false
    // One language: what they came for leads, and translation follows.
    var oneLanguage = false
}

@MainActor struct WelcomeView: View {
    var entryPoints = WelcomeEntryPoints()
    let startSetup: () -> Void
    let notNow: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    #if YULLO_TESTING
        var yulloTestingCaptureActions: ((WelcomeAttachedActions) -> Void)?
    #endif

    // Symbols share one column; every description, note and hairline starts
    // on the text edge after it. Key caps form the trailing column.
    private let symbolColumn: CGFloat = 26
    private let columnGap: CGFloat = 12
    // The two-bubble translate glyph is wider and heavier than the others.
    private static let symbolSize: [String: CGFloat] = ["translate": 13]
    private let pageWidth: CGFloat = 700
    private let gutter: CGFloat = 36

    // Only whitespace changes between densities; type sizes stay fixed.
    private struct Spacing {
        let margin, headline, section, row, notes: CGFloat
        static let regular = Spacing(margin: 28, headline: 18, section: 16, row: 9, notes: 8)
        static let compact = Spacing(margin: 16, headline: 10, section: 12, row: 5, notes: 6)
    }

    var body: some View {
        // Shipped translations fit the minimum Settings size, compact at worst.
        // Far longer text scrolls the introduction while both decisions stay
        // pinned and visible.
        ViewThatFits(in: .vertical) {
            page(.regular)
            page(.compact)
            VStack(spacing: 0) {
                // A visible scroller and a short fade say the text continues.
                ScrollView(.vertical) {
                    introduction(.compact).padding(.horizontal, gutter).padding(.vertical, Spacing.compact.margin)
                        .frame(maxWidth: pageWidth).frame(maxWidth: .infinity).smallNativeScrollbars()
                }
                .scrollIndicators(.visible)
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 24)
                    }
                }
                footer(.compact).padding(.horizontal, gutter).padding(.bottom, Spacing.compact.margin)
                    .frame(maxWidth: pageWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.locale, L10n.locale)
        .onAppear {
            #if YULLO_TESTING
                yulloTestingCaptureActions?(.init(startSetup: startSetup, notNow: notNow))
            #endif
        }
    }

    private func page(_ spacing: Spacing) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            introduction(spacing)
            footer(spacing)
        }
        .padding(.horizontal, gutter).padding(.vertical, spacing.margin)
        .background {
            #if YULLO_TESTING
                WelcomeLayoutProbe(name: "content")
            #endif
        }
        .frame(maxWidth: pageWidth)
    }

    private func yullo(_ spacing: Spacing, caption: String) -> some View {
        capability("translate", L10n.tr("Yullo"), L10n.tr(caption), key: entryPoints.showYullo, spacing: spacing)
    }
    private func translateSelection(_ spacing: Spacing) -> some View {
        capability(
            "character.cursor.ibeam", L10n.tr("Translate selected text"),
            L10n.tr("In any app, replace it where you can type."),
            key: entryPoints.translateSelection, spacing: spacing)
    }
    private func dictate(_ spacing: Spacing, caption: String) -> some View {
        capability("mic", L10n.tr("Dictate"), L10n.tr(caption), key: entryPoints.dictation, spacing: spacing)
    }
    private func refine(_ spacing: Spacing) -> some View {
        capability(
            "pencil.line", L10n.tr("Refine and read aloud"),
            L10n.tr("Polish selected text, or hear it read aloud."),
            key: entryPoints.refineSelection, spacing: spacing)
    }

    private func introduction(_ spacing: Spacing) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: colorScheme == .dark ? BrandArtwork.darkSettingsIcon : BrandArtwork.lightSettingsIcon)
                    .resizable().frame(width: 38, height: 38).accessibilityHidden(true)
                Text("Yullo").font(BrandTypography.wordmark(size: 34)).tracking(-1)
            }
            Text(L10n.tr("Your ideas, less effort"))
                .font(.system(size: 26, weight: .semibold)).tracking(-0.5)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, spacing.headline)
            VStack(alignment: .leading, spacing: 0) {
                if entryPoints.oneLanguage {
                    dictate(spacing, caption: "Speak into any app: word for word or refined.")
                    rule
                    refine(spacing)
                    rule
                    yullo(spacing, caption: "Type or paste to translate or refine.")
                    rule
                    translateSelection(spacing)
                } else {
                    yullo(spacing, caption: "Translation follows as you type.")
                    rule
                    translateSelection(spacing)
                    rule
                    dictate(spacing, caption: "Speak into any app: word for word, translated or refined.")
                    rule
                    refine(spacing)
                }
            }.padding(.top, spacing.section)
            // Practical notes share one group below the capabilities.
            VStack(alignment: .leading, spacing: spacing.notes) {
                if entryPoints.menuBarItemVisible {
                    // The real menu-bar glyph shows which icon to look for later.
                    note(
                        Image(nsImage: BrandArtwork.templateImage).renderingMode(.template).resizable()
                            .frame(width: 14, height: 14),
                        L10n.tr("Yullo stays in the menu bar after you close this window.")
                    )
                    .background {
                        #if YULLO_TESTING
                            WelcomeLayoutProbe(name: "menu-bar")
                        #endif
                    }
                }
                note(
                    Image(systemName: "lock.shield").font(.system(size: 13)),
                    L10n.tr(
                        "Speech recognition runs on this Mac. Translation and read aloud can stay here or use a service you choose."
                    ))
                note(
                    Image(systemName: "hand.raised").font(.system(size: 13)),
                    L10n.tr("Setup asks for microphone and, optionally, Accessibility access."))
            }.padding(.top, spacing.section)
        }
    }

    private func footer(_ spacing: Spacing) -> some View {
        VStack(spacing: 0) {
            Divider().padding(.top, spacing.section + 4)
            WelcomeFooterLayout(spacing: 20, stackedSpacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.format("Start the guide anytime in %@.", L10n.tr("Quick setup")))
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .background {
                    #if YULLO_TESTING
                        WelcomeLayoutProbe(name: "footer-note")
                    #endif
                }
                HStack(spacing: 10) {
                    Button(L10n.tr("Not now"), action: notNow).keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("welcome-not-now")
                        .background {
                            #if YULLO_TESTING
                                WelcomeActionLayoutProbe(name: "not-now")
                            #endif
                        }
                    Button(L10n.tr("Set up Yullo"), action: startSetup)
                        .keyboardShortcut(.defaultAction).accessibilityIdentifier("welcome-start-setup")
                        .background {
                            #if YULLO_TESTING
                                WelcomeActionLayoutProbe(name: "start-setup")
                            #endif
                        }
                }.controlSize(.large).fixedSize()
            }.padding(.top, spacing.section - 2)
        }
    }

    private var rule: some View {
        Divider().padding(.leading, symbolColumn + columnGap)
    }

    private func capability(
        _ symbol: String, _ title: String, _ detail: String, key: WelcomeEntryPoints.Key?, spacing: Spacing
    ) -> some View {
        // Symbol and key cap centre on the title's cap height.
        HStack(alignment: .firstTextBaseline, spacing: columnGap) {
            Image(systemName: symbol).font(.system(size: Self.symbolSize[symbol, default: 15]))
                .foregroundStyle(Palette.accent).frame(width: symbolColumn, height: 20).accessibilityHidden(true)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let key {
                Text(key.label).font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.quinary))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .fixedSize().padding(.leading, 4)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                    .accessibilityLabel(key.spokenLabel)
                    .background {
                        #if YULLO_TESTING
                            WelcomeLayoutProbe(name: "key")
                        #endif
                    }
            }
        }
        .padding(.vertical, spacing.row)
        .accessibilityElement(children: .combine)
    }

    private func note(_ icon: some View, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: columnGap) {
            icon.foregroundStyle(.secondary)
                .frame(width: symbolColumn).accessibilityHidden(true)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.2 }
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// The note sits beside the actions only when none of its lines wraps there;
// otherwise it takes the full width above right-aligned actions. Reading
// order is the same either way.
private struct WelcomeFooterLayout: Layout {
    let spacing: CGFloat
    let stackedSpacing: CGFloat

    private func arrangement(_ width: CGFloat, _ subviews: Subviews) -> (note: CGSize, actions: CGSize, beside: Bool) {
        let actions = subviews[1].sizeThatFits(.unspecified)
        let full = subviews[0].sizeThatFits(.init(width: width, height: nil))
        let besideWidth = width - actions.width - spacing
        if besideWidth >= 200 {
            let beside = subviews[0].sizeThatFits(.init(width: besideWidth, height: nil))
            if beside.height <= full.height + 0.5 {
                return (CGSize(width: besideWidth, height: beside.height), actions, true)
            }
        }
        return (CGSize(width: width, height: full.height), actions, false)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Unconstrained, the ideal is one line of note beside the actions.
        let width =
            proposal.width
            ?? subviews[0].sizeThatFits(.unspecified).width + spacing + subviews[1].sizeThatFits(.unspecified).width
        let parts = arrangement(width, subviews)
        let height =
            parts.beside
            ? max(parts.note.height, parts.actions.height) : parts.note.height + stackedSpacing + parts.actions.height
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let parts = arrangement(bounds.width, subviews)
        let note = ProposedViewSize(width: parts.note.width, height: nil)
        if parts.beside {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY - parts.note.height / 2), proposal: note)
            subviews[1].place(
                at: CGPoint(x: bounds.maxX - parts.actions.width, y: bounds.midY - parts.actions.height / 2),
                proposal: .init(parts.actions))
        } else {
            subviews[0].place(at: bounds.origin, proposal: note)
            subviews[1].place(
                at: CGPoint(x: bounds.maxX - parts.actions.width, y: bounds.minY + parts.note.height + stackedSpacing),
                proposal: .init(parts.actions))
        }
    }
}

#if YULLO_TESTING
    struct WelcomeActionLayoutProbe: NSViewRepresentable {
        let name: String
        func makeNSView(context: Context) -> Probe { Probe() }
        func updateNSView(_ view: Probe, context: Context) { view.name = name }
        final class Probe: NSView {
            var name = ""
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
    }
    // Content, key-cap, menu-bar and footer-note frames for overflow and overlap checks.
    struct WelcomeLayoutProbe: NSViewRepresentable {
        let name: String
        func makeNSView(context: Context) -> Probe { Probe() }
        func updateNSView(_ view: Probe, context: Context) { view.name = name }
        final class Probe: NSView {
            var name = ""
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
    }
#endif
