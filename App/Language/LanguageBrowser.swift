import SwiftUI
import Translation

enum AppleLanguageSupport: Equatable {
    case checking, supported, unsupported, unknown

    var help: String {
        switch self {
        case .checking: return L10n.tr("Checking Apple translation support…")
        case .supported: return L10n.tr("Supported by Apple translation. The language pair may need a download.")
        case .unsupported: return L10n.tr("Not available with Apple translation in Yullo.")
        case .unknown: return L10n.tr("Couldn’t check Apple translation support.")
        }
    }
}

// Support comes from Translation's current catalog, not voice availability or a
// fixed language list. Region variants can share assets; script variants cannot.
enum LanguageBrowserContent {
    // Overlay scrollers occupy the trailing edge of the viewport. Keep the
    // row's small add/remove control outside that transient hit-test area.
    static let trailingControlInset: CGFloat = 24
    static func name(for language: Language, localized: Bool, locale: Locale = L10n.locale) -> String {
        // Locale's identifier display preserves script distinctions that a
        // language-code-only name would lose (zh-Hans versus zh-Hant).
        if localized {
            return language.displayName(localized: true, locale: locale)
        }
        return language.id == "zh" ? "简体中文" : language.name
    }

    static func appleSupport(for language: Language, supported: [Locale.Language]?) -> AppleLanguageSupport {
        guard let supported else { return .checking }
        guard !supported.isEmpty else { return .unknown }
        let requested = Locale.Language(identifier: language.id == "zh" ? "zh-Hans" : language.id)
        return supported.contains { candidate in
            canonicalAppleCode(candidate) == canonicalAppleCode(requested) && candidate.script == requested.script
        } ? .supported : .unsupported
    }

    private static func canonicalAppleCode(_ language: Locale.Language) -> String? {
        guard let code = language.languageCode?.identifier else { return nil }
        // Mandarin's explicit BCP-47 code is not Cantonese (yue). In particular,
        // zh-Hant-HK is a Chinese script/region, not proof of Cantonese support.
        return code == "cmn" ? "zh" : Language.canonicalCode(code)
    }

    static func appleDownloadLanguages(favorites: [String], supported: [Locale.Language]?) -> [Language] {
        let eligible = Language.catalog.filter {
            $0.appleCode != nil && appleSupport(for: $0, supported: supported) == .supported
        }
        let lookup = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })
        var seen = Set<String>()
        return (favorites.compactMap { lookup[Language.canonicalCode($0)] } + eligible)
            .filter { seen.insert($0.id).inserted }
    }

    static func normalizedAppleDownloadPair(
        source: String, target: String, languages: [Language]
    ) -> (source: String, target: String) {
        guard languages.count >= 2 else { return (source, target) }
        let contains = { id in languages.contains { $0.id == id } }
        let from = contains(source) ? source : (languages.first { $0.id != target }?.id ?? source)
        let to = contains(target) && target != from ? target : (languages.first { $0.id != from }?.id ?? target)
        return (from, to)
    }

    static func allowsAppleDownload(source: String, target: String, languages: [Language]) -> Bool {
        source != target && languages.contains { $0.id == source } && languages.contains { $0.id == target }
    }

    static func appleDownloadHelp(supported: [Locale.Language]?, languages: [Language]) -> String? {
        guard let supported else { return AppleLanguageSupport.checking.help }
        guard !supported.isEmpty else { return AppleLanguageSupport.unknown.help }
        guard languages.count >= 2 else {
            return L10n.tr(
                "This language pair isn’t available with Apple. Choose another translation service in Settings.")
        }
        return nil
    }

    // Return in the browser's search: the first match not yet chosen is added.
    static func addingFirstMatch(query: String, localizedNames: Bool, to selected: [String]) -> [String] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return selected }
        let chosen = Set(Language.enabled(selected).map(\.id))
        guard let next = matches(query: query, localizedNames: localizedNames).first(where: { !chosen.contains($0.id) })
        else { return selected }
        return toggling(next, in: selected)
    }
    static func matches(query: String, locale: Locale = L10n.locale, localizedNames: Bool = false) -> [Language] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let matches =
            terms.isEmpty
            ? Language.catalog
            : Language.catalog.filter { language in
                let searchable = [
                    language.name, language.subtitle, language.id, language.locale,
                    name(for: language, localized: false), name(for: language, localized: true, locale: locale)
                ].joined(separator: " ")
                return terms.allSatisfy { searchable.localizedStandardContains($0) }
            }
        // Alphabetical by the name shown, in either naming mode. Your languages
        // keep their own order.
        return Language.sorted(matches, locale: locale) { name(for: $0, localized: localizedNames, locale: locale) }
    }

    // The list with one language moved to a position; an unknown language changes nothing.
    static func moving(_ id: String, to index: Int, in selected: [String]) -> [String] {
        var ids = Language.enabled(selected).map(\.id)
        guard let from = ids.firstIndex(of: id) else { return ids }
        ids.remove(at: from)
        ids.insert(id, at: min(max(index, 0), ids.count))
        return ids
    }

    static func toggling(_ language: Language, in selected: [String]) -> [String] {
        var ids = Language.enabled(selected).map(\.id)
        if ids.contains(language.id) {
            if ids.count > 1 { ids.removeAll { $0 == language.id } }
        } else {
            ids.append(language.id)
        }
        return ids
    }
}

// Your languages: every From and To menu lists them in this order, and the top ones
// lead suggestions, so the order is the preference and can be changed here.
struct LanguageSettingsSection: View {
    @Binding var selected: [String]
    @Binding var showLocalizedNames: Bool
    let supportedAppleLanguages: [Locale.Language]?
    var showPresentationOptions = true
    @State private var browsing = false
    @State private var dragging: String?

    var body: some View {
        let languages = Language.enabled(selected)
        VStack(alignment: .leading, spacing: 8) {
            SettingsSection(L10n.tr("Your languages")) {
                SettingsRows {
                    ForEach(Array(languages.enumerated()), id: \.element.id) { index, language in
                        LanguageBrowserRow(
                            language: language, selected: $selected, showLocalizedNames: showLocalizedNames,
                            supportedAppleLanguages: supportedAppleLanguages, compact: true,
                            showsDragHandle: languages.count > 1
                        )
                        .contentShape(Rectangle())
                        .onDrag {
                            dragging = language.id
                            return NSItemProvider(object: language.id as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: LanguageOrderDropDelegate(
                                target: language.id, selected: $selected, dragging: $dragging)
                        )
                        .contextMenu { moveCommands(language, at: index, of: languages.count) }
                        .accessibilityActions { moveCommands(language, at: index, of: languages.count) }
                        .settingsRowOwnsTrailing()
                    }
                    if showPresentationOptions {
                        Toggle(L10n.tr("Names in English"), isOn: $showLocalizedNames)
                            .accessibilityIdentifier("localized-language-names")
                            .id("language-presentation")
                    }
                    HStack(spacing: 12) {
                        Button(L10n.tr("Add language…")) { browsing = true }
                            .accessibilityIdentifier("browse-languages")
                        Button(L10n.tr("Reset to defaults")) { selected = Language.systemDefaultIDs }
                            .disabled(languages.map(\.id) == Language.enabled(Language.systemDefaultIDs).map(\.id))
                    }
                }
            }
            if languages.count > 1 {
                Text(L10n.tr("From and To menus follow this order, and suggestions start at the top."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            appleLanguageLegend.font(.system(size: 11))
        }
        .sheet(isPresented: $browsing) {
            LanguageBrowserView(
                selected: $selected, showLocalizedNames: $showLocalizedNames,
                supportedAppleLanguages: supportedAppleLanguages
            ).glassSheet()
        }
    }

    @ViewBuilder private func moveCommands(_ language: Language, at index: Int, of count: Int) -> some View {
        Button(L10n.tr("Move to top")) { move(language, to: 0) }.disabled(index == 0)
        Button(L10n.tr("Move up")) { move(language, to: index - 1) }.disabled(index == 0)
        Button(L10n.tr("Move down")) { move(language, to: index + 1) }.disabled(index >= count - 1)
    }

    private func move(_ language: Language, to index: Int) {
        selected = LanguageBrowserContent.moving(language.id, to: index, in: selected)
    }
}

// Rows move as the dragged language passes over them, like a list.
private struct LanguageOrderDropDelegate: DropDelegate {
    let target: String
    @Binding var selected: [String]
    @Binding var dragging: String?

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }
    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
            let index = Language.enabled(selected).firstIndex(where: { $0.id == target })
        else { return }
        withAnimation(.smooth(duration: 0.18)) {
            selected = LanguageBrowserContent.moving(dragging, to: index, in: selected)
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

struct LanguageBrowserView: View {
    @Binding var selected: [String]
    @Binding var showLocalizedNames: Bool
    let supportedAppleLanguages: [Locale.Language]?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.tr("Languages")).font(.system(size: 20, weight: .semibold))
                Spacer()
                Button(L10n.tr("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Toggle(L10n.tr("Names in English"), isOn: $showLocalizedNames)
                .font(.system(size: 12)).accessibilityIdentifier("localized-language-names")
            SearchCapsule(prompt: L10n.tr("Search languages"), text: $query, focus: $searchFocused)
                // ↩ adds the first language found that isn't yours yet; it never removes one.
                .onSubmit {
                    selected = LanguageBrowserContent.addingFirstMatch(
                        query: query, localizedNames: showLocalizedNames, to: selected)
                }
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    let matches = LanguageBrowserContent.matches(query: query, localizedNames: showLocalizedNames)
                    if matches.isEmpty {
                        Text(L10n.tr("No languages found.")).font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 20)
                    }
                    ForEach(matches) { language in
                        LanguageBrowserRow(
                            language: language, selected: $selected, showLocalizedNames: showLocalizedNames,
                            supportedAppleLanguages: supportedAppleLanguages)
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, LanguageBrowserContent.trailingControlInset)
                    .smallNativeScrollbars()
            }.scrollIndicators(.visible).frame(maxWidth: .infinity, maxHeight: .infinity)
            appleLanguageLegend
        }.padding(22)
            .frame(minWidth: 440, idealWidth: 520, maxWidth: 660, minHeight: 360, idealHeight: 500, maxHeight: 650)
            .environment(\.locale, L10n.locale)
            // Opened, it is ready to type a language's name.
            .onAppear { DispatchQueue.main.async { searchFocused = true } }
    }
}

private struct LanguageBrowserRow: View {
    let language: Language
    @Binding var selected: [String]
    let showLocalizedNames: Bool
    let supportedAppleLanguages: [Locale.Language]?
    // In a Settings card the card's rows set the height.
    var compact = false
    // In Your languages with two or more, a quiet handle shows the row can be dragged.
    var showsDragHandle = false
    private var isSelected: Bool { Language.enabled(selected).contains { $0.id == language.id } }
    private var canRemove: Bool { Language.enabled(selected).count > 1 }
    private var support: AppleLanguageSupport {
        LanguageBrowserContent.appleSupport(for: language, supported: supportedAppleLanguages)
    }
    private var name: String { LanguageBrowserContent.name(for: language, localized: showLocalizedNames) }

    var body: some View {
        HStack(spacing: 12) {
            Text(name).font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(support.help).accessibilityHint(support.help)
            if support == .supported {
                Image(systemName: "apple.logo").font(.system(size: 11)).foregroundStyle(.secondary)
                    .help(support.help).accessibilityHidden(true)
            }
            Button {
                selected = LanguageBrowserContent.toggling(language, in: selected)
            } label: {
                // In a Settings card the remove control matches Dictation and Refine.
                if compact {
                    Image(systemName: "minus.circle").foregroundStyle(.secondary)
                        .frame(width: SettingsOutputColumns.remove, height: 18).contentShape(Rectangle())
                } else {
                    Image(systemName: isSelected ? "minus" : "plus").font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
            }.buttonStyle(.borderless)
                .disabled(isSelected && !canRemove)
                .accessibilityLabel(L10n.format(isSelected ? "Remove %@" : "Add %@", name))
                .help(L10n.format(isSelected ? "Remove %@" : "Add %@", name))
                .background {
                    #if YULLO_TESTING
                        TrailingControlGeometryProbe(controlID: "language-" + language.id)
                    #endif
                }
            if showsDragHandle {
                Image(systemName: "line.3.horizontal").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
                    .pointerStyle(.grabIdle).accessibilityHidden(true)
            }
        }.padding(.vertical, compact ? 0 : 8)
    }
}

#if YULLO_TESTING
    // Measures actual trailing-control frames in isolated native layout checks.
    // It never participates in hit testing and is absent from release builds.
    struct TrailingControlGeometryProbe: NSViewRepresentable {
        final class ProbeView: NSView {
            var controlID = ""
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
        let controlID: String
        func makeNSView(context: Context) -> ProbeView { ProbeView(frame: .zero) }
        func updateNSView(_ view: ProbeView, context: Context) { view.controlID = controlID }
    }
#endif

private var appleLanguageLegend: some View {
    HStack(alignment: .firstTextBaseline, spacing: 5) {
        Image(systemName: "apple.logo").font(.system(size: 11)).accessibilityHidden(true)
        Text(L10n.tr("Apple translation support. Language pairs may need a download."))
            .fixedSize(horizontal: false, vertical: true)
    }.font(.system(size: 11)).foregroundStyle(.secondary)
}

// The one search field: Settings, the language browser, More languages and the
// model catalog. A capsule with its glass, a clear button once typed, and a
// click anywhere on it focuses the field. Submit and arrow keys attach outside.
struct SearchCapsule: View {
    let prompt: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var fill = AnyShapeStyle(.quaternary.opacity(0.55))
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).focused(focus)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).accessibilityLabel(L10n.tr("Clear search"))
            }
        }.font(.system(size: 13)).padding(9)
            .background(fill, in: Capsule())
            .contentShape(Rectangle()).onTapGesture { focus.wrappedValue = true }
    }
}
