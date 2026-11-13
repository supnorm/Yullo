import SwiftUI
import AppKit

#if YULLO_TESTING
    struct VocabularySettingsAttachedActions {
        let enable: (Bool) -> Void
        let search: Binding<String>
        let visibleEntries: () -> [CoreVocabularyEntry]
        let select: (UUID?) -> Void
        let add: () -> Void
        let edit: (UUID) -> Void
        let remove: () -> Void
        let session: () -> VocabularyEditSession?
        let submit: (CoreVocabularyEntry, VocabularyEditSession) -> String?
        let cancelEditor: () -> Void
    }
    struct VocabularyEditorAttachedActions {
        let draft: Binding<CoreVocabularyEntry>
        let preservesSpelling: Binding<Bool>
        let matchingExpanded: Binding<Bool>
        let submit: () -> Void
        let cancel: () -> Void
        let issue: () -> String?
    }
#endif

@MainActor struct PersonalVocabularySettingsView: View {
    @Binding var configuration: CoreVocabularyConfiguration
    let localizedLanguageNames: Bool
    let close: () -> Void
    @State private var search = ""
    @State private var visibleEntries: [CoreVocabularyEntry] = []
    @State private var selection: UUID?
    @State private var editing: VocabularyEditSession?
    @State private var issue: String?
    #if YULLO_TESTING
        var yulloTestingCaptureActions: ((VocabularySettingsAttachedActions) -> Void)?
    #endif

    init(
        configuration: Binding<CoreVocabularyConfiguration>, localizedLanguageNames: Bool = true,
        close: @escaping () -> Void
    ) {
        _configuration = configuration
        self.localizedLanguageNames = localizedLanguageNames
        self.close = close
        _visibleEntries = State(initialValue: configuration.wrappedValue.entries)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.tr("Personal vocabulary")).font(.system(size: 22, weight: .semibold))
                Spacer(minLength: 12)
                Toggle(
                    L10n.tr("Use personal vocabulary"),
                    isOn: Binding(get: { configuration.enabled }, set: { setVocabularyEnabled($0) })
                )
                .toggleStyle(.switch).labelsHidden().accessibilityLabel(L10n.tr("Use personal vocabulary"))
                .accessibilityIdentifier("vocabulary-enabled")
            }
            Text(L10n.tr("Stored on this Mac. Terms may be sent to the service a task uses."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(L10n.tr("Search terms"), text: $search).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("vocabulary-search")
            List(selection: $selection) {
                ForEach(visibleEntries) { entry in
                    HStack(spacing: 12) {
                        Toggle(L10n.format("Use %@", actionName(entry)), isOn: entryEnabled(entry.id))
                            .labelsHidden().accessibilityLabel(L10n.format("Use %@", actionName(entry)))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(displayName(entry)).fontWeight(.medium)
                            Text(usesDescription(entry)).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button(L10n.tr("Edit…")) { editing = .existing(entry) }.buttonStyle(.borderless)
                            .accessibilityLabel(L10n.format("Edit %@", actionName(entry)))
                    }.padding(.vertical, 5).tag(entry.id)
                }
            }.listStyle(.inset).glassList().overlay {
                if visibleEntries.isEmpty, !configuration.entries.isEmpty {
                    Text(L10n.tr("No matching terms.")).foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }.accessibilityIdentifier("vocabulary-list")
            if let issue {
                Text(issue).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityIdentifier("vocabulary-list-error")
            }
            HStack(spacing: 12) {
                Button(L10n.tr("Add term…")) { editing = .new }
                    .accessibilityIdentifier("vocabulary-add")
                Button(L10n.tr("Delete"), action: deleteSelected).disabled(!hasVisibleSelection)
                    .accessibilityIdentifier("vocabulary-delete")
                Spacer(minLength: 12)
                Button(L10n.tr("Done"), action: close).keyboardShortcut(.cancelAction)
            }
        }.font(.system(size: 13)).padding(24)
            .frame(minWidth: 560, idealWidth: 640, maxWidth: 760, minHeight: 420, idealHeight: 520, maxHeight: 720)
            .environment(\.locale, L10n.locale)
            .onAppear {
                #if YULLO_TESTING
                    yulloTestingCaptureActions?(
                        .init(
                            enable: setVocabularyEnabled,
                            search: $search, visibleEntries: { visibleEntries }, select: { selection = $0 },
                            add: { editing = .new },
                            edit: { id in
                                if let entry = configuration.entries.first(where: { $0.id == id }) {
                                    editing = .existing(entry)
                                }
                            },
                            remove: deleteSelected, session: { editing },
                            submit: { entry, session in save(entry, session: session)
                            }, cancelEditor: { editing = nil }))
                #endif
            }
            .task(id: VocabularyFilterRequest(search: search, entries: configuration.entries)) {
                // Reconcile the cached list after the current AppKit table
                // update, rather than publishing another row set reentrantly.
                await Task.yield()
                guard !Task.isCancelled else { return }
                await filterEntries()
            }
            .sheet(item: $editing) { session in
                PersonalVocabularyEntryEditor(
                    session: session, localizedLanguageNames: localizedLanguageNames,
                    save: { entry in save(entry, session: session) }, cancel: { editing = nil }
                ).glassSheet()
            }
    }

    private func filterEntries() async {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let next =
            query.isEmpty
            ? configuration.entries
            : configuration.entries.filter {
                [$0.canonical, $0.alias, $0.translation].contains { $0.localizedStandardContains(query) }
            }
        if let selection, !next.contains(where: { $0.id == selection }) {
            self.selection = nil
            // AppKit must finish clearing its selected row before the next
            // row set replaces it. Keep both updates outside its delegate.
            await Task.yield()
            guard !Task.isCancelled else { return }
        }
        if visibleEntries != next { visibleEntries = next }
    }
    private var hasVisibleSelection: Bool {
        selection.map { id in visibleEntries.contains { $0.id == id } } ?? false
    }
    private func setVocabularyEnabled(_ enabled: Bool) {
        var next = configuration
        next.enabled = enabled
        if enabled {
            update(next)
        } else {
            // Off is always a safe recovery action, including for decoded
            // entries that need to be repaired one at a time.
            configuration = next
            issue = nil
        }
    }
    private func entryEnabled(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { configuration.entries.first(where: { $0.id == id })?.enabled ?? false },
            set: { value in
                guard let index = configuration.entries.firstIndex(where: { $0.id == id }) else { return }
                var next = configuration
                next.entries[index].enabled = value
                if next.enabled {
                    update(next)
                } else {
                    do {
                        if value { _ = try configuration.validatedEntry(next.entries[index], replacing: index) }
                        configuration = next
                        issue = nil
                    } catch { issue = vocabularyIssue(error) }
                }
            })
    }
    private func update(_ next: CoreVocabularyConfiguration) {
        do {
            configuration = try next.validated()
            issue = nil
        } catch { issue = vocabularyIssue(error) }
    }
    private func deleteSelected() {
        guard let selection, hasVisibleSelection,
            let index = configuration.entries.firstIndex(where: { $0.id == selection })
        else { return }
        self.selection = nil
        var next = configuration
        next.entries.remove(at: index)
        if next.enabled {
            update(next)
        } else {
            configuration = next
            issue = nil
        }
    }
    private func save(_ entry: CoreVocabularyEntry, session: VocabularyEditSession) -> String? {
        guard editing?.id == session.id else {
            return L10n.tr("This term changed. Close the editor and try again.")
        }
        let index: Int?
        if let original = session.original {
            guard let current = configuration.entries.firstIndex(where: { $0.id == original.id }),
                configuration.entries[current] == original
            else { return L10n.tr("This term changed. Close the editor and try again.") }
            index = current
        } else {
            index = nil
        }
        do {
            let accepted = try configuration.validatedEntry(entry, replacing: index)
            var next = configuration
            if let index { next.entries[index] = accepted } else { next.entries.append(accepted) }
            // While Off, unrelated malformed decoded entries stay available
            // for individual repair. On always requires complete validation.
            if next.enabled { configuration = try next.validated() } else { configuration = next }
            issue = nil
            selection = accepted.id
            editing = nil
            return nil
        } catch { return vocabularyIssue(error) }
    }
    private func displayName(_ entry: CoreVocabularyEntry) -> String {
        entry.canonical.isEmpty ? L10n.tr("Untitled term") : entry.canonical
    }
    private func actionName(_ entry: CoreVocabularyEntry) -> String {
        guard entry.useInTranslation else { return displayName(entry) }
        if entry.preservesSpelling { return displayName(entry) + " · " + L10n.tr("Keep spelling") }
        let language = Language.displayName(
            for: entry.targetLanguage, localized: localizedLanguageNames, locale: L10n.locale)
        return displayName(entry) + " · " + language
    }
    private func usesDescription(_ entry: CoreVocabularyEntry) -> String {
        var uses: [String] = []
        if entry.recognitionHint { uses.append(L10n.tr("Recognition hint")) }
        if entry.correctAlias { uses.append(L10n.tr("Spelling correction")) }
        if entry.preservesSpelling {
            uses.append(L10n.tr("Keep spelling"))
        } else if entry.useInTranslation {
            let language = Language.displayName(
                for: entry.targetLanguage, localized: localizedLanguageNames, locale: L10n.locale)
            uses.append(L10n.tr("Translation term") + " · " + language)
        }
        return uses.isEmpty ? L10n.tr("No uses selected") : uses.joined(separator: " · ")
    }
}

private struct VocabularyFilterRequest: Equatable {
    let search: String
    let entries: [CoreVocabularyEntry]
}

struct VocabularyEditSession: Identifiable {
    let id = UUID()
    let original: CoreVocabularyEntry?
    let entry: CoreVocabularyEntry
    static var new: Self { .init(original: nil, entry: .init(canonical: "")) }
    static func existing(_ entry: CoreVocabularyEntry) -> Self { .init(original: entry, entry: entry) }
}

@MainActor struct PersonalVocabularyEntryEditor: View {
    let session: VocabularyEditSession
    let localizedLanguageNames: Bool
    let save: (CoreVocabularyEntry) -> String?
    let cancel: () -> Void
    @State private var draft: CoreVocabularyEntry
    @State private var issue: String?
    @State private var matchingExpanded = false
    @State private var revealAlias = false
    @State private var revealTranslation = false
    @State private var savedTranslation = ""
    @State private var savedTranslationTarget = ""
    #if YULLO_TESTING
        var yulloTestingCaptureActions: ((VocabularyEditorAttachedActions) -> Void)?
    #endif

    init(
        session: VocabularyEditSession, localizedLanguageNames: Bool,
        save: @escaping (CoreVocabularyEntry) -> String?, cancel: @escaping () -> Void
    ) {
        self.session = session
        self.localizedLanguageNames = localizedLanguageNames
        self.save = save
        self.cancel = cancel
        _draft = State(initialValue: session.entry)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr(session.original == nil ? "Add term" : "Edit term"))
                .font(.system(size: 22, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field("Preferred spelling", value: $draft.canonical)
                    SettingsSection(L10n.tr("Use this term for")) {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(L10n.tr("Recognition hint"), isOn: $draft.recognitionHint)
                            Text(L10n.tr("Whisper models only."))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Divider()
                            Toggle(L10n.tr("Spelling correction"), isOn: $draft.correctAlias)
                            if draft.correctAlias || revealAlias {
                                field("Replace this spelling", value: $draft.alias)
                                Text(L10n.tr("After dictation. Case-sensitive."))
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)

                            }
                            Divider()
                            Toggle(L10n.tr("Translation term"), isOn: $draft.useInTranslation)
                            if draft.useInTranslation || revealTranslation {
                                Picker(L10n.tr("In translation"), selection: preservesSpelling) {
                                    Text(L10n.tr("Translate as")).tag(false)
                                    Text(L10n.tr("Keep spelling")).tag(true)
                                }.pickerStyle(.segmented).fixedSize().accessibilityIdentifier(
                                    "vocabulary-translation-behavior")
                                if !draft.preservesSpelling {
                                    Picker(L10n.tr("Target language"), selection: $draft.targetLanguage) {
                                        Text(L10n.tr("Choose a language")).tag("")
                                        if !draft.targetLanguage.isEmpty,
                                            !Language.catalog.contains(where: { $0.id == draft.targetLanguage })
                                        {
                                            Text(
                                                L10n.locale.localizedString(forIdentifier: draft.targetLanguage)
                                                    ?? draft.targetLanguage
                                            ).tag(draft.targetLanguage)
                                        }
                                        ForEach(
                                            Language.sorted(
                                                Language.catalog, localized: localizedLanguageNames,
                                                locale: L10n.locale)
                                        ) { language in
                                            Text(
                                                language.displayName(
                                                    localized: localizedLanguageNames, locale: L10n.locale)
                                            )
                                            .tag(language.id)
                                        }
                                    }
                                    field("Translate as", value: $draft.translation)
                                }
                            }
                            if draft.correctAlias || draft.useInTranslation {
                                DisclosureGroup(isExpanded: $matchingExpanded) {
                                    Picker(L10n.tr("Match"), selection: $draft.boundary) {
                                        Text(L10n.tr("Whole term")).tag(CoreVocabularyBoundary.wholeTerm)
                                        Text(L10n.tr("Anywhere in text")).tag(CoreVocabularyBoundary.substring)
                                    }.pickerStyle(.segmented).fixedSize().padding(.top, 8)
                                    if draft.boundary == .substring {
                                        Text(
                                            L10n.tr(
                                                "Matching inside words can change unrelated text. Use it only for a distinctive phrase."
                                            )
                                        )
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    }
                                } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text(L10n.tr("Matching"))
                                        Spacer(minLength: 8)
                                        if !matchingExpanded {
                                            Text(
                                                L10n.tr(
                                                    draft.boundary == .wholeTerm ? "Whole term" : "Anywhere in text")
                                            )
                                            .font(.system(size: 12)).foregroundStyle(.secondary)
                                        }
                                    }.contentShape(Rectangle())
                                }
                            }
                        }.padding(12)
                    }
                }.padding(.trailing, 8)
            }.smallNativeScrollbars()
            if let issue {
                Text(issue).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("vocabulary-entry-error")
            }
            Divider()
            HStack {
                Button(L10n.tr("Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Spacer(minLength: 12)
                Button(L10n.tr("Save"), action: submit).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("vocabulary-entry-save")
            }
        }.font(.system(size: 13)).padding(24)
            .frame(minWidth: 520, idealWidth: 560, maxWidth: 640, minHeight: 420, idealHeight: 540, maxHeight: 680)
            .environment(\.locale, L10n.locale)
            .onAppear {
                #if YULLO_TESTING
                    yulloTestingCaptureActions?(
                        .init(
                            draft: $draft, preservesSpelling: preservesSpelling, matchingExpanded: $matchingExpanded,
                            submit: submit, cancel: cancel, issue: { issue }))
                #endif
            }
    }
    private var preservesSpelling: Binding<Bool> {
        Binding(
            get: { draft.targetLanguage == CoreVocabularyEntry.allTranslationLanguages },
            set: { preserve in
                guard preserve != (draft.targetLanguage == CoreVocabularyEntry.allTranslationLanguages) else { return }
                if preserve {
                    savedTranslation = draft.translation
                    savedTranslationTarget = draft.targetLanguage
                    draft.targetLanguage = CoreVocabularyEntry.allTranslationLanguages
                    draft.translation = draft.canonical
                } else {
                    draft.targetLanguage = savedTranslationTarget
                    draft.translation = savedTranslation
                }
            })
    }
    private func submit() {
        if draft.preservesSpelling { draft.translation = draft.canonical }
        do { _ = try CoreVocabularyConfiguration(entries: [draft]).validated() } catch let error
            as CoreVocabularyValidationError
        {
            switch error {
            case .fieldTooLong(.alias), .invalidCharacters(.alias): revealAlias = true
            case .fieldTooLong(.translation), .invalidCharacters(.translation),
                .fieldTooLong(.targetLanguage), .invalidCharacters(.targetLanguage):
                revealTranslation = true
            default: break
            }
            issue = L10n.tr(error.messageKey)
            return
        } catch {
            issue = vocabularyIssue(error)
            return
        }
        issue = save(draft)
    }

    private func field(_ title: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr(title)).fontWeight(.medium)
            TextField(L10n.tr(title), text: value).labelsHidden().textFieldStyle(.roundedBorder)
                .autocorrectionDisabled().accessibilityLabel(L10n.tr(title))
        }
    }
}

private func vocabularyIssue(_ error: Error) -> String {
    // Core validation owns the limits and conflict rules. A failed edit stays
    // in this sheet, without replacing the saved configuration.
    if let issue = error as? CoreVocabularyValidationError { return L10n.tr(issue.messageKey) }
    return L10n.tr("Couldn’t save this term. Check its spelling, uses and matching rules.")
}
