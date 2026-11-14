import AppKit
import UniformTypeIdentifiers
import Carbon
import SwiftUI

// The saved API key's state from the window's one silent check, and how to allow it.
// Every engine row reads it, so one engine shows one status on every page.
struct EngineKeyAccess {
    var state: CredentialAccessState? = nil
    var working = false
    var allow: () -> Void = {}
}
// Allow online: the explicit switch a paused task's row offers.
struct AllowOnline {
    var allow: (() -> Void)? = nil
}
extension EnvironmentValues {
    @Entry var allowOnline = AllowOnline()
    @Entry var engineKeyAccess = EngineKeyAccess()
    // Opens a writing service's setup from a sheet (Settings › Services).
    @Entry var setUpWritingService = WritingServiceSetUp()
}

// Under an engine that cannot run yet: why, and its one fix, in the grammar of a
// recognizer's "Not downloaded · Download" line.
struct WritingServiceSetUp {
    var open: ((String) -> Void)?
}

struct EngineStatusLine: View {
    let engine: String
    let preferences: Preferences
    let setUp: (String) -> Void
    // When the pop-up above already reads "Not set up", the line shows only its fix,
    // or the reason a chosen output needs it ("Email needs a writing service.").
    var popUpSaysNotSetUp = false
    var reason: String? = nil
    @Environment(\.engineKeyAccess) private var access
    // On this Mac only, an online engine's key isn't the problem; the
    // page's single blocker line says what is.
    private var blockedOnThisMac: Bool {
        preferences.processingPolicy == .onDeviceOnly
            && (engine == "api" || engine == "cli"
                || (engine == "ollama" && !CoreOllama.isOnThisMac(host: preferences.ollamaHost)))
    }
    var body: some View {
        if blockedOnThisMac {
            EmptyView()
        } else {
            status
        }
    }
    @ViewBuilder private var status: some View {
        switch GuidedEngineReadiness.resolve(engine: engine, preferences: preferences, keyState: access.state) {
        case .ready:
            EmptyView()
        case .needsKeyAccess:
            line(L10n.tr("Needs access"), L10n.tr("Allow access…"), action: access.allow)
        case .needsSetup(let anchor):
            line(
                anchor == "api" && access.state == .noSavedKey
                    ? L10n.tr("No saved key") : popUpSaysNotSetUp ? reason ?? "" : L10n.tr("Not set up"),
                L10n.tr("Set up…"), action: { setUp(anchor) })
        }
    }
    private func line(_ status: String, _ title: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(status).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(title, action: action).buttonStyle(.link).disabled(access.working)
        }.font(.system(size: 11)).accessibilityElement(children: .contain)
    }
}

// Under a task whose chosen service is online while Yullo works on this
// Mac only: the choice is kept and paused; one click allows online.
struct PausedLine: View {
    @Environment(\.allowOnline) private var allowOnline
    var body: some View {
        HStack(spacing: 8) {
            Text(L10n.tr("Paused until online is allowed"))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let allow = allowOnline.allow {
                Button(L10n.tr("Allow online"), action: allow).buttonStyle(.link)
                    .accessibilityIdentifier("allow-online")
            }
        }.font(.system(size: 11)).accessibilityElement(children: .contain)
            .accessibilityIdentifier("paused-until-online")
    }
}

// Shared Settings controls for task pages: the output pair ([Format] in
// [Language]), a row's own key, and the shared engines (Translate with, Write
// with). Every picker writes only the value it names.

// Label left (with an optional short caption), controls right.
struct SettingsTaskRow<Trailing: View>: View {
    let title: String
    var caption: String? = nil
    // A row whose controls are wide (an output pair) puts them under its name
    // when both don't fit, instead of squeezing the name.
    var stacksWhenNarrow = false
    // A remove button: last on a single line, beside the name when stacked.
    var accessory: AnyView? = nil
    // An app's icon before its name.
    var icon: NSImage? = nil
    @ViewBuilder var trailing: () -> Trailing
    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18).accessibilityHidden(true)
                }
                Text(title).fixedSize(horizontal: stacksWhenNarrow, vertical: false)
            }
            if let caption {
                Text(caption).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    var body: some View {
        Group {
            if stacksWhenNarrow {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 10) {
                        label
                        Spacer(minLength: 10)
                        trailing()
                        accessory
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            label
                            Spacer(minLength: 0)
                            accessory
                        }
                        HStack(spacing: 6) {
                            Spacer(minLength: 0)
                            trailing()
                        }
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    label.frame(maxWidth: .infinity, alignment: .leading)
                    trailing()
                }
            }
        }.font(.system(size: 13))
    }
}

// One size for every key box (Refine, Dictation, General), so their edges align.
enum SettingsKeyBox {
    static let width: CGFloat = 88
    static let height: CGFloat = 24
    // A long key name ("⌃⇧Leertaste") widens its own box with 10 pt sides; boxes never go below the shared width.
    static func width(for shortcut: Shortcut) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        let label = NSAttributedString(string: shortcut.displayLabel, attributes: [.font: font])
        return max(width, ceil(label.size().width) + 20)
    }
}

extension EnvironmentValues {
    // One decision per card: all output rows inline, or all stacked.
    @Entry var outputRowsStacked = false
}
extension View {
    // A card of output rows measures itself once and stacks every row when the widest name doesn't fit.
    func outputRowsFit(labels: [(title: String, icon: Bool)]) -> some View {
        modifier(OutputRowsFit(labels: labels))
    }
}
private struct OutputRowsFit: ViewModifier {
    let labels: [(title: String, icon: Bool)]
    @State private var width: CGFloat = 0
    private var needed: CGFloat {
        let font = NSFont.systemFont(ofSize: 13)
        let widest =
            labels.map { ($0.title as NSString).size(withAttributes: [.font: font]).width + ($0.icon ? 24 : 0) }
            .max() ?? 0
        return ceil(widest) + 12 + SettingsOutputColumns.pair + SettingsOutputColumns.removeInset
    }
    func body(content: Content) -> some View {
        content.environment(\.outputRowsStacked, width > 0 && needed > width)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                width = $0
            }
    }
}

enum OutputSettingsPresentation {
    // The word a key suggestion is taken from.
    static func keyWord(_ output: CoreOutput, preferences: Preferences) -> String {
        if output.isSpoken {
            return output.language.map { OutputPresentation.languageTitle($0) } ?? L10n.tr("What I say")
        }
        return OutputPresentation.formatTitle(output.format, presets: preferences.dictationPresets)
    }
    // A row's own key. Voice translation keeps its original saved key.
    static func key(_ id: String, in draft: Binding<Preferences>) -> Binding<Shortcut> {
        if id == CoreOutputSettings.voiceTranslationShortcutID { return draft.voiceTranslationShortcut }
        return Binding(
            get: { draft.wrappedValue.outputShortcutKeys[id] ?? .unassigned },
            set: { value in
                // Edit with voice and Edit with text remember a removed key, so its default never returns.
                if value.isAssigned || Shortcut.rememberedIDs.contains(id) {
                    draft.wrappedValue.outputShortcutKeys[id] = value
                } else {
                    draft.wrappedValue.outputShortcutKeys.removeValue(forKey: id)
                }
            })
    }
    // Bindings found by row identity, so removing a row never leaves a stale index.
    static func rule(_ id: UUID, in draft: Binding<Preferences>) -> Binding<CoreOutputRule>? {
        guard let initial = draft.wrappedValue.outputs.rules.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { draft.wrappedValue.outputs.rules.first { $0.id == id } ?? initial },
            set: { value in
                guard let index = draft.wrappedValue.outputs.rules.firstIndex(where: { $0.id == id }) else { return }
                draft.wrappedValue.outputs.rules[index] = value
            })
    }
    static func output(
        _ id: String, in draft: Binding<Preferences>, rows: WritableKeyPath<CoreOutputSettings, [CoreOutputShortcut]>
    ) -> Binding<CoreOutput> {
        let initial = draft.wrappedValue.outputs[keyPath: rows].first { $0.id == id }?.output ?? .spoken
        return Binding(
            get: { draft.wrappedValue.outputs[keyPath: rows].first { $0.id == id }?.output ?? initial },
            set: { value in
                guard let index = draft.wrappedValue.outputs[keyPath: rows].firstIndex(where: { $0.id == id }) else {
                    return
                }
                draft.wrappedValue.outputs[keyPath: rows][index].output = value
            })
    }
    static func newRowID(_ prefix: String) -> String {
        prefix + "-" + UUID().uuidString.prefix(8).lowercased()
    }
}

// An empty key box suggests ⌃⇧ plus the first free letter of the row's name.
// Nothing is saved until the person accepts it.
enum OutputShortcutSuggestion {
    static let prefix = UInt32(controlKey | shiftKey)
    static func shortcut(for name: String, taken: [Shortcut]) -> Shortcut? {
        let letters = Set(
            taken.filter { $0.isAssigned && $0.modifiers == prefix }.compactMap {
                ShortcutKeyboardLayout.character(key: $0.key, modifiers: 0)?.uppercased().first
            })
        guard let letter = CoreShortcutSuggestion.letter(for: name, taken: letters),
            let key = ShortcutKeyboardLayout.keyCode(for: String(letter).lowercased(), modifiers: prefix)
        else { return nil }
        var value = Shortcut(key: key, modifiers: prefix, label: "")
        value.label = value.displayLabel
        return taken.contains(where: { $0.conflicts(value) }) ? nil : value
    }
}

struct OutputKeyBox: View {
    @Binding var shortcut: Shortcut
    let name: String
    let taken: [Shortcut]
    var body: some View {
        ShortcutRecorder(
            shortcut: $shortcut, actionName: name,
            suggestion: shortcut.isAssigned ? nil : OutputShortcutSuggestion.shortcut(for: name, taken: taken)
        ).frame(width: SettingsKeyBox.width(for: shortcut), height: SettingsKeyBox.height)
    }
}

struct OutputFormatPicker: View {
    @Binding var format: String
    @Binding var preferences: Preferences
    var allowsSpoken = true
    @State private var sheet: YourFormatsRoute?
    private var presets: CoreDictationPresetsConfiguration { preferences.dictationPresets }
    private var own: [CoreDictationPresetRecord] { YourFormats.records(presets) }
    private var listed: [String] {
        OutputPresentation.formatGroups.flatMap { $0 } + own.map { CoreOutput.preset($0.id).format }
    }
    // New format… and Edit formats… are items of the menu; neither changes the row by itself.
    private var selection: Binding<String> {
        Binding(
            get: { format },
            set: { value in
                switch value {
                case YourFormats.newTag:
                    sheet = .new
                case YourFormats.editTag: sheet = .list
                default: format = value
                }
            })
    }
    var body: some View {
        Picker(L10n.tr("Format"), selection: selection) {
            if !listed.contains(format) || (!allowsSpoken && format == CoreOutput.spoken.format) {
                Text(OutputPresentation.formatTitle(format, presets: presets)).tag(format)
            }
            ForEach(Array(OutputPresentation.formatGroups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(group.filter { allowsSpoken || $0 != CoreOutput.spoken.format }, id: \.self) { value in
                    Text(OutputPresentation.formatTitle(value, presets: presets)).tag(value)
                }
            }
            if !own.isEmpty {
                Divider()
                ForEach(own, id: \.id) { record in
                    Text(DictationPresetPresentation.title(record)).tag(CoreOutput.preset(record.id).format)
                }
            }
            Divider()
            Text(L10n.tr("New format…")).tag(YourFormats.newTag)
            if !own.isEmpty { Text(L10n.tr("Edit formats…")).tag(YourFormats.editTag) }
        }.labelsHidden().pickerStyle(.menu).settingsControlWidth(SettingsOutputColumns.popup)
            .accessibilityLabel(L10n.tr("Format"))
            .sheet(item: $sheet) { route in
                YourFormatsSheet(
                    preferences: $preferences, start: route, allowsSpoken: allowsSpoken,
                    chosen: { format = $0 }, close: { sheet = nil }
                ).glassSheet()
            }
    }
}

struct OutputLanguagePicker: View {
    @Binding var language: String?
    @Binding var yourLanguages: [String]
    var localizedNames = true
    @State private var browsing = false
    private static let moreTag = "__more-languages__"
    private var selection: Binding<String> {
        Binding(
            get: { language ?? "" },
            set: { value in
                if value == Self.moreTag {
                    browsing = true
                } else {
                    language = value.isEmpty ? nil : value
                }
            })
    }
    var body: some View {
        let yours = Language.enabled(yourLanguages)
        // With one language, it is what Same as I speak already writes.
        let own = yours.count > 1 ? yours : []
        Picker(L10n.tr("Language"), selection: selection) {
            Text(L10n.tr("Same as I speak")).tag("")
            if let language, !own.contains(where: { $0.id == language }) {
                Text(OutputPresentation.languageTitle(language, localized: localizedNames)).tag(language)
            }
            if !own.isEmpty { Divider() }
            ForEach(own) { Text($0.displayName(localized: localizedNames, locale: L10n.locale)).tag($0.id) }
            Divider()
            Text(L10n.tr("More languages…")).tag(Self.moreTag)
        }.labelsHidden().pickerStyle(.menu).settingsControlWidth(SettingsOutputColumns.popup)
            .accessibilityLabel(L10n.tr("Language"))
            .sheet(isPresented: $browsing) {
                MoreLanguagesSheet(
                    localizedNames: localizedNames, excluded: yours.map(\.id),
                    choose: { id, add in
                        language = id
                        if add, !yourLanguages.contains(id) { yourLanguages.append(id) }
                        browsing = false
                    }, cancel: { browsing = false }
                ).glassSheet()
            }
    }
}

// What the More languages sheet would choose as the search changes: the first
// match, unless the person moved to another row (↓, ↑ or a click) that still
// matches. Nothing searched or nothing found chooses nothing.
struct LanguagePick: Equatable {
    var selected: String?
    var moved = false
    mutating func update(query: String, matches: [String]) {
        if moved, let selected, matches.contains(selected) { return }
        moved = false
        selected = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : matches.first
    }
    mutating func move(_ step: Int, matches: [String]) {
        guard !matches.isEmpty else { return }
        let index =
            selected.flatMap { matches.firstIndex(of: $0) }.map { $0 + step } ?? (step > 0 ? 0 : matches.count - 1)
        selected = matches[min(max(index, 0), matches.count - 1)]
        moved = true
    }
    mutating func pick(_ id: String?) {
        selected = id
        moved = id != nil
    }
}

// Every language, searchable. Picking one sets only the row it came from; the
// tick also adds it to your languages. Opened, it is ready to type; ↩ chooses.
struct MoreLanguagesSheet: View {
    let localizedNames: Bool
    let excluded: [String]
    let choose: (String, Bool) -> Void
    let cancel: () -> Void
    // Off where choosing always adds the language, as in the guide's Your languages.
    var offersAdding = true
    @State private var query = ""
    @State private var pick = LanguagePick()
    @State private var addToYours = false
    @State private var chosen = false
    @FocusState private var searchFocused: Bool
    private var matches: [Language] {
        // Shown alphabetically; found by the native, English or interface-language name.
        Language.sorted(
            LanguageBrowserContent.matches(query: query, locale: L10n.locale).filter { !excluded.contains($0.id) },
            localized: localizedNames, locale: L10n.locale)
    }
    private func commit() {
        guard !chosen, let selected = pick.selected, matches.contains(where: { $0.id == selected }) else { return }
        chosen = true
        choose(selected, addToYours)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("More languages")).font(.system(size: 17, weight: .semibold))
            SearchCapsule(prompt: L10n.tr("Search languages"), text: $query, focus: $searchFocused)
                .onSubmit(commit)
                .onKeyPress(.downArrow) {
                    pick.move(1, matches: matches.map(\.id))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    pick.move(-1, matches: matches.map(\.id))
                    return .handled
                }
            List(matches, selection: Binding(get: { pick.selected }, set: { pick.pick($0) })) { language in
                Text(language.displayName(localized: localizedNames, locale: L10n.locale)).tag(language.id)
            }.frame(minHeight: 220)
            if offersAdding {
                Toggle(L10n.tr("Also add it to your languages"), isOn: $addToYours).toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button(L10n.tr("Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(L10n.tr("Choose"), action: commit)
                    .keyboardShortcut(.defaultAction).disabled(pick.selected == nil)
            }
        }.font(.system(size: 13)).padding(20).frame(width: 360, height: 420)
            .onChange(of: query) { _, value in pick.update(query: value, matches: matches.map(\.id)) }
            .onAppear { DispatchQueue.main.async { searchFocused = true } }
    }
}

// [Format] in [Language], writing exactly the output it names.
struct OutputPairControl: View {
    @Binding var output: CoreOutput
    @Binding var draft: Preferences
    var allowsSpoken = true
    private var format: some View {
        OutputFormatPicker(format: $output.format, preferences: $draft, allowsSpoken: allowsSpoken)
    }
    // "Email in French"; with Same as I speak the format stands alone.
    private var connector: some View {
        // Kept invisible for Same as I speak, so every row's pop-ups line up.
        Text(L10n.tr("in")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            .frame(width: SettingsOutputColumns.connector)
            .opacity(output.language == nil ? 0 : 1).accessibilityHidden(output.language == nil)
    }
    private var language: some View {
        OutputLanguagePicker(
            language: $output.language, yourLanguages: $draft.enabledLanguages,
            localizedNames: draft.showLocalizedLanguageNames)
    }
    var body: some View {
        HStack(spacing: 4) {
            format
            connector
            language
        }.fixedSize()
    }
}

// One row for every output: a name on the left, the [Format] in [Language]
// pair on the right, then a fixed slot for remove. The card decides once whether
// its rows are inline or stacked (pair under the name), so every row matches.
struct OutputRow<Leading: View>: View {
    let pair: OutputPairControl
    var removeName: String? = nil
    var remove: (() -> Void)? = nil
    @ViewBuilder var leading: () -> Leading
    @Environment(\.outputRowsStacked) private var stacked
    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        leading()
                        Spacer(minLength: 4)
                        OutputRemoveSlot(name: removeName, remove: remove)
                    }
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        pair
                    }.padding(.trailing, SettingsOutputColumns.removeInset)
                }
            } else {
                HStack(spacing: 12) {
                    leading().frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        pair
                        OutputRemoveSlot(name: removeName, remove: remove)
                    }
                }
            }
        }.font(.system(size: 13))
    }
}

// A row started by its own key: the pair it writes on the left, the key on the
// trailing column shared with the card's other keys, then remove.
struct OutputKeyRow: View {
    let pair: OutputPairControl
    let key: OutputKeyBox
    var removeName: String? = nil
    var remove: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 12) {
            pair
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                key
                OutputRemoveSlot(name: removeName, remove: remove)
            }
        }.font(.system(size: 13))
    }
}

// The remove control, or the same empty width, so every row keeps one trailing column.
struct OutputRemoveSlot: View {
    var name: String? = nil
    var remove: (() -> Void)? = nil
    var body: some View {
        Group {
            if let remove { OutputRemoveButton(name: name ?? "", action: remove) } else { Color.clear }
        }.frame(width: SettingsOutputColumns.remove, height: 18)
    }
}

// A name with an app's icon, for the left of an output row.
struct OutputRowLabel: View {
    let title: String
    var icon: NSImage? = nil
    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18).accessibilityHidden(true) }
            Text(title).lineLimit(1)
        }
    }
}

struct OutputRemoveButton: View {
    let name: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }.buttonStyle(.plain).accessibilityLabel(L10n.format("Remove %@", name)).help(L10n.tr("Remove"))
    }
}

// Format, then Language, then a key with a suggestion. Cancel changes nothing.
struct OutputShortcutAddSheet: View {
    let title: String
    let preferencesSnapshot: Preferences
    // Your formats are saved as you make them; only the row waits for Add.
    @Binding var formats: Preferences
    let taken: [Shortcut]
    var allowsSpoken = true
    let add: (CoreOutput, Shortcut, [String]) -> Void
    let cancel: () -> Void
    @State private var draft: Preferences
    @State private var output: CoreOutput
    @State private var shortcut = Shortcut.unassigned
    init(
        title: String, preferences: Binding<Preferences>, initial: CoreOutput, taken: [Shortcut],
        allowsSpoken: Bool = true,
        add: @escaping (CoreOutput, Shortcut, [String]) -> Void, cancel: @escaping () -> Void
    ) {
        self.title = title
        preferencesSnapshot = preferences.wrappedValue
        _formats = preferences
        self.taken = taken
        self.allowsSpoken = allowsSpoken
        self.add = add
        self.cancel = cancel
        _draft = State(initialValue: preferences.wrappedValue)
        _output = State(initialValue: initial)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 17, weight: .semibold))
            SettingsTaskRow(title: L10n.tr("Format")) {
                OutputFormatPicker(format: $output.format, preferences: $formats, allowsSpoken: allowsSpoken)
            }
            SettingsTaskRow(title: L10n.tr("Language")) {
                OutputLanguagePicker(
                    language: $output.language, yourLanguages: $draft.enabledLanguages,
                    localizedNames: draft.showLocalizedLanguageNames)
            }
            SettingsTaskRow(title: L10n.tr("Shortcut")) {
                OutputKeyBox(
                    shortcut: $shortcut, name: OutputSettingsPresentation.keyWord(output, preferences: formats),
                    taken: taken)
            }
            if taken.contains(where: { $0.conflicts(shortcut) }) {
                Text(L10n.tr("Choose a different shortcut for each action.")).font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(L10n.tr("Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(L10n.tr("Add")) { add(output, shortcut, draft.enabledLanguages) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(taken.contains(where: { $0.conflicts(shortcut) }))
            }
        }.padding(20).frame(width: 420)
    }
}

// Claude Code and Codex CLI found on this Mac, offered by name in Write with and
// Translate with while no command-line tool is set up. Finding them runs only
// --version/--help; choosing one fills in its path and a suggested model.
@MainActor final class InstalledCLIs: ObservableObject {
    #if YULLO_TESTING
        static var shared = InstalledCLIs(find: { [] })
    #else
        static let shared = InstalledCLIs()
    #endif
    static let tagPrefix = "__cli-installed__:"
    // One order everywhere, sheet and menus: Claude Code, then Codex CLI.
    static let order: [CLIProvider] = [.claude, .codex]
    @Published private(set) var setups: [CLIConfiguration] = []
    // Signed in (true), not (false) or unknown (missing), per installed tool.
    @Published private(set) var signedIn: [CLIProvider: Bool] = [:]
    // Whether a look has finished, so "not installed" is said only after looking.
    @Published private(set) var looked = false
    private var finding: Task<Void, Never>?
    private let find: @Sendable () async -> [CLIConfiguration]
    private let status: @Sendable (CLIConfiguration) async -> Bool?
    init(
        find: @escaping @Sendable () async -> [CLIConfiguration] = { await CLIClient.shared.installedSetups() },
        status: @escaping @Sendable (CLIConfiguration) async -> Bool? = { await CLIClient.shared.signInStatus($0) }
    ) {
        self.find = find
        self.status = status
    }
    // Supported tools not found on this Mac, once Yullo has looked.
    var missing: [CLIProvider] {
        looked ? Self.order.filter { provider in !setups.contains { $0.provider == provider } } : []
    }
    // Again, from scratch: after an install or a sign-in in Terminal, when Yullo comes back.
    func rescan(_ preferences: Preferences) async {
        guard Self.wanted(preferences) else { return }
        await finding?.value
        finding = nil
        await refresh(preferences)
    }
    // Once per launch, and again when Yullo returns to the front with none found yet.
    func refresh(_ preferences: Preferences) async {
        guard Self.wanted(preferences) else { return }
        if finding == nil {
            let find = self.find
            let status = self.status
            finding = Task { @MainActor in
                let found = await find()
                var signed: [CLIProvider: Bool] = [:]
                for setup in found { if let value = await status(setup) { signed[setup.provider] = value } }
                self.setups = found.sorted {
                    (Self.order.firstIndex(of: $0.provider) ?? 9) < (Self.order.firstIndex(of: $1.provider) ?? 9)
                }
                self.signedIn = signed
                self.looked = true
                if found.isEmpty { self.finding = nil }
            }
        }
        await finding?.value
    }
    // Every installed tool other than the one in use, as it was last set up when Yullo remembers it.
    func offers(_ preferences: Preferences) -> [CLIConfiguration] {
        guard Self.wanted(preferences) else { return [] }
        let current = ServiceChoices.configured("cli", preferences) ? preferences.cli.provider : nil
        return setups.filter { $0.provider != current }.map { found in
            guard let saved = preferences.rememberedCLIs.first(where: { $0.provider == found.provider }) else {
                return found
            }
            var value = found
            if FileManager.default.isExecutableFile(atPath: saved.executablePath) {
                value.executablePath = saved.executablePath
            }
            if !saved.model.isEmpty { value.model = saved.model }
            value.preferLowEffort = saved.preferLowEffort
            return value
        }
    }
    // Named for what runs: the tool and its model.
    static func title(_ setup: CLIConfiguration) -> String {
        let model = setup.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return setup.provider.displayName + (model.isEmpty ? "" : " · " + model)
    }
    func setup(for tag: String) -> CLIConfiguration? { setups.first { Self.tag($0) == tag } }
    static func tag(_ setup: CLIConfiguration) -> String { tagPrefix + setup.provider.rawValue }
    // Command-line tools are looked for wherever Yullo may use one, set up or not.
    private static func wanted(_ preferences: Preferences) -> Bool {
        preferences.processingPolicy == .standard
    }
    // The one choice: the tool, its path and model, and the task now uses it.
    static func choose(_ setup: CLIConfiguration, writing: Bool, in preferences: Preferences) -> Preferences {
        var value = preferences
        // The tool being left keeps its own path and model for a later switch back.
        if ServiceChoices.configured("cli", preferences), preferences.cli.provider != setup.provider {
            value.rememberedCLIs.removeAll { $0.provider == preferences.cli.provider }
            value.rememberedCLIs.append(preferences.cli)
        }
        value.rememberedCLIs.removeAll { $0.provider == setup.provider }
        value.cli = setup
        if writing { value.voiceRefinementEngine = "cli" } else { value.engine = "cli" }
        return value
    }
}

// Write with: one value shared by Refine, Dictation and Translation.
enum WritingServicePresentation {
    static func title(_ engine: String, preferences: Preferences) -> String {
        switch engine {
        case "apple": return L10n.tr("Apple Foundation Model")
        case "ollama":
            return preferences.ollamaModel.isEmpty ? "Ollama" : "Ollama · " + preferences.ollamaModel
        // Named for what actually runs: the API's model, the command-line app and its model.
        case "api":
            // The model's own name, without its provider prefix ("openai/gpt-oss-120b" → "gpt-oss-120b").
            let model =
                preferences.model.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "/").last.map(String.init) ?? ""
            return model.isEmpty ? L10n.tr("API connection") : L10n.format("%@ · API", model)
        case "cli":
            let model = preferences.cli.model.trimmingCharacters(in: .whitespacesAndNewlines)
            return preferences.cli.provider.displayName + (model.isEmpty ? "" : " · " + model)
        default: return L10n.tr("Choose a service")
        }
    }
    // Services that would write now, without setup.
    @MainActor static func ready(_ preferences: Preferences) -> [String] {
        (AppleWriterStatus.availability() == .available ? ["apple"] : []) + others(preferences)
    }
    // Ready writers other than Apple's: what "If it fails, use" offers.
    static func others(_ preferences: Preferences) -> [String] {
        ["ollama", "api", "cli"].filter { engine in
            var value = preferences
            value.voiceRefinementEngine = engine
            return VoiceWritingConnection.isSetUp(value)
        }
    }
}

struct WriteWithRow: View {
    @Binding var draft: Preferences
    // What the writer is for on this page and where else the same setting applies.
    var caption: String? = nil
    // Dictation only: the chosen format that needs a writer, named in one line while none is ready
    // ("Email needs a writing service."). Other pages show "Not set up" in the pop-up alone.
    var needs: String? = nil
    // Opens the Services page at an anchor ("ollama", "api", "cli", "text-services").
    let openServices: (String) -> Void
    // What writes when Apple's model can't; Settings shows it, the guide leaves it there.
    var showsFallback = true
    @ObservedObject var installedTools = InstalledCLIs.shared
    @State private var choosing = false
    // Set by a "Choose a writing service…" fix elsewhere: the chooser opens with the row.
    static var opensChooser = false
    private static let chooseTag = "__choose-writer__"
    private static let modelsTag = "__get-more-models__"
    // Set up, wherever Yullo works; on this Mac only, choosing it allows online.
    private var ready: Bool { VoiceWritingConnection.isSetUp(draft) }
    private var needsLine: String? { needs.map { L10n.format("%@ needs a writing service.", $0) } }
    private var selection: Binding<String> {
        Binding(
            get: { draft.voiceRefinementEngine },
            set: { value in
                switch value {
                case Self.chooseTag: choosing = true
                case Self.modelsTag: openServices("ollama")
                case let tag where tag.hasPrefix(InstalledCLIs.tagPrefix):
                    if let setup = installedTools.setup(for: tag) {
                        draft = InstalledCLIs.choose(setup, writing: true, in: draft)
                    }
                default: draft.voiceRefinementEngine = value
                }
            })
    }
    // Apple · on device where it can never run here: listed, not choosable, with the reason.
    @ViewBuilder private func choice(_ engine: String) -> some View {
        let availability = AppleWriterStatus.availability()
        if engine == "apple", draft.voiceRefinementEngine != "apple", !availability.canBecomeReady {
            VStack(alignment: .leading) {
                Text(WritingServicePresentation.title(engine, preferences: draft))
                Text(AppleWriterPresentation.status(availability) ?? "")
            }.tag(engine).disabled(true)
        } else {
            Text(WritingServicePresentation.title(engine, preferences: draft)).tag(engine)
        }
    }
    var body: some View {
        writer
        // Apple's model can't run everywhere; what writes instead is the person's choice.
        if showsFallback, draft.voiceRefinementEngine == "apple" { AppleWriterFallbackRow(draft: $draft) }
    }
    private var writer: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsTaskRow(title: L10n.tr("Write with"), caption: caption) {
                Picker(L10n.tr("Write with"), selection: selection) {
                    if ready {
                        ForEach(ServiceChoices.writing(draft), id: \.self) { engine in
                            choice(engine)
                        }
                    } else {
                        Text(L10n.tr("Not set up")).tag(draft.voiceRefinementEngine)
                        ForEach(WritingServicePresentation.ready(draft), id: \.self) { engine in
                            Text(WritingServicePresentation.title(engine, preferences: draft)).tag(engine)
                        }
                    }
                    ForEach(installedTools.offers(draft), id: \.provider) { setup in
                        Text(InstalledCLIs.title(setup)).tag(InstalledCLIs.tag(setup))
                    }
                    Divider()
                    Text(L10n.tr("Choose a writing service…")).tag(Self.chooseTag)
                    // It opens Ollama's models, so it says so.
                    Text(L10n.tr("Get Ollama models…")).tag(Self.modelsTag)
                }.labelsHidden().pickerStyle(.menu).settingsControlWidth()
                    .accessibilityLabel(L10n.tr("Write with"))
                    .accessibilityIdentifier("writing-service-picker")
            }
            if draft.voiceRefinementEngine == "apple" {
                AppleWriterStatusLine(choose: { choosing = true })
            } else if ready || draft.voiceRefinementEngine == "api" {
                EngineStatusLine(
                    engine: draft.voiceRefinementEngine, preferences: draft, setUp: openServices,
                    popUpSaysNotSetUp: !ready, reason: needsLine)
            }
            if draft.pausedTasks.contains(.writing) { PausedLine() }
            // Without a status line, the reason stands alone.
            if !ready, draft.voiceRefinementEngine != "api", let needs {
                Text(L10n.format("%@ needs a writing service.", needs)).font(.system(size: 11))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.id("writing-service")
            .onAppear {
                guard Self.opensChooser else { return }
                Self.opensChooser = false
                choosing = true
            }
            .sheet(isPresented: $choosing) {
                WritingServiceChooser(
                    draft: $draft, installed: installedTools,
                    setUp: { anchor in
                        choosing = false
                        openServices(anchor)
                    }, close: { choosing = false }
                ).glassSheet()
            }
            .background {
                #if YULLO_TESTING
                    YulloActionPresentationProbe(
                        title: "writing-service-picker",
                        value: installedTools.offers(draft).map(InstalledCLIs.title).joined(separator: ","),
                        action: {
                            if let setup = installedTools.offers(draft).first {
                                selection.wrappedValue = InstalledCLIs.tag(setup)
                            }
                        })
                #endif
            }
            .installedCLIs(installedTools, draft)
    }
}

// Under Write with while it is Apple's model: one line, the remark when it can
// write, or why it can't and its one fix. It is checked each time it shows and
// whenever Yullo comes back to the front.
struct AppleWriterStatusLine: View {
    let choose: () -> Void
    @State private var availability = AppleWriterStatus.availability()
    var body: some View {
        Group {
            if availability == .available {
                Text(L10n.tr("Runs on this Mac"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.9)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let status = AppleWriterPresentation.status(availability) {
                HStack(spacing: 8) {
                    Text(status).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    switch availability {
                    case .intelligenceOff:
                        Button(L10n.tr("Open Settings…")) {
                            NSWorkspace.shared.open(AppleWriterPresentation.settingsURL)
                        }
                        .buttonStyle(.link)
                    case .modelNotReady: EmptyView()
                    default: Button(L10n.tr("Choose another…"), action: choose).buttonStyle(.link)
                    }
                }.font(.system(size: 11)).accessibilityElement(children: .contain)
                    .accessibilityIdentifier("apple-writer-status")
            }
        }
        .appleAvailability($availability)
    }
}

extension View {
    // Looks for installed command-line tools when a row shows and Yullo returns to the front.
    func installedCLIs(_ installed: InstalledCLIs, _ draft: Preferences) -> some View {
        task(id: ServiceChoices.configured("cli", draft)) { await installed.refresh(draft) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await installed.refresh(draft) }
            }
    }
    // Apple's model state, read when shown and when Yullo comes back to the front (after
    // turning Apple Intelligence on), and every few seconds while its model downloads.
    func appleAvailability(_ availability: Binding<CoreAppleWriterAvailability>) -> some View {
        onAppear { availability.wrappedValue = AppleWriterStatus.availability() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                availability.wrappedValue = AppleWriterStatus.availability()
            }
            .task(id: availability.wrappedValue) {
                while availability.wrappedValue == .modelNotReady, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    availability.wrappedValue = AppleWriterStatus.availability()
                }
            }
    }
}

// Settings › Services: Apple's model beside the models on this Mac. It needs no
// setup; its state reads as under Write with, with a button only when there is a fix.
struct AppleModelServiceRow: View {
    @State private var availability = AppleWriterStatus.availability()
    var body: some View {
        SettingsTaskRow(
            title: L10n.tr("Apple Foundation Model"),
            caption: AppleWriterPresentation.status(availability) ?? L10n.tr("Ready")
        ) {
            if availability == .intelligenceOff {
                Button(L10n.tr("Open Settings…")) { NSWorkspace.shared.open(AppleWriterPresentation.settingsURL) }
            }
        }
        .appleAvailability($availability)
    }
}

// "If it fails, use": a ready writer, or Nothing, which shows the reason instead.
struct AppleWriterFallbackRow: View {
    @Binding var draft: Preferences
    private var choices: [String] {
        let ready = WritingServicePresentation.others(draft)
        let saved = draft.appleWriterFallback
        return saved.isEmpty || ready.contains(saved) ? ready : ready + [saved]
    }
    var body: some View {
        SettingsTaskRow(title: L10n.tr("If it fails, use")) {
            Picker(L10n.tr("If it fails, use"), selection: $draft.appleWriterFallback) {
                Text(L10n.tr("None")).tag("")
                ForEach(choices, id: \.self) { engine in
                    Text(WritingServicePresentation.title(engine, preferences: draft)).tag(engine)
                }
            }.labelsHidden().pickerStyle(.menu).settingsControlWidth()
                .accessibilityIdentifier("apple-writer-fallback")
        }.id("apple-writer-fallback")
    }
}

// "Choose a writing service": the three kinds of writer, with what each needs.
// A ready one is used in one click, which sets Write with and returns to the page
// it was opened from; Cancel returns without a change.
// What the writing-service sheet does outside itself; checks pass their own.
@MainActor struct WritingServiceSetupEffects {
    var copy: (String) -> Void
    // Opens Terminal on the tool's fixed sign-in command; false if Terminal can't open.
    var signIn: (CLIProvider) -> Bool
    // The key goes where Settings keeps it: Keychain, under the API's address.
    var saveKey: (_ key: String, _ endpoint: String) throws -> Void
    var testAPI: (_ endpoint: String, _ model: String, _ key: String) async throws -> String
    static let live = WritingServiceSetupEffects(
        copy: { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        },
        signIn: { provider in
            // A fixed command in a script of its own, opened by the person's Terminal.
            let command = CLISetupCommand(rawValue: provider.rawValue)?.command ?? ""
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(
                "yullo-sign-in-\(provider.rawValue).command")
            guard !command.isEmpty, (try? Data("#!/bin/zsh -l\n\(command)\n".utf8).write(to: file)) != nil,
                (try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)) != nil,
                let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            else { return false }
            NSWorkspace.shared.open(
                [file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            return true
        },
        saveKey: { key, endpoint in try KeyStore.write(key, endpoint: APIClient.endpoint(endpoint).absoluteString) },
        testAPI: { endpoint, model, key in
            let config = try APIConnectionSettings(endpoint: endpoint, model: model)
            let sample = ConnectionTestSample.current
            let text = try await APIClient().translate(
                endpoint: config.endpoint, model: config.model, key: key, text: sample.text, source: sample.source,
                target: sample.target, useCache: false)
            return sample.result(String(text.prefix(120)))
        })
}

struct WritingServiceChooser: View {
    @Binding var draft: Preferences
    // Observed, so a tool found while the sheet is open appears in it.
    @ObservedObject var installed = InstalledCLIs.shared
    let setUp: (String) -> Void
    let close: () -> Void
    // Ollama's state on this Mac; checks pass their own answer.
    var ollamaStatus: @MainActor (String) async -> OllamaClient.Status = { await OllamaClient.shared.status(host: $0) }
    var effects = WritingServiceSetupEffects.live
    // Checks open the API form already filled: address, model and key.
    var apiPrefill: (url: String, model: String, key: String)? = nil
    // In the guide: the same rows in its own card, without the sheet's title and Cancel,
    // only the kinds it lists (nil: all), and none that can never run on this Mac.
    var inline = false
    var shown: Set<String>? = nil
    var opensAPIForm = false
    // Set up here, in place: the API's form opens under its row.
    @State private var apiOpen = false
    @State private var apiURL = ""
    @State private var apiModel = ""
    @State private var apiKey = ""
    @State private var apiStatus: String?
    @State private var apiTesting = false
    @State private var copied: CLIProvider?
    @State private var signingIn: CLIProvider?
    // Ollama is one click where it can be: open it, or add the suggested model,
    // which then becomes the writer, as the click asked.
    @State private var ollama: OllamaClient.Status?
    @State private var refresh = 0
    @State private var adding: String?
    @State private var progress: Double?
    @State private var issue: String?
    @State private var addTask: Task<Void, Never>?
    private let suggestion = OllamaSuggestion.model()
    private struct Kind: Identifiable {
        let engine: String
        let title: String
        let anchor: String
        var id: String { engine }
    }
    private var kinds: [Kind] {
        [
            .init(engine: "apple", title: L10n.tr("Apple Foundation Model"), anchor: ""),
            .init(engine: "ollama", title: L10n.tr("Ollama on this Mac"), anchor: "ollama"),
            .init(engine: "api", title: L10n.tr("Online service (API)"), anchor: "api"),
            .init(engine: "cli", title: L10n.tr("Command-line tool"), anchor: "cli")
        ]
    }
    var body: some View {
        let ready = WritingServicePresentation.ready(draft)
        VStack(alignment: .leading, spacing: 14) {
            if !inline {
                Text(L10n.tr("Choose a writing service")).font(.system(size: 17, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(
                    kinds.filter {
                        ($0.engine != "cli" || (cliRows.isEmpty && installed.missing.isEmpty))
                            && (shown?.contains($0.engine) ?? true)
                            && !(inline && $0.engine == "apple" && !apple.canBecomeReady)
                    }
                ) { kind in
                    SettingsTaskRow(
                        title: kind.title,
                        caption: caption(kind.engine, ready: ready)
                    ) {
                        if ready.contains(kind.engine) || (kind.engine == "apple" && apple.canBecomeReady) {
                            Button(L10n.tr("Use")) { use(kind.engine) }
                        } else if kind.engine == "apple" {
                            if apple == .intelligenceOff {
                                Button(L10n.tr("Open Settings…")) {
                                    NSWorkspace.shared.open(AppleWriterPresentation.settingsURL)
                                }
                            }
                        } else if kind.engine == "ollama" {
                            ollamaAction
                        } else if kind.engine == "api" {
                            // Opens and closes the form below; the chevron says which.
                            Button {
                                apiOpen.toggle()
                            } label: {
                                HStack(spacing: 5) {
                                    Text(L10n.tr("Set up…"))
                                    Image(systemName: apiOpen ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                            }
                            .accessibilityIdentifier("writing-service-api-set-up")
                            .background {
                                #if YULLO_TESTING
                                    YulloActionPresentationProbe(
                                        title: "writing-service-api-set-up", action: { apiOpen.toggle() })
                                #endif
                            }
                        } else {
                            Button(L10n.tr("Set up…")) { setUp(kind.anchor) }
                        }
                    }.foregroundStyle(kind.engine == "apple" && !apple.canBecomeReady ? .tertiary : .primary)
                    if kind.engine == "ollama", let adding {
                        OllamaAddProgress(name: adding, progress: progress, cancel: cancelAdd)
                    }
                    if kind.engine == "api", apiOpen, !ready.contains("api") { apiForm }
                }
                // Command-line tools in one fixed order, each as it stands: in use or ready,
                // signed out, or not installed, so no row moves as its state changes.
                ForEach(shown?.contains("cli") ?? true ? InstalledCLIs.order : [], id: \.self) { provider in
                    if let setup = cliRows.first(where: { $0.provider == provider }) {
                        toolRow(setup)
                    } else if installed.missing.contains(provider) {
                        installRow(provider)
                    }
                }
                if let issue {
                    Text(issue).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(12).settingsCard()
            if !inline {
                HStack {
                    Spacer()
                    Button(L10n.tr("Cancel")) {
                        cancelAdd()
                        close()
                    }.keyboardShortcut(.cancelAction)
                }
            }
        }.padding(inline ? 0 : 20).frame(width: inline ? nil : 440)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refresh += 1
                // Back from Terminal: an install or a sign-in shows at once.
                let current = draft
                Task { await installed.rescan(current) }
            }
            .task { await installed.refresh(draft) }
            .onAppear {
                if opensAPIForm { apiOpen = true }
                if let apiPrefill {
                    (apiURL, apiModel, apiKey) = apiPrefill
                    apiOpen = true
                }
            }
            .task(id: refresh) {
                let host = draft.ollamaHost
                let value = await ollamaStatus(host)
                guard !Task.isCancelled else { return }
                ollama = value
            }
            .onDisappear { cancelAdd() }
    }
    private var apple: CoreAppleWriterAvailability { AppleWriterStatus.availability() }
    @ViewBuilder private func toolRow(_ setup: CLIConfiguration) -> some View {
        // Titled by the tool itself; the kind and its model below.
        let signed = installed.signedIn[setup.provider]
        SettingsTaskRow(
            title: setup.provider.displayName,
            caption: signed == false
                ? L10n.tr(signingIn == setup.provider ? "Finish signing in in Terminal." : "Not signed in")
                : [L10n.tr("Command-line tool"), setup.model.trimmingCharacters(in: .whitespaces)]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
        ) {
            // Signed out, the one fix is to sign in; unknown, signing in sits beside Use.
            if signed == false {
                Button(L10n.tr("Sign in…")) { signIn(setup.provider) }
                    .accessibilityIdentifier("writing-service-sign-in-" + setup.provider.rawValue)
                    .background {
                        #if YULLO_TESTING
                            YulloActionPresentationProbe(
                                title: "writing-service-sign-in-" + setup.provider.rawValue,
                                action: { signIn(setup.provider) })
                        #endif
                    }
            } else if signed == nil {
                Button(L10n.tr("Sign in…")) { signIn(setup.provider) }.buttonStyle(.link)
                    .accessibilityIdentifier("writing-service-sign-in-" + setup.provider.rawValue)
            }
            if signed == false {
                EmptyView()
            } else if setup.provider == draft.cli.provider, ServiceChoices.configured("cli", draft) {
                if draft.voiceRefinementEngine == "cli" {
                    Label(L10n.tr("In use"), systemImage: "checkmark").foregroundStyle(.secondary)
                        .font(.system(size: 12))
                } else {
                    Button(L10n.tr("Use")) { use("cli") }
                }
            } else {
                Button(L10n.tr("Use")) {
                    draft = InstalledCLIs.choose(setup, writing: true, in: draft)
                    close()
                }
            }
        }.accessibilityIdentifier("writing-service-cli-" + setup.provider.rawValue)
    }
    @ViewBuilder private func installRow(_ provider: CLIProvider) -> some View {
        let setup = CLISetupCommand(rawValue: provider.rawValue)
        SettingsTaskRow(title: provider.displayName, caption: L10n.tr("Not installed")) {
            Button {
                effects.copy(setup?.install ?? "")
                copied = provider
            } label: {
                // The app's usual confirmation: the same button, a checkmark for a moment.
                if copied == provider {
                    Label(L10n.tr("Copied"), systemImage: "checkmark")
                } else {
                    Text(L10n.tr("Copy command"))
                }
            }.accessibilityIdentifier("writing-service-copy-" + provider.rawValue)
                .task(id: copied) {
                    guard copied == provider else { return }
                    try? await Task.sleep(for: .seconds(1.5))
                    if copied == provider { copied = nil }
                }
                .background {
                    #if YULLO_TESTING
                        YulloActionPresentationProbe(
                            title: "writing-service-copy-" + provider.rawValue,
                            action: {
                                effects.copy(setup?.install ?? "")
                                copied = provider
                            })
                    #endif
                }
        }
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(setup?.install ?? "").font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let guide = setup?.guide {
                Link(L10n.tr("Learn more"), destination: guide).font(.system(size: 11))
            }
        }
    }

    // The API's address, model and key, as Settings asks for them; Test, then Use.
    private var apiForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            apiField("API URL") {
                TextField(
                    L10n.tr("API URL"), text: $apiURL,
                    prompt: Self.placeholder(Text(verbatim: "https://your-provider.example/v1")))
            }
            apiField("Model ID") {
                TextField(
                    L10n.tr("Model ID"), text: $apiModel,
                    prompt: Self.placeholder(Text(L10n.tr("Exact model name from your provider"))))
            }
            apiField("API key") {
                SecureField(
                    L10n.tr("API key"), text: $apiKey, prompt: Self.placeholder(Text(L10n.tr("Paste your key"))))
            }
            HStack(spacing: 12) {
                if apiTesting { ProgressView().controlSize(.small) }
                if let apiStatus {
                    Text(apiStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(L10n.tr("Test")) { testAPI() }.disabled(!apiComplete || apiTesting)
                    .accessibilityIdentifier("writing-service-api-test")
                    .background {
                        #if YULLO_TESTING
                            YulloActionPresentationProbe(title: "writing-service-api-test", action: testAPI)
                        #endif
                    }
                Button(L10n.tr("Use")) { useAPI() }.disabled(!apiComplete || apiTesting)
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("writing-service-api-use")
                    .background {
                        #if YULLO_TESTING
                            YulloActionPresentationProbe(title: "writing-service-api-use", action: useAPI)
                        #endif
                    }
            }
        }.font(.system(size: 13)).padding(.leading, 2).accessibilityIdentifier("writing-service-api-form")
    }
    // A label above, as in Settings, over a field in Yullo's own input fill.
    private func apiField<Field: View>(_ title: String, @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr(title)).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            field().textFieldStyle(.plain).autocorrectionDisabled().labelsHidden()
                .padding(.horizontal, 9).frame(height: 28)
                // One even fill across the field, in light and dark.
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
    // A placeholder in the placeholder colour, so an empty form never reads as filled.
    private static func placeholder(_ text: Text) -> Text {
        text.foregroundColor(Color(nsColor: .placeholderTextColor))
    }
    private var apiComplete: Bool {
        ![apiURL, apiModel, apiKey].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private func testAPI() {
        let url = apiURL, model = apiModel, key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        apiTesting = true
        apiStatus = nil
        Task { @MainActor in
            do {
                apiStatus = try await effects.testAPI(url, model, key)
            } catch {
                apiStatus =
                    error is APIError
                    ? error.localizedDescription : L10n.tr("Couldn’t connect. Check the URL, network and model.")
            }
            apiTesting = false
        }
    }
    private func useAPI() {
        do {
            let config = try APIConnectionSettings(endpoint: apiURL, model: apiModel)
            try effects.saveKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), config.endpoint)
            apiKey = ""
            draft.endpoint = config.endpoint
            draft.model = config.model
            use("api")
        } catch {
            apiStatus = error.localizedDescription
        }
    }
    private func signIn(_ provider: CLIProvider) {
        if effects.signIn(provider) {
            signingIn = provider
        } else {
            issue = L10n.tr("Couldn’t open Terminal. Open it from Applications → Utilities.")
        }
    }
    // The tool set up now, if any, then the other installed ones.
    private var cliRows: [CLIConfiguration] {
        (ServiceChoices.configured("cli", draft) ? [draft.cli] : []) + installed.offers(draft)
    }
    private func caption(_ engine: String, ready: [String]) -> String {
        if engine == "apple" { return AppleWriterPresentation.status(apple) ?? L10n.tr("Ready") }
        // Ollama with a model it can use now names it, beside its Use button.
        if engine == "ollama", !ready.contains(engine), case .running(let models) = ollama, let first = models.first {
            return first.name
        }
        return ready.contains(engine)
            ? WritingServicePresentation.title(engine, preferences: draft) : L10n.tr("Not set up")
    }
    @ViewBuilder private var ollamaAction: some View {
        switch ollama {
        case nil: ProgressView().controlSize(.small)
        case .notInstalled:
            Button(L10n.tr("Get Ollama…")) { NSWorkspace.shared.open(OllamaSuggestion.website) }
        case .notRunning:
            Button(L10n.tr("Open Ollama")) { OllamaSuggestion.openApp(host: draft.ollamaHost) { refresh += 1 } }
        case .running(let models):
            if let first = models.first?.name {
                // The row's caption names the model.
                Button(L10n.tr("Use")) {
                    draft.ollamaModel = first
                    use("ollama")
                }
            } else {
                Button(L10n.format("Add %@ · %@", suggestion.name, suggestion.size)) { add(suggestion.name) }
                    .disabled(adding != nil)
            }
        }
    }
    private func use(_ engine: String) {
        draft.voiceRefinementEngine = engine
        close()
    }
    private func add(_ name: String) {
        guard adding == nil else { return }
        adding = name
        progress = nil
        issue = nil
        let host = draft.ollamaHost
        addTask = Task { @MainActor in
            do {
                try await OllamaClient.shared.pull(model: name, host: host) { value in
                    Task { @MainActor in if adding == name { progress = value } }
                }
                guard !Task.isCancelled, adding == name else { return }
                adding = nil
                // The click asked for this writer: it is set once the model is ready.
                draft.ollamaModel = name
                use("ollama")
            } catch {
                guard !Task.isCancelled, adding == name else { return }
                adding = nil
                issue = error.localizedDescription
            }
        }
    }
    private func cancelAdd() {
        addTask?.cancel()
        addTask = nil
        adding = nil
    }
}

// Translate with: one value shared by Translation and dictation into another language.
struct TranslateWithRow: View {
    @Binding var draft: Preferences
    @ObservedObject var models: VoiceModelStore
    // What the translator is for on this page and where else the same setting applies.
    var caption: String? = nil
    let openServices: (String) -> Void
    @ObservedObject var installedTools = InstalledCLIs.shared
    // The chosen model's ratings under the row (Translation page).
    var showsDetails = true
    // With one language the translator is only for text in others.
    static func caption(oneLanguage: Bool) -> String {
        L10n.tr(oneLanguage ? "For text in other languages." : "For Translation and dictation in another language.")
    }
    private static let setUpTag = "__set-up-translator__"
    private static let ollamaTag = "__set-up-ollama__"
    private static let modelsTag = "__get-more-models__"
    // Each installed translation model is its own choice, named, so the menu says which one translates.
    private static let localPrefix = "local:"
    static func title(_ engine: String, preferences: Preferences) -> String {
        switch engine {
        case "apple": return L10n.tr("Apple · on device")
        case "local": return localTitle(preferences.localTranslationModelID)
        case "ollama", "api", "cli": return WritingServicePresentation.title(engine, preferences: preferences)
        default: return L10n.tr("Choose a service")
        }
    }
    static func localTitle(_ id: String, installed: [InstalledLocalModel] = []) -> String {
        installed.first { $0.id == id }?.name ?? ModelLibrary.catalog.first { $0.id == id }?.name
            ?? L10n.tr("Local model")
    }
    private var installed: [InstalledLocalModel] { models.installed.filter { $0.task == .translation } }
    private var selection: Binding<String> {
        Binding(
            get: { draft.engine == "local" ? Self.localPrefix + draft.localTranslationModelID : draft.engine },
            set: { value in
                switch value {
                case Self.setUpTag: openServices("text-services")
                case Self.modelsTag: openServices("models")
                case Self.ollamaTag: openServices("ollama")
                case let tag where tag.hasPrefix(InstalledCLIs.tagPrefix):
                    if let setup = installedTools.setup(for: tag) {
                        draft = InstalledCLIs.choose(setup, writing: false, in: draft)
                    }
                case let tag where tag.hasPrefix(Self.localPrefix):
                    draft.localTranslationModelID = String(tag.dropFirst(Self.localPrefix.count))
                    draft.engine = "local"
                default: draft.engine = value
                }
            })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsTaskRow(title: L10n.tr("Translate with"), caption: caption) {
                let choices = ServiceChoices.translation(draft, hasLocalModel: !installed.isEmpty)
                Picker(L10n.tr("Translate with"), selection: selection) {
                    if !["apple", "local", "ollama", "api", "cli"].contains(draft.engine) {
                        Text(L10n.tr("Choose a service")).tag(draft.engine)
                    }
                    ForEach(choices, id: \.self) { engine in
                        if engine == "local" {
                            // The saved model first if it is no longer installed, then every installed one.
                            if !installed.contains(where: { $0.id == draft.localTranslationModelID }),
                                draft.engine == "local"
                            {
                                Text(Self.localTitle(draft.localTranslationModelID))
                                    .tag(Self.localPrefix + draft.localTranslationModelID)
                            }
                            ForEach(installed) { model in
                                Text(model.name).tag(Self.localPrefix + model.id)
                            }
                        } else {
                            Text(Self.title(engine, preferences: draft)).tag(engine)
                        }
                    }
                    ForEach(installedTools.offers(draft), id: \.provider) { setup in
                        Text(InstalledCLIs.title(setup)).tag(InstalledCLIs.tag(setup))
                    }
                    Divider()
                    if draft.ollamaModel.isEmpty { Text(L10n.tr("Ollama · Set up…")).tag(Self.ollamaTag) }
                    Text(L10n.tr("Get more models…")).tag(Self.modelsTag)
                    Text(L10n.tr("Set up another service…")).tag(Self.setUpTag)
                }.labelsHidden().pickerStyle(.menu).settingsControlWidth()
                    .accessibilityLabel(L10n.tr("Translate with"))
                    .accessibilityIdentifier("translation-service-picker")
            }
            EngineStatusLine(engine: draft.engine, preferences: draft, setUp: openServices)
            if draft.pausedTasks.contains(.translation) { PausedLine() }
            if showsDetails, draft.engine == "local" {
                ModelRatingSummary(modelID: draft.localTranslationModelID, recommended: false)
            }
        }.id("translation-model")
            .background {
                #if YULLO_TESTING
                    YulloActionPresentationProbe(
                        title: "translation-manage-services", action: { openServices("text-services") })
                    YulloActionPresentationProbe(
                        title: "translation-installed-cli",
                        value: installedTools.offers(draft).map(InstalledCLIs.title).joined(separator: ","),
                        action: {
                            if let setup = installedTools.offers(draft).first {
                                selection.wrappedValue = InstalledCLIs.tag(setup)
                            }
                        })
                #endif
            }
            .task { await models.refresh() }
            .installedCLIs(installedTools, draft)
    }
}

// The name that closes Email and Formal letter when no sign-off was spoken; one home, in Personalization.
struct SignLettersRow: View {
    @Binding var draft: Preferences
    var caption: String? = nil
    var body: some View {
        SettingsTaskRow(title: L10n.tr("Sign letters as"), caption: caption) {
            TextField(
                L10n.tr("Your name"),
                text: Binding(
                    get: { draft.signOffName },
                    set: { draft.signOffName = String($0.prefix(CoreWritingRequirements.maximumSignOffNameCharacters)) }
                )
            ).textFieldStyle(.roundedBorder).settingsControlWidth()
                .accessibilityLabel(L10n.tr("Sign letters as")).accessibilityIdentifier("sign-off-name")
        }.id("sign-off-name")
    }
}

// Apps for "+ Add app…": the running apps first, then any app on this Mac.
@MainActor enum OutputAppChooser {
    struct App: Identifiable, Equatable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }
    static func running(excluding: Set<String>) -> [App] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app -> App? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != own,
                !excluding.contains(id.lowercased()), seen.insert(id).inserted
            else { return nil }
            return App(bundleID: id, name: app.localizedName ?? id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static var websiteIcon: NSImage {
        NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage()
    }
    static func icon(_ rule: CoreOutputRule) -> NSImage {
        rule.website == nil ? icon(rule.applicationBundleID) : websiteIcon
    }
    // The app's own icon, or the generic app icon when it isn't on this Mac.
    static func icon(_ bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
    static func other() -> App? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L10n.tr("Choose")
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url),
            let id = bundle.bundleIdentifier
        else { return nil }
        let name =
            (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return App(bundleID: id, name: String(name.prefix(128)))
    }
}

// Dictation's keys and outputs: Start dictation with the rows that start with
// their own key (folded), then Everywhere else, one row per app, and the shared
// engines they need. The shortcuts fold is closed on every visit; search opens it.
struct DictationOutputsSettings: View {
    @Binding var draft: Preferences
    @ObservedObject var models: VoiceModelStore
    let taken: [Shortcut]
    let openServices: (String) -> Void
    var revealedSections: Set<SettingsVisibilitySection> = []
    @State private var adding = false
    @State private var shortcutsExpanded = false
    @State private var showsSuggestions = false
    @State private var suggestions: [OutputSuggestionGroup]?

    private var allOutputs: [CoreOutput] {
        [draft.outputs.everywhere] + draft.outputs.rules.map(\.output) + draft.outputs.dictationShortcuts.map(\.output)
    }
    private var firstWrittenFormat: CoreOutput? { allOutputs.first { !$0.isSpoken } }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            shortcuts
            whatItWrites
            sharedSections
        }
        .onAppear {
            if revealedSections.contains(.dictationShortcuts) { shortcutsExpanded = true }
            if revealedSections.contains(.dictationSuggestions) { showsSuggestions = true }
        }
        .onChange(of: revealedSections) { _, sections in
            if sections.contains(.dictationShortcuts) { shortcutsExpanded = true }
            if sections.contains(.dictationSuggestions) { showsSuggestions = true }
        }
        .sheet(isPresented: $adding) {
            OutputShortcutAddSheet(
                title: L10n.tr("Add dictation shortcut"), preferences: $draft,
                initial: .init(format: RewriteStyle.bullets.rawValue), taken: taken,
                add: { output, key, languages in
                    let id = OutputSettingsPresentation.newRowID("dictation")
                    draft.enabledLanguages = languages
                    draft.outputs.dictationShortcuts.append(.init(id: id, output: output))
                    if key.isAssigned { draft.outputShortcutKeys[id] = key }
                    shortcutsExpanded = true
                    adding = false
                }, cancel: { adding = false }
            ).glassSheet()
        }
    }
    private var whatItWrites: some View {
        SettingsSection(L10n.tr("What dictation writes")) {
            SettingsRows {
                OutputRow(pair: OutputPairControl(output: $draft.outputs.everywhere, draft: $draft)) {
                    OutputRowLabel(title: L10n.tr(draft.outputs.rules.isEmpty ? "Writes" : "Everywhere else"))
                }.settingsRowOwnsTrailing().settingsLanding("output", ownsTrailing: true).id("output-everywhere")
                ForEach(draft.outputs.rules) { rule in
                    if let binding = OutputSettingsPresentation.rule(rule.id, in: $draft) {
                        appRow(rule, binding: binding)
                    }
                }
                // The person's own rows come first; suggestions open in their own sheet,
                // on a line of their own when the three buttons don't fit.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        addButtons
                        if hasSuggestions {
                            Spacer(minLength: 12)
                            suggestionsButton
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) { addButtons }
                        if hasSuggestions { suggestionsButton }
                    }
                }
                QuickLanguagesRow(draft: $draft)
            }.outputRowsFit(
                labels: [(L10n.tr(draft.outputs.rules.isEmpty ? "Writes" : "Everywhere else"), false)]
                    + draft.outputs.rules.map { ($0.applicationName, true) })
        }.id("output")
            .onAppear { if suggestions == nil { suggestions = OutputSuggestionCatalog.installed() } }
            .sheet(isPresented: $showsSuggestions) {
                OutputSuggestionsSheet(
                    groups: suggestions ?? [], outputs: $draft.outputs, presets: draft.dictationPresets,
                    close: { showsSuggestions = false }
                ).glassSheet()
            }
    }
    @ViewBuilder private var addButtons: some View {
        addAppMenu
        AddWebsiteButton(add: addWebsite).fixedSize()
    }
    private var hasSuggestions: Bool { !(suggestions ?? []).isEmpty }
    private var suggestionsButton: some View {
        Button(L10n.tr("Suggestions…")) { showsSuggestions = true }
            .fixedSize().accessibilityIdentifier("output-suggestions").id("output-suggestions")
    }
    @ViewBuilder private func appRow(_ rule: CoreOutputRule, binding: Binding<CoreOutputRule>) -> some View {
        if rule.enabled {
            OutputRow(
                pair: OutputPairControl(output: binding.output, draft: $draft), removeName: rule.applicationName,
                remove: { draft.outputs.rules.removeAll { $0.id == rule.id } }
            ) {
                OutputRowLabel(title: rule.applicationName, icon: OutputAppChooser.icon(rule))
            }.settingsRowOwnsTrailing()
        } else {
            // A migrated rule that was paused stays visible and Off until turned on.
            SettingsTaskRow(title: rule.applicationName, icon: OutputAppChooser.icon(rule)) {
                Button(L10n.tr("Turn on")) { binding.wrappedValue.enabled = true }
                OutputRemoveSlot(name: rule.applicationName) {
                    draft.outputs.rules.removeAll { $0.id == rule.id }
                }
            }.settingsRowOwnsTrailing()
        }
    }
    // The translator and writer these outputs use, in the same Translator and Writer
    // sections as on Translation and Refine, shown only while a row needs them.
    @ViewBuilder private var sharedSections: some View {
        let translates = allOutputs.contains { $0.language != nil }
        if translates {
            SettingsSection(L10n.tr("Translator")) {
                SettingsRows {
                    TranslateWithRow(
                        draft: $draft, models: models,
                        caption: TranslateWithRow.caption(oneLanguage: draft.usesOneLanguage),
                        openServices: openServices)
                }
            }
        }
        if let writes = firstWrittenFormat {
            SettingsSection(L10n.tr("Writer")) {
                SettingsRows {
                    WriteWithRow(
                        draft: $draft, caption: L10n.tr("For Refine and formats like Email."),
                        needs: OutputPresentation.formatTitle(writes.format, presets: draft.dictationPresets),
                        openServices: openServices)
                }
            }
        }
    }
    private var addAppMenu: some View {
        Menu(L10n.tr("Add app…")) {
            let present = Set(
                draft.outputs.rules.filter { $0.website == nil }.map { $0.applicationBundleID.lowercased() })
            let running = OutputAppChooser.running(excluding: present)
            ForEach(running) { app in Button(app.name) { addRule(app) } }
            if !running.isEmpty { Divider() }
            Button(L10n.tr("Other…")) { if let app = OutputAppChooser.other() { addRule(app) } }
        }.menuStyle(.button).menuIndicator(.hidden).fixedSize().accessibilityIdentifier("output-add-app")
    }
    private func addWebsite(_ domain: String) {
        guard draft.outputs.rule(for: .website(domain)) == nil else { return }
        draft.outputs.rules.append(.website(domain, output: draft.outputs.everywhere))
    }
    private func addRule(_ app: OutputAppChooser.App) {
        guard draft.outputs.rule(forApplication: app.bundleID) == nil,
            !draft.outputs.rules.contains(where: {
                $0.applicationBundleID.caseInsensitiveCompare(app.bundleID) == .orderedSame
            })
        else { return }
        draft.outputs.rules.append(
            .init(applicationBundleID: app.bundleID, applicationName: app.name, output: draft.outputs.everywhere))
    }
    // The page title names the task, so this card needs no heading.
    private var shortcuts: some View {
        GroupBox {
            SettingsRows {
                SettingsTaskRow(title: L10n.tr("Start dictation")) {
                    ShortcutRecorder(shortcut: $draft.dictationShortcut, actionName: L10n.tr("Start dictation"))
                        .frame(width: SettingsKeyBox.width(for: draft.dictationShortcut), height: SettingsKeyBox.height)
                }.id("start-dictation")
                if draft.outputs.dictationShortcuts.isEmpty {
                    SettingsTaskRow(title: L10n.tr("More shortcuts")) { addShortcutButton }
                        .id("dictation-shortcuts")
                } else {
                    SettingsDisclosureRow(
                        title: L10n.tr("More shortcuts"), summary: "\(draft.outputs.dictationShortcuts.count)",
                        isExpanded: $shortcutsExpanded
                    ).id("dictation-shortcuts")
                    if shortcutsExpanded {
                        ForEach(draft.outputs.dictationShortcuts) { row in
                            OutputKeyRow(
                                pair: OutputPairControl(
                                    output: OutputSettingsPresentation.output(
                                        row.id, in: $draft, rows: \.dictationShortcuts),
                                    draft: $draft),
                                key: OutputKeyBox(
                                    shortcut: OutputSettingsPresentation.key(row.id, in: $draft),
                                    name: OutputSettingsPresentation.keyWord(row.output, preferences: draft),
                                    taken: taken),
                                removeName: OutputPresentation.name(row.output, preferences: draft),
                                remove: { remove(row) }
                            ).settingsRowOwnsTrailing().id(
                                row.id == CoreOutputSettings.voiceTranslationShortcutID
                                    ? "voice-translation-row" : row.id)
                        }
                        addShortcutButton
                    }
                }
            }
        }
    }
    private var addShortcutButton: some View {
        Button(L10n.tr("Add shortcut…")) { adding = true }
            .disabled(draft.outputs.dictationShortcuts.count >= CoreOutputSettings.maximumShortcuts)
            .accessibilityIdentifier("dictation-shortcut-add")
    }
    private func remove(_ row: CoreOutputShortcut) {
        draft.outputs.dictationShortcuts.removeAll { $0.id == row.id }
        if row.id == CoreOutputSettings.voiceTranslationShortcutID {
            draft.voiceTranslationShortcut = .unassigned
        } else {
            draft.outputShortcutKeys.removeValue(forKey: row.id)
        }
    }
}

// Refine in place: row 1 always, extra rows up to three. Rows never write What I say.
// Its rows sit in the Selected text card: a group label, then each row's output
// with its key on the card's key column.
struct RefineInPlaceSettings: View {
    @Binding var draft: Preferences
    let taken: [Shortcut]
    @State private var adding = false
    // The same value the review's Show Changes button flips.
    @AppStorage(ReviewDisplay.showsChangesKey, store: ReviewDisplay.store) private var showsChanges = false
    var body: some View {
        Text(L10n.tr("Refine in place")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .help(L10n.tr("⌘Z undoes it.")).accessibilityAddTraits(.isHeader).settingsGroupLabel()
        ForEach(Array(draft.outputs.refineInPlace.enumerated()), id: \.element.id) { index, row in
            OutputKeyRow(
                pair: OutputPairControl(
                    output: OutputSettingsPresentation.output(row.id, in: $draft, rows: \.refineInPlace),
                    draft: $draft, allowsSpoken: false),
                key: OutputKeyBox(
                    shortcut: OutputSettingsPresentation.key(row.id, in: $draft),
                    name: OutputSettingsPresentation.keyWord(row.output, preferences: draft), taken: taken),
                removeName: OutputPresentation.name(row.output, preferences: draft),
                remove: index == 0
                    ? nil
                    : {
                        draft.outputs.refineInPlace.removeAll { $0.id == row.id }
                        draft.outputShortcutKeys.removeValue(forKey: row.id)
                    }
            ).settingsRowOwnsTrailing().id(index == 0 ? "refine-in-place" : row.id)
        }
        if draft.outputs.refineInPlace.count < CoreOutputSettings.maximumRefineRows {
            Button(L10n.tr("Add another…")) { adding = true }.accessibilityIdentifier("refine-in-place-add")
                .sheet(isPresented: $adding) { addSheet }
        }  // Select text, press the key, say what to change; ⌘Z undoes it.
        HStack(spacing: 12) {
            Text(L10n.tr("Edit with voice")).lineLimit(1)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                OutputKeyBox(
                    shortcut: OutputSettingsPresentation.key(Shortcut.editWithVoiceID, in: $draft),
                    name: L10n.tr("Edit with voice"), taken: taken)
                OutputRemoveSlot()
            }
        }.font(.system(size: 13)).help(L10n.tr("⌘Z undoes it.")).settingsRowOwnsTrailing().id("edit-with-voice")
        // The same edit, with the request typed.
        HStack(spacing: 12) {
            Text(L10n.tr("Edit with text")).lineLimit(1)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                OutputKeyBox(
                    shortcut: OutputSettingsPresentation.key(Shortcut.editWithTextID, in: $draft),
                    name: L10n.tr("Edit with text"), taken: taken)
                OutputRemoveSlot()
            }
        }.font(.system(size: 13)).help(L10n.tr("⌘Z undoes it.")).settingsRowOwnsTrailing().id("edit-with-text")
        Toggle(L10n.tr("Review before replacing"), isOn: $draft.voiceEditReview)
            .accessibilityIdentifier("edit-with-voice-review").id("edit-review")
        // How the review shows a result; with no review, there is nothing to show it in.
        if draft.voiceEditReview {
            Toggle(isOn: $showsChanges) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("Show changes"))
                    // Two sentences, two lines: what it does, then its key.
                    Text(L10n.tr("Mark what changed in the review.") + "\n" + L10n.tr("Press ⇧⌘D there to switch."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.accessibilityIdentifier("edit-show-changes")
        }
    }
    private var addSheet: some View {
        OutputShortcutAddSheet(
            title: L10n.tr("Add Refine in place"), preferences: $draft,
            initial: .init(format: RewriteStyle.formal.rawValue), taken: taken, allowsSpoken: false,
            add: { output, key, languages in
                let id = OutputSettingsPresentation.newRowID("refine")
                draft.enabledLanguages = languages
                draft.outputs.refineInPlace.append(.init(id: id, output: output))
                if key.isAssigned { draft.outputShortcutKeys[id] = key }
                adding = false
            }, cancel: { adding = false }
        ).glassSheet()
    }
}
