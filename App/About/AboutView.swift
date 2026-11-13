import SwiftUI
import AppKit

@MainActor struct AboutView: View {
    nonisolated static let contact = "hi@yullo.me"
    nonisolated static let repository = StarAsk.repository.absoluteString
    let openLicenses: () -> Void
    var licenseFocus: FocusState<Bool>.Binding?
    var version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    var build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    private let openWebsite: () -> Void
    private let openContact: () -> Void
    private let openRepository: () -> Void
    private let checkForUpdates: () -> Void
    @FocusState private var localLicenseFocus: Bool
    @FocusState private var releaseNotesFocus: Bool
    @State private var showReleaseNotes = false
    @Environment(\.colorScheme) private var colorScheme

    init(
        openLicenses: @escaping () -> Void, licenseFocus: FocusState<Bool>.Binding? = nil,
        checkForUpdates: (() -> Void)? = nil,
        openWebsite: @escaping () -> Void = { NSWorkspace.shared.open(URL(string: "https://yullo.me")!) },
        openContact: @escaping () -> Void = { NSWorkspace.shared.open(URL(string: "mailto:\(AboutView.contact)")!) },
        openRepository: @escaping () -> Void = { NSWorkspace.shared.open(StarAsk.repository) }
    ) {
        self.openLicenses = openLicenses
        self.licenseFocus = licenseFocus
        self.openWebsite = openWebsite
        self.openContact = openContact
        self.openRepository = openRepository
        self.checkForUpdates = checkForUpdates ?? { AppUpdates.shared.check() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 24) {
                Text("Yullo").font(BrandTypography.wordmark(size: 76)).tracking(-2.2)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                Image(nsImage: colorScheme == .dark ? BrandArtwork.darkSettingsIcon : BrandArtwork.lightSettingsIcon)
                    .resizable().frame(width: 68, height: 68).padding(.bottom, 8).accessibilityHidden(true)
            }.padding(.top, 4).padding(.bottom, 12)
            Text(L10n.tr("Your ideas, less effort"))
                .font(BrandTypography.annotation(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 28)
                .accessibilityIdentifier("about-tagline")
                .aboutCLILeafBounds("about-tagline")
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                AboutActionFlow(spacing: 20, rowSpacing: 12) {
                    metadata("Version", value: version).aboutCLILeafBounds("about-version")
                    metadata("Build", value: build).aboutCLILeafBounds("about-build")
                    updateButton
                }
            }.padding(.top, 20)
            // An index of ruled rows on the same left edge as the metadata. Text
            // stays neutral; the accent marks only each destination's arrow.
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                AboutLinkRow(title: L10n.tr(releaseNotesTitle), symbol: "arrow.right") { showReleaseNotes = true }
                    .focused($releaseNotesFocus)
                    .accessibilityIdentifier("about-whats-new").aboutCLILeafBounds("about-whats-new")
                Divider()
                AboutLinkRow(title: L10n.tr("Open-source licenses"), symbol: "arrow.right", action: openLicenses)
                    .focused(licenseFocus ?? $localLicenseFocus)
                    .accessibilityIdentifier("about-third-party-notices")
                    .aboutCLILeafBounds("about-third-party-notices")
                Divider()
                // Outside destinations: one quiet line under the index. Equal
                // side columns keep the contact address on the centre line.
                // Website leading, contact centred, source trailing on one line;
                // narrow windows wrap them from the leading edge instead.
                AboutOutsideLine(spacing: 12) {
                    websiteLink
                    contactLink
                    // Shown only once the repository is public.
                    if StarAsk.repositoryIsPublic { sourceLink }
                }.frame(maxWidth: .infinity).padding(.top, 4)
                Text(L10n.tr("Yullo™ and the Yullo logo are trademarks."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 16)
                    .accessibilityIdentifier("about-trademark").aboutCLILeafBounds("about-trademark")
            }.padding(.top, 24)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .sheet(isPresented: $showReleaseNotes, onDismiss: { releaseNotesFocus = true }) {
                ReleaseNotesView(version: version, build: build) { showReleaseNotes = false }.glassSheet()
            }
    }

    private var websiteLink: some View {
        AboutLinkRow(title: "yullo.me", symbol: "arrow.up.right", action: openWebsite, compact: true)
            .fixedSize().accessibilityIdentifier("about-website").aboutCLILeafBounds("about-website")
    }
    private var contactLink: some View {
        AboutLinkRow(title: Self.contact, symbol: "envelope", action: openContact, compact: true)
            .fixedSize().accessibilityIdentifier("about-contact").aboutCLILeafBounds("about-contact")
    }
    private var sourceLink: some View {
        AboutLinkRow(title: L10n.tr("Star on GitHub"), symbol: "star", action: openRepository, compact: true)
            .fixedSize().accessibilityIdentifier("about-source").aboutCLILeafBounds("about-source")
    }

    private var releaseNotesTitle: String {
        ReleaseNotes.entry(version: version, build: build)?.titleKey ?? "What’s new"
    }

    // Sparkle shows its own progress and result windows.
    private var updateButton: some View {
        Button(L10n.tr("Check for Updates…"), action: checkForUpdates)
            .font(.system(size: 12))
            .accessibilityIdentifier("about-check-updates")
            .aboutCLILeafBounds("about-check-updates")
    }

    private func metadata(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr(title)).font(BrandTypography.annotation(size: 10)).foregroundStyle(.secondary)
            Text(value).font(BrandTypography.annotation(size: 20)).monospacedDigit().textSelection(.enabled)
        }
    }
}

private struct AboutLinkRow: View {
    let title: String
    let symbol: String
    let action: () -> Void
    // A compact link sits in the line of outside destinations: smaller,
    // secondary text with its symbol right after the title.
    var compact = false
    // Inline beside text: the arrow's extra point is taken back, so the line
    // keeps its plain height; the click target still reaches past the label.
    var inline = false
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: compact ? 5 : 12) {
                Text(title).font(.system(size: compact ? 12 : 13))
                    .foregroundStyle(hovering ? Color.accentColor : compact ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !compact { Spacer(minLength: 8) }
                // The envelope is wider than the arrows; a lighter weight matches them.
                Image(systemName: symbol)
                    .font(
                        .system(
                            size: compact && symbol == "envelope" ? 9 : compact ? 10 : 11,
                            weight: symbol == "envelope" ? .regular : .semibold)
                    )
                    .foregroundStyle(Color.accentColor).accessibilityHidden(true)
            }.padding(.vertical, inline ? -1 : 8).frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
                .contentShape(Rectangle().inset(by: inline ? -4 : 0))
        }.buttonStyle(.plain).onHover { hovering = $0 }.accessibilityLabel(title)
    }
}

private struct AboutOutsideLine: Layout {
    var spacing: CGFloat
    private func centred(_ width: CGFloat, _ sizes: [CGSize]) -> Bool {
        guard sizes.count >= 2 else { return true }
        let side = sizes.enumerated().filter { $0.offset != 1 }.map(\.element.width).max() ?? 0
        return side * 2 + sizes[1].width + spacing * 2 <= width
    }
    private func lines(_ width: CGFloat, _ sizes: [CGSize]) -> [[Int]] {
        var result: [[Int]] = [], row: [Int] = [], used: CGFloat = 0
        for index in sizes.indices {
            let next = row.isEmpty ? sizes[index].width : used + spacing + sizes[index].width
            if !row.isEmpty && next > width {
                result.append(row)
                row = []
            }
            used = row.isEmpty ? sizes[index].width : used + spacing + sizes[index].width
            row.append(index)
        }
        if !row.isEmpty { result.append(row) }
        return result
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width =
            proposal.width.map { $0.isFinite ? $0 : 0 }.flatMap { $0 > 0 ? $0 : nil } ?? sizes.reduce(0) {
                $0 + $1.width
            } + spacing * CGFloat(max(0, sizes.count - 1))
        if centred(width, sizes) { return CGSize(width: width, height: sizes.map(\.height).max() ?? 0) }
        let rows = lines(width, sizes)
        return CGSize(
            width: width,
            height: rows.reduce(0) { $0 + ($1.map { sizes[$0].height }.max() ?? 0) })
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        if centred(bounds.width, sizes) {
            for (index, size) in sizes.enumerated() {
                let x =
                    index == 0 ? bounds.minX : index == 1 ? bounds.midX - size.width / 2 : bounds.maxX - size.width
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(size))
            }
            return
        }
        var y = bounds.minY
        for row in lines(bounds.width, sizes) {
            var x = bounds.minX
            for index in row {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sizes[index]))
                x += sizes[index].width + spacing
            }
            y += row.map { sizes[$0].height }.max() ?? 0  // Rows carry their own padding.
        }
    }
}

// The three metadata actions retain one control each and their reading/focus order as
// the narrow About content wraps; there are no duplicate compact controls.
private struct AboutActionFlow: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = rows(width: proposal.width ?? .infinity, sizes: sizes)
        return CGSize(
            width: rows.map { row in
                row.reduce(CGFloat.zero) { $0 + sizes[$1].width } + spacing * CGFloat(max(0, row.count - 1))
            }.max() ?? 0,
            height: rows.reduce(CGFloat.zero) { $0 + ($1.map { sizes[$0].height }.max() ?? 0) } + rowSpacing
                * CGFloat(max(0, rows.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for row in rows(width: bounds.width, sizes: sizes) {
            let height = row.map { sizes[$0].height }.max() ?? 0
            var x = bounds.minX
            for index in row {
                subviews[index].place(
                    at: CGPoint(x: x, y: y + height - sizes[index].height), anchor: .topLeading,
                    proposal: ProposedViewSize(sizes[index]))
                x += sizes[index].width + spacing
            }
            y += height + rowSpacing
        }
    }
    private func rows(width: CGFloat, sizes: [CGSize]) -> [[Int]] {
        var result: [[Int]] = [], row: [Int] = [], rowWidth: CGFloat = 0
        for index in sizes.indices {
            let nextWidth = row.isEmpty ? sizes[index].width : rowWidth + spacing + sizes[index].width
            if !row.isEmpty && nextWidth > width {
                result.append(row)
                row = []
                rowWidth = 0
            }
            rowWidth += (row.isEmpty ? 0 : spacing) + sizes[index].width
            row.append(index)
        }
        if !row.isEmpty { result.append(row) }
        return result
    }
}

// The first version reads as an introduction: a title, one lead sentence and
// numbered features on a two-column grid, in the About page's typography.
@MainActor struct ReleaseNotesView: View {
    let version: String
    let build: String
    let close: () -> Void
    private var entry: ReleaseNotes.Entry? { ReleaseNotes.entry(version: version, build: build) }
    @State private var moreBelow = true
    private var metadata: String {
        var parts = ["Yullo " + version, L10n.tr("Build") + " " + build]
        if entry?.isPreview == true { parts.append(L10n.tr("Preview")) }
        return parts.joined(separator: " · ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L10n.tr(entry?.titleKey ?? "What’s new"))
                        .font(BrandTypography.wordmark(size: 34)).tracking(-0.8)
                        .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                    Text(metadata).font(BrandTypography.annotation(size: 11)).foregroundStyle(.secondary)
                        .textSelection(.enabled).padding(.top, 8)
                        .aboutCLILeafBounds("release-notes-version")
                    if let entry {
                        Text(L10n.tr(entry.leadKey)).font(.system(size: 15))
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            .padding(.top, 22).padding(.bottom, 22)
                            .aboutCLILeafBounds("release-notes-introduction")
                        Divider()
                        ForEach(Array(entry.features.enumerated()), id: \.element.id) { index, feature in
                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                Text(String(format: "%02d", index + 1))
                                    .font(BrandTypography.annotation(size: 11)).monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .leading).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(L10n.tr(feature.titleKey)).font(.system(size: 13, weight: .semibold))
                                    Text(L10n.tr(feature.detailKey)).font(.system(size: 13))
                                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }.accessibilityElement(children: .combine)
                            }.padding(.vertical, 11)
                            Divider()
                        }
                        Text(L10n.tr(entry.closingKey)).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 16)
                    } else {
                        Text(L10n.tr("Release notes aren’t available for this build."))
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 22)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.top, 28)
                    .padding(.bottom, 20)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 1
                } action: { _, more in
                    moreBelow = more
                }
                // A soft edge over the last visible lines shows the list goes on.
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(
                            colors: [.black, .black.opacity(moreBelow ? 0 : 1)], startPoint: .top, endPoint: .bottom
                        ).frame(height: 32)
                    }
                }
                .aboutCLILeafBounds("release-notes-scroll")
            Divider()
            HStack {
                Spacer()
                Button(L10n.tr("Close"), action: close).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("release-notes-close").aboutCLILeafBounds("release-notes-close")
            }.padding(.horizontal, 28).padding(.vertical, 14)
        }.frame(width: 540, height: 470)
    }
}

extension View {
    @ViewBuilder func aboutCLILeafBounds(_ id: String) -> some View {
        #if YULLO_TESTING
            background(AboutCLILeafBoundsProbe(id: id))
        #else
            self
        #endif
    }
}

#if YULLO_TESTING
    private struct AboutCLILeafBoundsProbe: NSViewRepresentable {
        final class Probe: NSView {
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
        let id: String
        func makeNSView(context: Context) -> NSView {
            let view = Probe()
            view.identifier = NSUserInterfaceItemIdentifier("about-cli-bounds-" + id)
            return view
        }
        func updateNSView(_ view: NSView, context: Context) {}
    }
#endif
