import AppKit
import SwiftUI

// Names are presentation only; neither names nor record identities enter model requests.
enum DictationPresetPresentation {
    static func title(_ id: CoreDictationPresetID) -> String {
        L10n.tr(id == .technicalWriting ? "Technical writing" : "Message translation")
    }
    static func title(_ record: CoreDictationPresetRecord) -> String {
        record.name ?? record.templateID.map(title) ?? L10n.tr("Format")
    }
    // Where the active preset is shown: a scenario says so.
    static func activeTitle(_ record: CoreDictationPresetRecord) -> String {
        record.id.hasPrefix(DictationScenario.idPrefix)
            ? L10n.format("Temporary format: %@", title(record)) : title(record)
    }
    static func needsRepair(_ definition: CoreDictationPresetDefinition) -> Bool {
        if let mode = definition.mode, !["original", "translate", "refine"].contains(mode) { return true }
        if let target = definition.targetLanguage, !Language.catalog.contains(where: { $0.id == target }) {
            return true
        }
        if let style = definition.style, RewriteStyle(rawValue: style) == nil { return true }
        return false
    }
    static func currentFields(_ definition: CoreDictationPresetDefinition) -> CoreDictationPresetDefinition {
        switch definition.mode {
        case "original": return .init(mode: "original")
        case "translate": return .init(mode: "translate", targetLanguage: definition.targetLanguage)
        case "refine":
            return .init(
                mode: "refine", style: definition.style,
                preserveTechnicalLiterals: definition.preserveTechnicalLiterals)
        default: return definition
        }
    }
    static func summary(_ definition: CoreDictationPresetDefinition, localizedLanguageNames: Bool) -> String {
        guard !needsRepair(definition) else { return L10n.tr("Check this format’s settings.") }
        switch definition.mode {
        case "original": return L10n.tr("Original")
        case "translate":
            let language = definition.targetLanguage.flatMap { id in Language.catalog.first { $0.id == id } }
            return L10n.tr("Translate") + " · "
                + (language?.displayName(localized: localizedLanguageNames, locale: L10n.locale)
                    ?? L10n.tr("Use app or default"))
        case "refine":
            return L10n.tr("Refine") + " · "
                + (definition.style.flatMap(RewriteStyle.init(rawValue:)).map(WritingStylePresentation.title)
                    ?? L10n.tr("Use app or default"))
        default: return L10n.tr("Use app or default")
        }
    }
}

// The configured Writing service, offered for an explicit Describe or Preview.
struct PresetWritingAccess {
    var settings: TranslationSettings
    var defaultStyle: RewriteStyle
    init?(_ preferences: Preferences) {
        guard VoiceWritingConnection.isConfigured(preferences) else { return nil }
        settings = TranslationSettings(preferences, engine: preferences.voiceRefinementEngine)
        defaultStyle = RewriteStyle(rawValue: preferences.voiceRefinementStyle) ?? .professional
    }
}

struct PreviewKey: Equatable {
    var definition: CoreDictationPresetDefinition
    var sample: String
}

// This editor is a private draft. Opening, typing and cancelling cannot enter runtime configuration.
struct DictationPresetEditDraft: Equatable {
    var expected: CoreDictationPresetRecord?
    var name: String
    var definition: CoreDictationPresetDefinition
    var templateID: CoreDictationPresetID?
    var selectAfterSave: Bool

    init(record: CoreDictationPresetRecord) {
        expected = record
        name = DictationPresetPresentation.title(record)
        definition = record.definition
        templateID = record.templateID
        selectAfterSave = false
    }
    init(
        definition: CoreDictationPresetDefinition, templateID: CoreDictationPresetID? = nil, name: String = "",
        selectAfterSave: Bool = false
    ) {
        expected = nil
        self.name = name
        self.definition = definition
        self.templateID = templateID
        self.selectAfterSave = selectAfterSave
    }
    @discardableResult
    func save(in configuration: inout CoreDictationPresetsConfiguration) throws -> String {
        let targets = Set(Language.catalog.map(\.id))
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let expected {
            var value = expected
            // Preserve a built-in localized name unless the user actually renames it.
            value.name =
                expected.name == nil && cleanName == DictationPresetPresentation.title(expected)
                ? nil : cleanName
            value.definition = definition
            try configuration.update(value, replacing: expected, availableTargetLanguageIDs: targets)
            return value.id
        }
        if selectAfterSave {
            return try configuration.saveAs(
                name: cleanName, definition: definition, templateID: templateID,
                availableTargetLanguageIDs: targets)
        }
        return try configuration.create(
            name: cleanName, definition: definition, templateID: templateID,
            availableTargetLanguageIDs: targets)
    }
}

// Your own formats sit beside Email, Notes… in every Format pop-up. New format…
// and Edit formats… open this one sheet; a format made from a pop-up fills it.
enum YourFormatsRoute: Identifiable, Equatable {
    case new, edit(String), list
    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let id): return "edit." + id
        case .list: return "list"
        }
    }
}

enum YourFormats {
    static let newTag = "__new-format__"
    static let editTag = "__edit-formats__"
    static func records(_ presets: CoreDictationPresetsConfiguration) -> [CoreDictationPresetRecord] {
        // Every record is selectable; `enabled` only remembers the old preset selection.
        presets.records.filter { !$0.isBuiltIn && $0.legacyIssue == nil }
    }
    static func defaultStyle(_ preferences: Preferences) -> RewriteStyle {
        RewriteStyle(rawValue: preferences.voiceRefinementStyle) ?? .professional
    }
    // A name is free when no built-in format or other format of yours uses it.
    static func nameTaken(_ name: String, in presets: CoreDictationPresetsConfiguration, except id: String?) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let names =
            OutputPresentation.formatGroups.joined().map { OutputPresentation.formatTitle($0, presets: presets) }
            + records(presets).filter { $0.id != id }.map(DictationPresetPresentation.title)
        return names.contains { $0.compare(clean, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }
    // Every place that writes this format, by the name the person knows it by.
    static func uses(of id: String, in preferences: Preferences) -> [String] {
        let uses = preferences.outputs.uses(presetID: id)
        let key: (String) -> String? = { row in
            let shortcut =
                row == CoreOutputSettings.voiceTranslationShortcutID
                ? preferences.voiceTranslationShortcut : preferences.outputShortcutKeys[row]
            return shortcut.flatMap { $0.isAssigned ? $0.displayLabel : nil }
        }
        return (uses.everywhere ? [L10n.tr("Dictation")] : []) + uses.rules.map(\.applicationName)
            + uses.shortcuts.map { key($0) ?? L10n.tr("Dictation shortcut") }
            + uses.refine.map { key($0) ?? L10n.tr("Refine in place") }
    }
}

struct YourFormatsSheet: View {
    @Binding var preferences: Preferences
    var allowsSpoken = true
    let chosen: (String) -> Void
    let close: () -> Void
    @State private var editor: DictationPresetEditDraft?
    // An editor opened from the list goes back to it.
    @State private var returnsToList: Bool
    @State private var pendingDelete: CoreDictationPresetRecord?
    // The sample is this sheet's own; it is never saved.
    @State private var sample: String?
    @State private var preview: (key: PreviewKey, text: String?, error: String?)?
    @State private var error: String?
    @State private var choosingWriter = false
    @FocusState private var nameFocused: Bool
    @Environment(\.setUpWritingService) private var setUpWritingService
    #if YULLO_TESTING
        var yulloTestingCaptureActions: ((YourFormatsActions) -> Void)? = nil
        var yulloTestingWriter: ((PreviewKey) async throws -> String)? = nil
    #endif

    init(
        preferences: Binding<Preferences>, start: YourFormatsRoute, allowsSpoken: Bool = true,
        chosen: @escaping (String) -> Void, close: @escaping () -> Void
    ) {
        _preferences = preferences
        self.allowsSpoken = allowsSpoken
        self.chosen = chosen
        self.close = close
        let style = YourFormats.defaultStyle(preferences.wrappedValue)
        switch start {
        case .new:
            _editor = State(
                initialValue: .init(definition: CoreDictationPresetDefinition().based(on: nil, defaultStyle: style)))
        case .edit(let id):
            _editor = State(
                initialValue: preferences.wrappedValue.dictationPresets.record(for: id).map { .init(record: $0) })
        case .list: _editor = State(initialValue: nil)
        }
        _returnsToList = State(initialValue: start == .list)
    }

    private var presets: CoreDictationPresetsConfiguration { preferences.dictationPresets }
    private var defaultStyle: RewriteStyle { YourFormats.defaultStyle(preferences) }
    private var writingAccess: PresetWritingAccess? { PresetWritingAccess(preferences) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if editor != nil { editorContent } else { listContent }
        }.padding(24).frame(width: 440).fixedSize(horizontal: false, vertical: true)
            .font(.system(size: 13)).groupBoxStyle(SettingsCardGroupBoxStyle())
            .confirmationDialog(
                pendingDelete.map { L10n.format("Delete “%@”?", DictationPresetPresentation.title($0)) } ?? "",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button(L10n.tr("Delete"), role: .destructive) { if let pendingDelete { remove(pendingDelete) } }
                Button(L10n.tr("Cancel"), role: .cancel) { pendingDelete = nil }
            } message: {
                if let message = pendingDelete.flatMap(deleteMessage) { Text(message) }
            }
            .sheet(isPresented: $choosingWriter) {
                WritingServiceChooser(
                    draft: $preferences,
                    setUp: { anchor in
                        choosingWriter = false
                        close()
                        setUpWritingService.open?(anchor)
                    }, close: { choosingWriter = false }
                ).glassSheet()
            }
            #if YULLO_TESTING
                .onAppear { captureActions() }
                .onChange(of: preferences) { _, _ in captureActions() }
                .onChange(of: editor) { _, _ in captureActions() }
                .onChange(of: error) { _, _ in captureActions() }
            #endif
    }
    private func title(_ key: String) -> some View {
        Text(L10n.tr(key)).font(.system(size: 21, weight: .semibold))
    }

    // MARK: List

    private static let visibleRows = 8
    @ViewBuilder private var listContent: some View {
        title("Your formats")
        let records = YourFormats.records(presets)
        // The card fits its rows and scrolls only past eight.
        ScrollView {
            GroupBox {
                SettingsRows {
                    ForEach(records) { record in listRow(record) }
                }
            }
        }.scrollDisabled(records.count <= Self.visibleRows)
            .frame(height: records.count > Self.visibleRows ? CGFloat(Self.visibleRows) * 44 + 8 : nil)
            .fixedSize(horizontal: false, vertical: records.count <= Self.visibleRows)
        if let error { errorText(error) }
        HStack(spacing: 10) {
            Button(L10n.tr("New format…")) { create() }.accessibilityIdentifier("your-formats-new")
            Spacer()
            Button(L10n.tr("Done"), action: close).keyboardShortcut(.defaultAction)
        }
    }
    private func listRow(_ record: CoreDictationPresetRecord) -> some View {
        HStack(spacing: 8) {
            Text(DictationPresetPresentation.title(record)).lineLimit(1)
            Spacer(minLength: 8)
            Menu {
                Button(L10n.tr("Edit…")) { edit(record) }
                Button(L10n.tr("Duplicate")) { duplicate(record) }
                Divider()
                Button(L10n.tr("Delete…"), role: .destructive) { pendingDelete = record }
            } label: {
                Image(systemName: "ellipsis.circle")
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(L10n.format("Actions for %@", DictationPresetPresentation.title(record)))
                .help(L10n.tr("Actions"))
        }.contentShape(Rectangle()).onTapGesture(count: 2) { edit(record) }
            .accessibilityIdentifier("your-format-" + record.id)
    }

    // MARK: Editor

    private var draftName: String { editor?.name ?? "" }
    private var nameTaken: Bool {
        YourFormats.nameTaken(draftName, in: presets, except: editor?.expected?.id)
    }
    private var canSave: Bool {
        !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !nameTaken
    }
    // The built-in format this one starts from; none means its instructions alone shape it.
    private var start: String? { editor?.definition.startFormat(defaultStyle: defaultStyle) }
    private func choose(start value: String?) {
        editor?.definition = editor?.definition.based(on: value, defaultStyle: defaultStyle) ?? .init()
        error = nil
    }
    private static let noStart = "__none__"
    private var startSelection: Binding<String> {
        Binding(get: { start ?? Self.noStart }, set: { choose(start: $0 == Self.noStart ? nil : $0) })
    }
    private var starts: [[String]] {
        OutputPresentation.formatGroups.map { group in
            group.filter { allowsSpoken || $0 != CoreOutput.spoken.format }
        }
    }

    @ViewBuilder private var editorContent: some View {
        title(editor?.expected == nil ? "New format" : "Edit format")
        GroupBox {
            SettingsRows {
                SettingsTaskRow(title: L10n.tr("Name")) {
                    TextField(
                        L10n.tr("Name"),
                        text: Binding(
                            get: { draftName },
                            set: {
                                editor?.name = String($0.prefix(64))
                                error = nil
                            })
                    ).labelsHidden().textFieldStyle(.roundedBorder).frame(width: SettingsControl.width)
                        .focused($nameFocused).onAppear(perform: focusName)
                        .accessibilityIdentifier("your-format-name")
                }
                if nameTaken {
                    Text(L10n.tr("You already have a format with this name."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing).settingsRowAttached()
                }
            }
        }
        instructionsField
        GroupBox {
            SettingsRows {
                SettingsTaskRow(title: L10n.tr("Start from")) {
                    Picker(L10n.tr("Start from"), selection: startSelection) {
                        Text(L10n.tr("None")).tag(Self.noStart)
                        ForEach(Array(starts.enumerated()), id: \.offset) { _, group in
                            Divider()
                            ForEach(group, id: \.self) { value in
                                Text(OutputPresentation.formatTitle(value, presets: presets)).tag(value)
                            }
                        }
                    }.labelsHidden().pickerStyle(.menu).settingsControlWidth()
                        .accessibilityIdentifier("your-format-start")
                }
            }
        }
        previewCard
        if let error { errorText(error) }
        HStack(spacing: 10) {
            Spacer()
            Button(L10n.tr("Cancel")) { closeEditor() }.keyboardShortcut(.cancelAction)
            Button(L10n.tr(editor?.expected == nil ? "Create" : "Save")) { save() }
                .keyboardShortcut(.defaultAction).disabled(!canSave)
                .accessibilityIdentifier("your-format-save")
        }
    }
    // Focus the name with the caret at its end, so a keystroke never replaces it.
    private func focusName() {
        nameFocused = true
        DispatchQueue.main.async {
            guard let field = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            field.setSelectedRange(NSRange(location: (field.string as NSString).length, length: 0))
        }
    }
    private var instructionsCount: Int { editor?.definition.instructions?.count ?? 0 }
    @ViewBuilder private var instructionsField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.tr("Instructions")).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                if instructionsCount >= CorePresetInstructions.maximumCharacters - 100 {
                    Text(L10n.format("%ld of %ld", instructionsCount, CorePresetInstructions.maximumCharacters))
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            TextField(
                L10n.tr("Short and friendly. No emoji."),
                text: Binding(
                    get: { editor?.definition.instructions ?? "" },
                    set: {
                        let value = String($0.prefix(CorePresetInstructions.maximumCharacters))
                        editor?.definition.instructions = value.isEmpty ? nil : value
                        error = nil
                    }), axis: .vertical
            ).lineLimit(3...4).textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.tr("Instructions"))
                .accessibilityIdentifier("your-format-instructions")
        }
    }
    private var defaultSample: String {
        PresetDescribing.previewSample(style: start.flatMap(RewriteStyle.init(rawValue:)))
    }
    private var sampleText: Binding<String> {
        Binding(get: { sample ?? defaultSample }, set: { sample = String($0.prefix(1_000)) })
    }
    private var previewKey: PreviewKey? {
        guard let definition = editor?.definition, writingAccess != nil else { return nil }
        let text = sampleText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : PreviewKey(definition: definition, sample: text)
    }
    // Runs by itself a moment after the format or the sample stops changing.
    @ViewBuilder private var previewCard: some View {
        GroupBox {
            SettingsRows {
                SettingsTaskRow(title: L10n.tr("Preview")) { EmptyView() }
                if writingAccess == nil {
                    HStack(spacing: 8) {
                        Text(L10n.tr("No writing service")).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button(L10n.tr("Set up…")) { choosingWriter = true }.buttonStyle(.link)
                            .accessibilityIdentifier("your-format-set-up-writer")
                    }.font(.system(size: 11)).settingsRowAttached()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("Before")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    TextField(L10n.tr("Before"), text: sampleText, axis: .vertical).lineLimit(2...4)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                        .accessibilityIdentifier("your-format-sample")
                    if let key = previewKey {
                        Text(L10n.tr("After")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        // Three lines stay reserved, so a result doesn't move the sheet.
                        Group {
                            if let preview, preview.key == key {
                                if let text = preview.text {
                                    Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled).accessibilityIdentifier("your-format-preview-result")
                                } else if let message = preview.error {
                                    errorText(message)
                                }
                            } else {
                                ActivityStatus(title: L10n.tr("Rewriting…"))
                            }
                        }.frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
                    }
                }.padding(.vertical, 8)
            }
        }.task(id: previewKey) { await runPreview(previewKey) }
    }
    private func errorText(_ value: String) -> some View {
        Text(value).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("your-format-error")
    }

    // MARK: Actions

    private func create() {
        editor = .init(definition: CoreDictationPresetDefinition().based(on: nil, defaultStyle: defaultStyle))
        error = nil
    }
    private func edit(_ record: CoreDictationPresetRecord) {
        editor = .init(record: record)
        error = nil
    }
    private func duplicate(_ record: CoreDictationPresetRecord) {
        let title = DictationPresetPresentation.title(record)
        var name = L10n.format("%@ copy", String(title.prefix(48)))
        var number = 2
        while YourFormats.nameTaken(name, in: presets, except: nil) {
            name = L10n.format("%@ copy", String(title.prefix(48))) + " \(number)"
            number += 1
        }
        do {
            try preferences.dictationPresets.create(
                name: name, definition: record.definition,
                availableTargetLanguageIDs: Set(Language.catalog.map(\.id)))
            error = nil
        } catch { self.error = message(error) }
    }
    private func closeEditor() {
        sample = nil
        preview = nil
        error = nil
        if returnsToList { editor = nil } else { close() }
    }
    private func save() {
        guard let editor, canSave else { return }
        do {
            var updated = preferences.dictationPresets
            let id = try editor.save(in: &updated)
            preferences.dictationPresets = updated
            if editor.expected == nil && !returnsToList { chosen(CoreOutput.preset(id).format) }
            closeEditor()
        } catch { self.error = message(error) }
    }
    private func deleteMessage(_ record: CoreDictationPresetRecord) -> String? {
        let uses = YourFormats.uses(of: record.id, in: preferences)
        guard !uses.isEmpty else { return nil }
        let base = record.definition.baseFormat(defaultStyle: defaultStyle)
        return L10n.format(
            "%1$@ will write %2$@ instead.", ListFormatter.localizedString(byJoining: uses),
            OutputPresentation.formatTitle(base, presets: presets))
    }
    // Rows that used it write its base format, in the same language.
    private func remove(_ record: CoreDictationPresetRecord) {
        pendingDelete = nil
        do {
            var updated = preferences
            try updated.dictationPresets.remove(record)
            updated.outputs = updated.outputs.replacing(
                presetID: record.id, with: record.definition.baseFormat(defaultStyle: defaultStyle))
            preferences = updated
            error = nil
        } catch { self.error = message(error) }
    }
    private func runPreview(_ key: PreviewKey?) async {
        guard let key, let access = writingAccess else { return }
        if preview?.key == key { return }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard !Task.isCancelled else { return }
        do {
            let service: (PreviewKey) async throws -> String = { key in
                try await PresetDescriptionService.shared.preview(
                    key.definition, sample: key.sample, settings: access.settings, defaultStyle: access.defaultStyle)
            }
            #if YULLO_TESTING
                let write = yulloTestingWriter ?? service
            #else
                let write = service
            #endif
            let text = try await write(key)
            if !Task.isCancelled { preview = (key, text, nil) }
        } catch {
            if !Task.isCancelled { preview = (key, nil, error.localizedDescription) }
        }
    }
    private func message(_ error: Error) -> String {
        switch error as? CoreDictationPresetValidationError {
        case .invalidName: return L10n.tr("Use a name of 64 characters or fewer.")
        case .tooManyRecords: return L10n.tr("You can save up to 32 formats of your own.")
        case .invalidInstructions: return L10n.tr("Shorten the instructions to 500 characters or fewer.")
        default: return L10n.tr("This format changed. Open it again to edit.")
        }
    }
    #if YULLO_TESTING
        private func captureActions() {
            yulloTestingCaptureActions?(
                .init(
                    draft: { editor }, setName: { editor?.name = $0 }, setStart: choose(start:), start: { start },
                    setInstructions: { editor?.definition.instructions = $0 }, canSave: { canSave },
                    nameTaken: { nameTaken }, save: save, cancel: closeEditor, create: create,
                    edit: { id in presets.record(for: id).map(edit) },
                    duplicate: { id in presets.record(for: id).map(duplicate) },
                    deleteMessage: { id in presets.record(for: id).flatMap(deleteMessage) },
                    remove: { id in presets.record(for: id).map(remove) }, error: { error }))
        }
    #endif
}

#if YULLO_TESTING
    struct YourFormatsActions {
        let draft: () -> DictationPresetEditDraft?
        let setName: (String) -> Void
        let setStart: (String?) -> Void
        let start: () -> String?
        let setInstructions: (String?) -> Void
        let canSave: () -> Bool
        let nameTaken: () -> Bool
        let save: () -> Void
        let cancel: () -> Void
        let create: () -> Void
        let edit: (String) -> Void
        let duplicate: (String) -> Void
        let deleteMessage: (String) -> String?
        let remove: (String) -> Void
        let error: () -> String?
    }
#endif
