import SwiftUI

// Rows, filter options and language choices for local voices. Pure values,
// so the same rules are checked without a view.
enum LocalVoicePresentation {
    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let detail: String
        let variety: String?
        let gender: String?
        let recommended: Bool
    }
    static func rows(modelID: String, language: String) -> [Row] {
        LocalSpeechSynthesizer.voices(modelID: modelID, language: language).enumerated().map { index, voice in
            let details = LocalSpeechVoiceCatalog.details(for: voice.id, modelID: modelID)
            return Row(
                id: voice.id, name: voice.name,
                detail: LocalSpeechVoiceCatalog.detail(for: voice.id, modelID: modelID),
                variety: details?.variety, gender: details?.gender.rawValue, recommended: index == 0)
        }
    }
    // A filter helps only in a long list with more than one accent or gender.
    // Each option is "variety:<code>" or "gender:<female|male>"; "" shows all.
    static func filters(_ rows: [Row]) -> [String] {
        guard rows.count > 8 else { return [] }
        var varieties: [String] = [], genders: [String] = []
        for row in rows {
            if let variety = row.variety, !varieties.contains(variety) { varieties.append(variety) }
            if let gender = row.gender, !genders.contains(gender) { genders.append(gender) }
        }
        let options =
            (varieties.count > 1 ? varieties.map { "variety:" + $0 } : [])
            + (genders.count > 1 ? genders.sorted().map { "gender:" + $0 } : [])
        return options
    }
    static func filtered(_ rows: [Row], by filter: String) -> [Row] {
        if filter.hasPrefix("variety:") { return rows.filter { "variety:" + ($0.variety ?? "") == filter } }
        if filter.hasPrefix("gender:") { return rows.filter { "gender:" + ($0.gender ?? "") == filter } }
        return rows
    }
    static func filterName(_ filter: String) -> String {
        if filter.hasPrefix("variety:") { return LocalSpeechVoiceCatalog.varietyName(String(filter.dropFirst(8))) }
        if filter == "gender:female" { return LocalSpeechVoiceCatalog.genderName(.female) }
        if filter == "gender:male" { return LocalSpeechVoiceCatalog.genderName(.male) }
        return L10n.tr("All voices")
    }
    // The user's languages that the model speaks, in their order; otherwise
    // every language it speaks. The current voice language always stays listed.
    static func languages(supported: Set<String>, enabled: [String], current: String) -> [String] {
        var result = enabled.filter(supported.contains)
        if result.isEmpty { result = Language.catalog.map(\.id).filter(supported.contains) }
        if supported.contains(current), !result.contains(current) { result.append(current) }
        return result
    }
}

// The local model's voices for one language at a time: each row has readable
// details and its own sample. The first voice is the automatic default; a
// saved choice applies to this model and language only. Reference-based
// models instead choose the recording whose voice they imitate.
struct LocalVoiceSettings: View {
    @Binding var draft: Preferences
    @Binding var voiceLanguage: String
    // The saved voice for this model and language; empty means automatic.
    let selection: Binding<String>
    @ObservedObject var session: SpeechSettingsSession
    let snapshot: SpeechSettingsSnapshot
    let languages: [String]
    let allowsActions: Bool
    let preview: (SpeechSettingsSnapshot, String) -> Void
    let chooseReference: () -> Void
    @State private var filter = ""
    static let sampleTag = "reference:sample", customTag = "reference:custom"
    private static let rowHeight: CGFloat = 42
    private var modelID: String { draft.localSpeechModelID }
    private var requiresReference: Bool { LocalSpeechSynthesizer.requiresReferenceAudio(modelID: modelID) }
    private var rows: [LocalVoicePresentation.Row] {
        LocalVoicePresentation.rows(modelID: modelID, language: voiceLanguage)
    }
    private var languageName: String {
        Language.displayName(for: voiceLanguage, localized: draft.showLocalizedLanguageNames, locale: L10n.locale)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if requiresReference { referenceRows } else { voiceRows }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("speech-local-voices")
            .id(SettingsCustomizationGroup.speechVoices.rawValue)
            .onChange(of: voiceLanguage) { _, _ in filter = "" }
            .onChange(of: modelID) { _, _ in filter = "" }
    }
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                title
                Spacer(minLength: 0)
                languageSwitcher.fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                title
                languageSwitcher
            }
        }
    }
    private var title: some View {
        Text(L10n.tr("Voice")).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
    }
    @ViewBuilder private var languageSwitcher: some View {
        if languages.count > 1 {
            Picker(
                L10n.tr("Voice language"),
                selection: Binding(
                    get: { voiceLanguage },
                    set: {
                        session.cancel()
                        voiceLanguage = $0
                    })
            ) {
                ForEach(languages, id: \.self) {
                    Text(
                        Language.displayName(for: $0, localized: draft.showLocalizedLanguageNames, locale: L10n.locale)
                    ).tag($0)
                }
            }.labelsHidden().help(L10n.tr("Voice language")).accessibilityIdentifier("speech-voice-language")
        } else {
            Text(languageName).foregroundStyle(.secondary).accessibilityLabel(L10n.tr("Voice language"))
                .accessibilityValue(languageName)
        }
    }

    // MARK: Preset voices

    private var selectedID: String {
        let stored = selection.wrappedValue
        return stored.isEmpty ? rows.first?.id ?? "" : stored
    }
    private var unavailableSelection: String? {
        let stored = selection.wrappedValue
        return stored.isEmpty || rows.contains(where: { $0.id == stored }) ? nil : stored
    }
    @ViewBuilder private var voiceRows: some View {
        let all = rows, options = LocalVoicePresentation.filters(all)
        let active = options.contains(filter) ? filter : ""
        let visible = LocalVoicePresentation.filtered(all, by: active)
        if !options.isEmpty {
            Picker(L10n.tr("Show"), selection: $filter) {
                Text(LocalVoicePresentation.filterName("")).tag("")
                ForEach(options, id: \.self) { Text(LocalVoicePresentation.filterName($0)).tag($0) }
            }.fixedSize().accessibilityIdentifier("speech-local-voice-filter")
        }
        rowList(count: visible.count + (unavailableSelection == nil ? 0 : 1)) {
            if let stored = unavailableSelection {
                row(
                    tag: stored, name: L10n.tr("Unavailable voice"), detail: stored, recommended: false,
                    selected: true, playable: false, select: {})
            }
            ForEach(visible) { voice in
                row(
                    tag: voice.id, name: voice.name, detail: voice.detail, recommended: voice.recommended,
                    selected: unavailableSelection == nil && voice.id == selectedID, playable: true
                ) {
                    // Choosing the recommended voice returns to automatic.
                    selection.wrappedValue = voice.recommended ? "" : voice.id
                }
            }
        }
        Text(L10n.tr("This language only."))
            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Reference recording

    private var customPath: String { draft.localSpeechReferencePath }
    @ViewBuilder private var referenceRows: some View {
        rowList(count: customPath.isEmpty ? 1 : 2) {
            // Its provenance record: generated from the Kokoro preset af_heart.
            row(
                tag: Self.sampleTag, name: L10n.tr("Yullo sample voice"),
                detail: L10n.tr("Built-in") + " · "
                    + LocalSpeechVoiceCatalog.detail(for: "af_heart", modelID: "kokoro-82m-q8"),
                recommended: true, selected: customPath.isEmpty, playable: true
            ) {
                session.cancel()
                draft.localSpeechReferencePath = ""
            }
            if !customPath.isEmpty {
                row(
                    tag: Self.customTag, name: URL(fileURLWithPath: customPath).lastPathComponent,
                    detail: L10n.tr("Your recording"), recommended: false, selected: true, playable: true, select: {})
            }
        }
        Button(L10n.tr("Use my own recording…"), action: chooseReference)
            .help(L10n.tr("Optional. Choose a WAV voice sample between 0.5 and 30 seconds."))
            .accessibilityIdentifier("speech-local-reference-choose")
        Text(L10n.tr("WAV, one clear speaker, 0.5–30 s. Used for every language.")).font(.system(size: 12))
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Rows

    // Short lists show every row; a long list scrolls within about six rows.
    @ViewBuilder private func rowList<Content: View>(count: Int, @ViewBuilder content: () -> Content) -> some View {
        let stack = VStack(spacing: 0) { content() }
        Group {
            if count > 6 {
                ScrollView(.vertical) { stack }.frame(height: Self.rowHeight * 6.5)
            } else {
                stack
            }
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.22)))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityIdentifier("speech-local-voice-rows")
    }
    private func row(
        tag: String, name: String, detail: String, recommended: Bool, selected: Bool, playable: Bool,
        select: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Button(action: select) {
                HStack(spacing: 8) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            if recommended {
                                Text(L10n.tr("Recommended")).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .lineLimit(1).fixedSize()
                            }
                        }
                        if playable, session.action == .preview, session.previewVoiceID == tag {
                            ActivityStatus(
                                title: L10n.tr(session.isPlaying ? "Playing sample" : "Preparing sample…"),
                                glyph: session.isPlaying ? .playing : .working,
                                elapsedAfter: session.isPlaying ? nil : 3,
                                slowNote: L10n.tr("The voice model loads on first use."), size: 11)
                        } else if !detail.isEmpty {
                            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(recommended ? "\(name), \(L10n.tr("Recommended"))" : name)
                .accessibilityValue(detail).accessibilityAddTraits(selected ? .isSelected : [])
            if playable { sampleButton(tag: tag, name: name) }
        }
        .padding(.horizontal, 10).frame(height: Self.rowHeight)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear)
        .background {
            #if YULLO_TESTING
                YulloActionPresentationProbe(
                    title: "Local voice: " + tag, value: selected ? "selected" : detail, action: select)
            #endif
        }
    }
    private func sampleButton(tag: String, name: String) -> some View {
        let active = session.action == .preview && session.previewVoiceID == tag
        let loading = active && !session.isPlaying
        let label = L10n.tr(active ? "Stop" : "Play sample") + ": " + name
        let action = { if active { session.cancel() } else { playSample(tag) } }
        return Button(action: action) {
            // While a sample loads or plays, its row says which; this stays Stop.
            Image(systemName: active ? "stop.fill" : "play.fill").frame(width: 22, height: 24)
        }.buttonStyle(.borderless)
            .disabled(!allowsActions)
            .accessibilityLabel(label).help(label)
            .background {
                #if YULLO_TESTING
                    YulloActionPresentationProbe(
                        title: "Local voice sample: " + tag, value: loading ? "loading" : active ? "active" : "",
                        action: action)
                #endif
            }
    }
    private func playSample(_ tag: String) {
        var configuration = snapshot.configuration
        var reference = snapshot.localReferenceAudioURL
        if tag == Self.sampleTag {
            reference = nil
        } else if tag != Self.customTag {
            configuration.voiceIDsByLanguage[voiceLanguage] = tag
        }
        preview(
            SpeechSettingsSnapshot(
                provider: snapshot.provider, configuration: configuration, region: snapshot.region,
                language: voiceLanguage, rate: snapshot.rate, localReferenceAudioURL: reference,
                authorization: snapshot.authorization), tag)
    }
}
