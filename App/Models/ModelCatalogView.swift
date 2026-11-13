import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LocalModelRowInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let sizeBytes: Int64
    let task: ModelDiscoveryTask
    init(id: String, name: String, sizeBytes: Int64, task: ModelDiscoveryTask = .dictation) {
        self.id = id
        self.name = name
        self.sizeBytes = sizeBytes
        self.task = task
    }
}

struct LocalModelSelection: Equatable {
    var dictation: String
    var translation: String
    var readAloud: String
    init(dictation: String = ModelLibrary.defaultModelID, translation: String = "", readAloud: String = "") {
        self.dictation = dictation
        self.translation = translation
        self.readAloud = readAloud
    }
    init(_ preferences: Preferences) {
        dictation = preferences.voiceModelID
        translation = preferences.engine == "local" ? preferences.localTranslationModelID : ""
        readAloud = preferences.speechEngine == "local" ? preferences.localSpeechModelID : ""
    }
    func id(for task: ModelDiscoveryTask) -> String {
        switch task {
        case .dictation: return dictation
        case .translation: return translation
        case .readAloud: return readAloud
        }
    }
    mutating func select(_ id: String, for task: ModelDiscoveryTask) {
        switch task {
        case .dictation: dictation = id
        case .translation: translation = id
        case .readAloud: readAloud = id
        }
    }
    func apply(to preferences: inout Preferences) {
        if !dictation.isEmpty { preferences.voiceModelID = dictation }
        if !translation.isEmpty {
            preferences.localTranslationModelID = translation
            preferences.engine = "local"
        }
        if !readAloud.isEmpty {
            preferences.localSpeechModelID = readAloud
            preferences.speechEngine = "local"
        }
    }
    static func binding(_ values: Binding<LocalModelSelection>, task: ModelDiscoveryTask) -> Binding<String> {
        Binding(
            get: { values.wrappedValue.id(for: task) },
            set: { id in
                var selection = values.wrappedValue
                selection.select(id, for: task)
                values.wrappedValue = selection
            })
    }
}

// Presentation is derived from the existing installation/download owner. Browsing
// never changes a model selection, starts a download or probes remote endpoints.
@MainActor enum ModelCatalogPresentation {
    // Only public catalog metadata is indexed, never queries or user text.
    private static var indexedLocale = ""
    private static var searchIndex: [String: String] = [:]
    private static func searchableText(_ entry: ModelDiscoveryEntry) -> String {
        let locale = L10n.locale
        if indexedLocale != locale.identifier {
            indexedLocale = locale.identifier
            searchIndex.removeAll(keepingCapacity: true)
        }
        if let cached = searchIndex[entry.id] { return cached }
        let languages = entry.languageIDs.flatMap { code in
            [
                code, Locale(identifier: "en").localizedString(forIdentifier: code) ?? "",
                locale.localizedString(forIdentifier: code) ?? "", Language.catalog.first { $0.id == code }?.name ?? ""
            ]
        }
        let live =
            entry.task == .dictation
            && entry.managedModelIDs.contains { LiveRecognitionSupport.mode(modelID: $0) != nil }
        let features = live ? [L10n.tr("Live preview")] : []
        let text =
            ([entry.name, entry.summaryKey, L10n.tr(entry.summaryKey), entry.formatLabel, entry.licenseLabel]
            + languages + features).joined(separator: " ")
        searchIndex[entry.id] = text
        return text
    }
    static func initialTask(preferences: Preferences, requested: ModelDiscoveryTask? = nil) -> ModelDiscoveryTask {
        requested
            ?? (preferences.engine == "local"
                ? .translation : preferences.speechEngine == "local" ? .readAloud : .dictation)
    }
    // Without hardware context, order by the cited ratings and maintainer pick.
    static func recommendedModelID(for task: ModelDiscoveryTask) -> String {
        ModelDiscoveryCatalog.hardwareCatalog.filter { $0.task == task }.max {
            ($0.balancedRank, -$0.downloadBytes, $1.id) < ($1.balancedRank, -$1.downloadBytes, $0.id)
        }?.id ?? ModelLibrary.defaultModelID
    }
    static func recommendation(
        for task: ModelDiscoveryTask, languageIDs: [String], profile: ModelHardwareProfile,
        installed: [InstalledLocalModel], livePreview: Bool = false
    ) -> ModelHardwareRecommendation? {
        HardwareModelRecommendation.recommend(
            needs: .init(task: task, languageIDs: languageIDs, livePreview: livePreview), profile: profile,
            candidates: ModelDiscoveryCatalog.hardwareCatalog, installedIDs: Set(installed.map(\.id)))
    }
    static func recommendationHelp(_ reason: ModelHardwareRecommendation.Reason?) -> String {
        switch reason {
        case .compact: return L10n.tr("A smaller download with lower estimated memory use.")
        case .livePreview: return L10n.tr("Supports live preview and your languages.")
        case .quality:
            return L10n.tr("A larger model for higher quality. Memory and storage needs vary by task.")
        case .balanced, .languageCoverage, nil:
            return L10n.tr(
                "A starting point for this Mac and your languages. Memory and storage needs vary by task.")
        }
    }
    static func optionLabel(_ name: String, recommended: Bool) -> String {
        recommended ? name + " · " + L10n.tr("Recommended") : name
    }
    static func choiceLabel(id: String, task: ModelDiscoveryTask, installed: [InstalledLocalModel]) -> String {
        if let model = installed.first(where: { $0.id == id && $0.task == task }) { return model.name }
        let name = ModelLibrary.catalog.first { $0.id == id && $0.task == task }?.name ?? L10n.tr("Local model")
        return L10n.tr("Not downloaded") + " · " + name
    }
    static func localRows(
        installed: [InstalledLocalModel], downloads: [String: ModelDownloadProgress], errors: [String: String] = [:],
        selected: String,
        task: ModelDiscoveryTask? = nil
    ) -> [LocalModelRowInfo] {
        var values = Dictionary(
            uniqueKeysWithValues: installed.filter { task == nil || $0.task == task }.map {
                ($0.id, LocalModelRowInfo(id: $0.id, name: $0.name, sizeBytes: $0.sizeBytes, task: $0.task))
            })
        for descriptor in ModelLibrary.catalog
        // Keep a failed uninstalled model beside its existing error and Retry
        // after the browser closes; unrelated available models stay hidden.
        where (downloads[descriptor.id] != nil || !(errors[descriptor.id] ?? "").isEmpty)
            && values[descriptor.id] == nil
            && (task == nil || descriptor.task == task)
        {
            values[descriptor.id] = LocalModelRowInfo(
                id: descriptor.id, name: descriptor.name, sizeBytes: descriptor.sizeBytes, task: descriptor.task)
        }
        return values.values.sorted {
            if ($0.id == selected) != ($1.id == selected) { return $0.id == selected }
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }
    static func entries(task: ModelDiscoveryTask, query: String, recommendedID: String? = nil) -> [ModelDiscoveryEntry]
    {
        let terms = query.split(whereSeparator: \.isWhitespace)
        let matches = ModelDiscoveryCatalog.entries.filter { entry in
            guard entry.task == task else { return false }
            let text = searchableText(entry)
            return terms.allSatisfy { text.localizedStandardContains(String($0)) }
        }
        let recommended = recommendedID ?? recommendedModelID(for: task)
        return matches.filter { $0.managedModelIDs.contains(recommended) }
            + matches.filter { !$0.managedModelIDs.contains(recommended) }
    }
    // Each catalog entry's variants that are not installed, by entry.
    static func uninstalledVariants(task: ModelDiscoveryTask, installed: [InstalledLocalModel]) -> [String: [String]] {
        let installedIDs = Set(installed.filter { $0.task == task }.map(\.id))
        var values: [String: [String]] = [:]
        for entry in ModelDiscoveryCatalog.entries where entry.task == task {
            let ids = descriptors(for: entry).map(\.id).filter { !installedIDs.contains($0) }
            if !ids.isEmpty { values[entry.id] = ids }
        }
        return values
    }
    static func browseCount(task: ModelDiscoveryTask, installed: [InstalledLocalModel]) -> Int {
        uninstalledVariants(task: task, installed: installed).count
    }
    struct BrowseRow {
        let entry: ModelDiscoveryEntry
        let variantIDs: [String]
        // Downloaded while Browse was open; it stays put until Browse resets.
        let installed: Bool
    }
    // Search order and matching as before. Rows shown when Browse opened keep
    // their variants; anything uninstalled since then joins with its own.
    static func browseRows(
        task: ModelDiscoveryTask, query: String, recommendedID: String?, installed: [InstalledLocalModel],
        shown: [String: [String]]
    ) -> [BrowseRow] {
        let current = uninstalledVariants(task: task, installed: installed)
        return entries(task: task, query: query, recommendedID: recommendedID).compactMap { entry in
            let variants = shown[entry.id] ?? current[entry.id] ?? []
            guard !variants.isEmpty else { return nil }
            return BrowseRow(entry: entry, variantIDs: variants, installed: current[entry.id] == nil)
        }
    }
    static func descriptors(for entry: ModelDiscoveryEntry) -> [LocalModelDescriptor] {
        entry.managedModelIDs.compactMap { id in ModelLibrary.catalog.first { $0.id == id && $0.task == entry.task } }
    }
    // One line in the same form for every model: how many languages it lists
    // and whether it covers the user's own. Summaries never name languages.
    static func languageSummary(modelID: String, selectedLanguageIDs: [String], localized: Bool = true) -> String? {
        guard let entry = ModelDiscoveryCatalog.entries.first(where: { $0.managedModelIDs.contains(modelID) }) else {
            return nil
        }
        let count = Set(entry.languageIDs.map(Language.canonicalCode)).count
        let total = L10n.format(entry.languageListComplete ? "%ld languages" : "At least %ld languages", count)
        if let missing = languageFit(modelID: modelID, selectedLanguageIDs: selectedLanguageIDs, localized: localized) {
            return total + " · " + missing
        }
        let yours = Language.enabled(selectedLanguageIDs).map(\.id)
        guard !yours.isEmpty else { return total }
        return total + " · " + L10n.format("Includes your %@", languageList(yours, localized: localized))
    }
    // Every listed language in the interface language, alphabetically, with the
    // user's own languages in bold.
    static func languageDetails(
        modelID: String, selectedLanguageIDs: [String], localized: Bool = true
    ) -> AttributedString? {
        guard let entry = ModelDiscoveryCatalog.entries.first(where: { $0.managedModelIDs.contains(modelID) }) else {
            return nil
        }
        let yours = Set(Language.enabled(selectedLanguageIDs).map { Language.canonicalCode($0.id) })
        var seen = Set<String>()
        let names = entry.languageIDs.map(Language.canonicalCode).filter { seen.insert($0).inserted }
            .map { (name: languageName($0, localized: localized), yours: yours.contains($0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var text = AttributedString()
        for (index, item) in names.enumerated() {
            if index > 0 { text += AttributedString(", ") }
            var name = AttributedString(item.name)
            if item.yours { name.font = .system(size: 12, weight: .semibold) }
            text += name
        }
        return text
    }
    // Coverage names the spoken language ("Chinese"), never a writing script.
    private static func languageName(_ id: String, localized: Bool) -> String {
        (localized ? L10n.locale : Locale(identifier: "en")).localizedString(forIdentifier: id)
            ?? Language.catalog.first { $0.id == id }?.subtitle ?? id
    }
    private static func languageList(_ ids: [String], localized: Bool) -> String {
        let formatter = ListFormatter()
        formatter.locale = L10n.locale
        let names = ids.map { languageName($0, localized: localized) }
        return formatter.string(from: names) ?? names.joined(separator: ", ")
    }
    static func languageFit(modelID: String, selectedLanguageIDs: [String], localized: Bool = true) -> String? {
        guard let entry = ModelDiscoveryCatalog.entries.first(where: { $0.managedModelIDs.contains(modelID) }) else {
            return nil
        }
        func coverageID(_ id: String) -> String {
            let canonical = Language.canonicalCode(id)
            return entry.task != .translation && canonical == "zh-Hant" ? "zh" : canonical
        }
        let supported = Set(entry.languageIDs.map(coverageID))
        var seen = Set<String>()
        let missing = Language.enabled(selectedLanguageIDs).map { coverageID($0.id) }
            .filter { seen.insert($0).inserted && !supported.contains($0) }
        guard !missing.isEmpty else { return nil }
        let names = missing.map { languageName($0, localized: localized) }
        let formatter = ListFormatter()
        formatter.locale = L10n.locale
        let list = formatter.string(from: names) ?? names.joined(separator: ", ")
        return L10n.format(entry.languageListComplete ? "Doesn’t support %@" : "Support not listed for %@", list)
    }
    static func progressLabel(_ progress: ModelDownloadProgress) -> String {
        if progress.phase == .verifying { return L10n.tr("Verifying…") }
        guard let total = progress.totalBytes, total > 0 else { return L10n.tr("Downloading…") }
        return L10n.format(
            "%@ of %@", L10n.size(progress.downloadedBytes),
            L10n.size(total))
    }
    static func variantID(
        for entry: ModelDiscoveryEntry, choice: String?, selected: String, downloads: [String: ModelDownloadProgress],
        recommendedID: String? = nil, among allowed: [String]? = nil
    ) -> String? {
        let ids = descriptors(for: entry).map(\.id).filter { allowed?.contains($0) ?? true }
        if let active = ids.first(where: { downloads[$0] != nil }) { return active }
        if let choice, ids.contains(choice) { return choice }
        if ids.contains(selected) { return selected }
        let recommended = recommendedID ?? recommendedModelID(for: entry.task)
        if ids.contains(recommended) { return recommended }
        return ids.first
    }
}

enum ModelImportPanel {
    @MainActor static func open(models: VoiceModelStore, task: ModelDiscoveryTask = .dictation) {
        let panel = NSOpenPanel()
        panel.title = L10n.tr(
            task == .dictation
                ? "Import speech model" : task == .translation ? "Import translation model" : "Import voice model")
        panel.message = L10n.tr(
            task == .dictation
                ? "Whisper GGML and supported speech GGUF files."
                : task == .translation
                    ? "Choose a supported translation GGUF model."
                    : "Choose a voice model file listed in Yullo’s catalog.")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = (task == .dictation ? ["bin", "gguf"] : ["gguf"]).compactMap {
            UTType(filenameExtension: $0)
        }
        if panel.runModal() == .OK, let url = panel.url { models.importModel(url, task: task) }
    }
}

// The Browse list inside "On this Mac": catalog models for the task that are
// not installed yet, each with its uninstalled variants only. Installed and
// imported models are managed in Installed above. A model downloaded here
// keeps its row, marked installed, until the task changes or Browse closes.
struct ModelCatalogView: View {
    @Binding var selections: LocalModelSelection
    @Binding var task: ModelDiscoveryTask
    var selectedLanguageIDs: [String] = Language.fallbackIDs
    private var recommendationLanguageIDs: [String]?
    @ObservedObject var models: VoiceModelStore
    @ObservedObject var voice: VoiceInputCoordinator
    var livePreviewRequested = false
    @State private var query = ""
    @State private var hardware: ModelHardwareProfile?
    // Uninstalled variants per entry when Browse opened or the task changed.
    @State private var shown: [String: [String]]?
    @FocusState private var searchFocused: Bool
    init(
        selections: Binding<LocalModelSelection>, task: Binding<ModelDiscoveryTask>,
        selectedLanguageIDs: [String] = Language.fallbackIDs, models: VoiceModelStore, voice: VoiceInputCoordinator,
        livePreviewRequested: Bool = false, hardwareProfile: ModelHardwareProfile? = nil,
        recommendationLanguageIDs: [String]? = nil
    ) {
        _selections = selections
        _task = task
        self.selectedLanguageIDs = selectedLanguageIDs
        self.recommendationLanguageIDs = recommendationLanguageIDs
        self.models = models
        self.voice = voice
        self.livePreviewRequested = livePreviewRequested
        _hardware = State(initialValue: hardwareProfile)
    }
    private func selection(for task: ModelDiscoveryTask) -> Binding<String> {
        LocalModelSelection.binding($selections, task: task)
    }
    private var recommendation: ModelHardwareRecommendation? {
        guard let hardware else { return nil }
        return ModelCatalogPresentation.recommendation(
            for: task, languageIDs: recommendationLanguageIDs ?? selectedLanguageIDs,
            profile: hardware, installed: models.installed,
            livePreview: livePreviewRequested)
    }
    private func snapshot() -> [String: [String]] {
        ModelCatalogPresentation.uninstalledVariants(task: task, installed: models.installed)
    }
    var body: some View {
        let suggestion = recommendation
        let recommendedID = suggestion?.modelID ?? ""
        let rows = ModelCatalogPresentation.browseRows(
            task: task, query: query, recommendedID: recommendedID, installed: models.installed,
            shown: shown ?? snapshot())
        VStack(alignment: .leading, spacing: 0) {
            SearchCapsule(prompt: L10n.tr("Search models"), text: $query, focus: $searchFocused)
                .padding(.vertical, 10)
            if rows.isEmpty {
                Text(L10n.tr("No models found.")).font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
            }
            ForEach(rows, id: \.entry.id) { row in
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    ManagedModelCatalogRow(
                        entry: row.entry, selected: selection(for: row.entry.task),
                        selectedLanguageIDs: selectedLanguageIDs, models: models, voice: voice,
                        recommendedID: recommendedID, recommendationReason: suggestion?.reason,
                        variantIDs: row.variantIDs)
                    if row.installed {
                        Text(L10n.tr("Installed.")).font(.system(size: 12))
                            .foregroundStyle(.secondary).padding(.bottom, 10)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.locale, L10n.locale)
            .onAppear { if shown == nil { shown = snapshot() } }
            .onChange(of: task) {
                query = ""
                shown = snapshot()
            }
            .task {
                if hardware == nil { hardware = await ModelHardwareProfile.load() }
                await models.refresh()
            }
    }
}

struct LocalTaskModelPicker: View {
    let task: ModelDiscoveryTask
    @Binding var selected: String
    @ObservedObject var models: VoiceModelStore
    var languageIDs: [String] = []
    @State private var hardware: ModelHardwareProfile?
    private var installed: [InstalledLocalModel] { models.installed.filter { $0.task == task } }
    private var choiceLabel: String {
        ModelCatalogPresentation.choiceLabel(id: selected, task: task, installed: installed)
    }
    var body: some View {
        let recommendedID = hardware.flatMap {
            ModelCatalogPresentation.recommendation(
                for: task, languageIDs: languageIDs, profile: $0, installed: models.installed)?.modelID
        }
        VStack(alignment: .leading, spacing: 6) {
            Picker(L10n.tr("Model"), selection: $selected) {
                if !installed.contains(where: { $0.id == selected }) {
                    Text(choiceLabel).tag(selected)
                }
                ForEach(installed) {
                    Text(ModelCatalogPresentation.optionLabel($0.name, recommended: $0.id == recommendedID)).tag($0.id)
                }
            }.help(choiceLabel)
            ModelRatingSummary(modelID: selected, recommended: selected == recommendedID)
        }.task {
            if hardware == nil { hardware = await ModelHardwareProfile.load() }
            await models.refresh()
        }
    }
}

// Cited speed and accuracy as five circles each, in half steps on the 3.0–5.0
// display scale; VoiceOver reads "Speed: 4.5 out of 5".
struct ModelRatingView: View {
    let rating: ModelRating
    var body: some View {
        HStack(spacing: 12) {
            meter("Speed %@", spoken: "Speed: %@ out of 5", value: rating.displaySpeed)
            meter("Accuracy %@", spoken: "Accuracy: %@ out of 5", value: rating.displayAccuracy)
        }.font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
            .accessibilityElement(children: .contain)
            .help(L10n.tr("Ratings come from published benchmarks and compare models for the same task."))
    }
    static func circleSymbols(_ value: Double) -> [String] {
        (0..<5).map { index in
            let fill = value - Double(index)
            // circle.lefthalf.filled fills its left half, so the meter fills
            // left to right like the full circles before it.
            return fill >= 1 ? "circle.fill" : fill >= 0.5 ? "circle.lefthalf.filled" : "circle"
        }
    }
    private func meter(_ key: String, spoken: String, value: Double) -> some View {
        let score = value.formatted(.number.precision(.fractionLength(1)).locale(L10n.locale))
        // The localized label keeps its own order around the circles.
        let parts = L10n.format(key, "\u{FFFC}").components(separatedBy: "\u{FFFC}")
        let circles = Self.circleSymbols(value).map {
            Text(Image(systemName: $0)).font(.system(size: 8)).baselineOffset(1)
        }
        let prefix = Text(verbatim: parts.first ?? ""), suffix = Text(verbatim: parts.dropFirst().joined())
        return Text("\(prefix)\(circles[0])\(circles[1])\(circles[2])\(circles[3])\(circles[4])\(suffix)")
            .accessibilityLabel(L10n.format(spoken, score))
    }
}

struct ModelRatingSummary: View {
    let modelID: String
    var recommended = false
    var body: some View {
        if let rating = ModelDiscoveryCatalog.rating(for: modelID) {
            HStack(spacing: 10) {
                ModelRatingView(rating: rating)
                if recommended {
                    Text(L10n.tr("Recommended")).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
                }
            }
        }
    }
}

// Languages, practical notes and rating sources, folded under each model.
struct ModelDetailsDisclosure: View {
    let entry: ModelDiscoveryEntry
    let modelID: String
    let selectedLanguageIDs: [String]
    @Environment(\.localizedLanguageNames) private var localizedLanguageNames
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(L10n.tr("Details"))
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0)).accessibilityHidden(true)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                .accessibilityValue(L10n.tr(expanded ? "Expanded" : "Collapsed"))
                .accessibilityIdentifier("model-details-" + entry.id)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let languages = ModelCatalogPresentation.languageDetails(
                        modelID: modelID, selectedLanguageIDs: selectedLanguageIDs, localized: localizedLanguageNames)
                    {
                        Text(languages).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if !entry.languageListComplete {
                        detail("Listed by the publisher; others may also work.")
                    }
                    ForEach(entry.detailNoteKeys, id: \.self) { detail($0) }
                    if let note = entry.accessNoteKey { detail(note) }
                    if ModelDiscoveryCatalog.rating(for: modelID) != nil {
                        detail("Ratings come from published benchmarks and compare models for the same task.")
                    }
                }.padding(.leading, 2)
            }
        }
    }
    private func detail(_ key: String) -> some View {
        Text(L10n.tr(key)).font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ManagedModelCatalogRow: View {
    let entry: ModelDiscoveryEntry
    @Binding var selected: String
    let selectedLanguageIDs: [String]
    @Environment(\.localizedLanguageNames) private var localizedLanguageNames
    @ObservedObject var models: VoiceModelStore
    @ObservedObject var voice: VoiceInputCoordinator
    @State private var choice: String?
    var recommendedID = ""
    var recommendationReason: ModelHardwareRecommendation.Reason?
    // The variants Browse offers; nil offers them all.
    var variantIDs: [String]?
    private var descriptors: [LocalModelDescriptor] {
        ModelCatalogPresentation.descriptors(for: entry).filter { variantIDs?.contains($0.id) ?? true }
    }
    private var descriptor: LocalModelDescriptor? {
        let id = ModelCatalogPresentation.variantID(
            for: entry, choice: choice, selected: selected, downloads: models.downloads,
            recommendedID: recommendedID, among: variantIDs)
        return descriptors.first { $0.id == id }
    }
    var body: some View {
        if let descriptor {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(entry.name).font(.system(size: 13, weight: .medium)).lineLimit(1).help(entry.name)
                    if descriptor.id == recommendedID {
                        Text(L10n.tr("Recommended")).font(.system(size: 12)).foregroundStyle(.secondary)
                            .help(ModelCatalogPresentation.recommendationHelp(recommendationReason))
                    }
                    if entry.task == .dictation, LiveRecognitionSupport.mode(modelID: descriptor.id) != nil {
                        Text(L10n.tr("Live preview")).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                    }
                    Spacer(minLength: 0)
                    if descriptors.count > 1 {
                        Picker(L10n.tr("Variant"), selection: Binding(get: { descriptor.id }, set: { choice = $0 })) {
                            ForEach(descriptors) {
                                Text($0.name.components(separatedBy: " · ").last ?? $0.name).tag($0.id)
                            }
                        }.labelsHidden().fixedSize().frame(width: 72, alignment: .trailing)
                            .disabled(voice.isBusy || descriptors.contains { models.downloads[$0.id] != nil })
                            .background {
                                #if YULLO_TESTING
                                    TrailingControlGeometryProbe(controlID: "variant-" + entry.id)
                                #endif
                            }
                    }
                }
                Text(L10n.tr(entry.summaryKey)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
                if let languages = ModelCatalogPresentation.languageSummary(
                    modelID: descriptor.id, selectedLanguageIDs: selectedLanguageIDs, localized: localizedLanguageNames)
                {
                    Text(languages).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).help(languages)
                }
                if let rating = ModelDiscoveryCatalog.rating(for: descriptor.id) { ModelRatingView(rating: rating) }
                ModelDetailsDisclosure(entry: entry, modelID: descriptor.id, selectedLanguageIDs: selectedLanguageIDs)
                if models.downloads[descriptor.id] == nil {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            metadata(descriptor)
                            Spacer(minLength: 0)
                            VoiceModelActions(
                                id: descriptor.id, task: entry.task, selected: $selected, models: models, voice: voice
                            )
                            .fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            metadata(descriptor)
                            VoiceModelActions(
                                id: descriptor.id, task: entry.task, selected: $selected, models: models, voice: voice
                            )
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    metadata(descriptor)
                    VoiceModelActions(
                        id: descriptor.id, task: entry.task, selected: $selected, models: models, voice: voice)
                }
                if let message = models.errors[descriptor.id] {
                    Text(message).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.padding(.vertical, 12)
        }
    }
    private func metadata(_ descriptor: LocalModelDescriptor) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                artifactDetails(descriptor)
                sourceLinks
            }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 6) {
                artifactDetails(descriptor)
                HStack(spacing: 10) { sourceLinks }
            }
        }.font(.system(size: 12))
    }
    private func artifactDetails(_ descriptor: LocalModelDescriptor) -> some View {
        Text(
            L10n.size(descriptor.sizeBytes) + " · "
                + entry.formatLabel
        )
        .foregroundStyle(.secondary).fixedSize(horizontal: true, vertical: false)
    }
    @ViewBuilder private var sourceLinks: some View {
        Link(L10n.tr("Model source"), destination: entry.sourceURL)
            .help(entry.accessNoteKey.map(L10n.tr) ?? "").fixedSize()
        Link(entry.licenseLabel, destination: entry.licenseURL).lineLimit(1).fixedSize()
    }
}

struct LocalVoiceModelRow: View {
    let row: LocalModelRowInfo
    @Binding var selected: String
    @ObservedObject var models: VoiceModelStore
    @ObservedObject var voice: VoiceInputCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.name).font(.system(size: 13, weight: .medium)).lineLimit(1).help(row.name)
                    HStack(spacing: 8) {
                        Text(L10n.size(row.sizeBytes))
                        if row.task == .dictation,
                            LiveRecognitionSupport.mode(
                                modelID: row.id,
                                architecture: models.installed.first { $0.id == row.id }?.architecture) != nil
                        {
                            Text(L10n.tr("Live preview"))
                        }
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                    if let rating = ModelDiscoveryCatalog.rating(for: row.id) { ModelRatingView(rating: rating) }
                }
                Spacer(minLength: 0)
                if models.downloads[row.id] == nil {
                    VoiceModelActions(id: row.id, task: row.task, selected: $selected, models: models, voice: voice)
                }
            }
            if models.downloads[row.id] != nil {
                VoiceModelActions(id: row.id, task: row.task, selected: $selected, models: models, voice: voice)
            }
            if let message = models.errors[row.id] {
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.padding(.vertical, 10)
    }
}

private struct VoiceModelActions: View {
    let id: String
    let task: ModelDiscoveryTask
    @Binding var selected: String
    @ObservedObject var models: VoiceModelStore
    @ObservedObject var voice: VoiceInputCoordinator
    var body: some View {
        if let progress = models.downloads[id] {
            VStack(alignment: .leading, spacing: 6) {
                if let value = progress.fraction, value.isFinite {
                    ProgressView(value: min(1, max(0, value))).tint(.accentColor)
                } else {
                    ProgressView().controlSize(.small)
                }
                HStack {
                    Text(ModelCatalogPresentation.progressLabel(progress)).font(.system(size: 12)).foregroundStyle(
                        .secondary
                    ).monospacedDigit()
                    Spacer()
                    Button(L10n.tr("Cancel")) { models.cancel(id) }.buttonStyle(.link).font(.system(size: 13))
                }
            }
        } else {
            HStack(spacing: 10) {
                if models.installed.contains(where: { $0.id == id }) {
                    // Names the task it changes, so a finished download has an obvious next step.
                    Button(selected == id ? L10n.tr("Selected") : Self.useTitle(task)) { selected = id }
                        .disabled(voice.isBusy || selected == id)
                        .background {
                            #if YULLO_TESTING
                                TrailingControlGeometryProbe(controlID: "use-" + id)
                            #endif
                        }
                    Button(L10n.tr("Remove")) { models.remove(id) }.buttonStyle(.link)
                        .disabled(voice.isBusy || selected == id)
                        .background {
                            #if YULLO_TESTING
                                TrailingControlGeometryProbe(controlID: "remove-" + id)
                            #endif
                        }
                } else {
                    Button(L10n.tr(models.errors[id] == nil ? "Download" : "Retry")) { models.download(id) }.disabled(
                        voice.isBusy
                    )
                    .background {
                        #if YULLO_TESTING
                            TrailingControlGeometryProbe(controlID: "download-" + id)
                        #endif
                    }
                }
            }.controlSize(.regular).font(.system(size: 13))
        }
    }
    static func useTitle(_ task: ModelDiscoveryTask) -> String {
        switch task {
        case .dictation: return L10n.tr("Use for dictation")
        case .translation: return L10n.tr("Use for translation")
        case .readAloud: return L10n.tr("Use for read aloud")
        }
    }
}
