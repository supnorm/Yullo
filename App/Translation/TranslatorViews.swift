import SwiftUI
import AppKit

private struct PinButton: View {
    @ObservedObject var session: WindowSession
    private var label: String { L10n.tr(session.isPinned ? "Unpin window" : "Keep window open") }
    var body: some View {
        Button {
            session.togglePin()
        } label: {
            Image(systemName: session.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 12)).frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .foregroundStyle(session.isPinned ? Palette.accent : .secondary)
            .help(session.isPinned ? label : label + "\n" + L10n.tr("Keep this window open when switching apps."))
            .accessibilityLabel(label)
    }
}

private struct DetectedLanguageIndicator: View {
    let languages: [String]
    let names: String
    private var label: String { L10n.format(languages.count > 1 ? "Detected languages: %@" : "Detected: %@", names) }
    var body: some View {
        Text(label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            .help(label).accessibilityLabel(label).accessibilityIdentifier("source-detected-languages")
    }
}

private struct SourceMetrics: View {
    let words: Int
    let characters: Int
    var body: some View {
        let wordText = L10n.format(words == 1 ? "%ld word" : "%ld words", words)
        let characterText = L10n.format(characters == 1 ? "%ld character" : "%ld characters", characters)
        Text(wordText + " · " + characterText)
            .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            .help(wordText + " · " + characterText)
            .accessibilityLabel(wordText + ", " + characterText)
    }
}

private struct SourceSpeechButton: View {
    @ObservedObject var model: Model
    private var active: Bool { model.speaking && model.speechSide == .source }
    var body: some View {
        Button {
            model.listen(.source)
        } label: {
            Image(systemName: active ? "stop.fill" : "speaker.wave.2")
                .font(.system(size: 12)).frame(width: 26, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(
            !active
                && (!model.hasSourceText || model.sourceVoiceUnavailable
                    || model.sourceVoiceState != .idle)
        )
        .help(L10n.tr(active ? "Stop reading aloud" : "Read source aloud"))
        .accessibilityLabel(L10n.tr(active ? "Stop reading aloud" : "Read source aloud"))
    }
}

private struct SourceDictationButton: View {
    @ObservedObject var model: Model
    let action: () -> Void
    private var recording: Bool { model.sourceVoiceState == .recording || model.sourceVoiceState == .paused }
    private var processing: Bool { model.sourceVoiceState == .processing }
    private var label: String {
        L10n.tr(recording ? "Finish recording" : processing ? "Voice input" : "Start dictation")
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: recording ? "stop.fill" : processing ? "ellipsis" : "mic")
                .font(.system(size: 12)).frame(width: 26, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .foregroundStyle(recording ? Palette.accent : .secondary)
            .disabled(processing || model.startSourceDictation == nil || (!recording && model.sourceVoiceUnavailable))
            .help(label).accessibilityLabel(label)
            .accessibilityValue(L10n.tr(model.sourceVoiceState == .paused ? "Paused" : recording ? "Listening" : ""))
    }
}

private struct TranslationSpeechButton: View {
    @ObservedObject var model: Model
    private var active: Bool { model.speaking && model.speechSide == .translation }
    private var label: String {
        L10n.tr(
            active
                ? "Stop reading aloud"
                : model.outputTitleKey == "Translation" ? "Read translation aloud" : "Read aloud")
    }
    var body: some View {
        Button {
            model.listen()
        } label: {
            Image(systemName: active ? "stop.fill" : "speaker.wave.2")
                .font(.system(size: 12)).frame(width: 26, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(
            !model.canUseOutput || model.sourceVoiceUnavailable || model.sourceVoiceState != .idle
        )
        .help(label).accessibilityLabel(label)
    }
}

private struct PronunciationSpeedButton: View {
    @ObservedObject var model: Model
    var body: some View {
        Button {
            model.stopSpeaking()
            model.slowSpeech.toggle()
        } label: {
            Image(systemName: model.slowSpeech ? "tortoise.fill" : "tortoise")
                .font(.system(size: 12)).frame(width: 26, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(model.slowSpeech ? Palette.accent : .secondary)
            .help(L10n.tr("Read slowly"))
            .accessibilityLabel(L10n.tr("Read slowly"))
            .accessibilityValue(L10n.tr(model.slowSpeech ? "On" : "Off"))
            .accessibilityAddTraits(.isToggle)
    }
}

private struct TranslationWritingActions: View {
    @ObservedObject var model: Model
    var compact = false
    @State private var formats: YourFormatsRoute?
    private var presets: CoreDictationPresetsConfiguration { model.preferences.dictationPresets }
    private func formatButton(_ format: String, title: String) -> some View {
        Button {
            model.refineFormat(format)
        } label: {
            Text(title)
            if model.isRefineFormatSelected(format) { Image(systemName: "checkmark") }
        }
    }
    private var formatsSheet: some View {
        YourFormatsSheet(
            preferences: Binding(
                get: { model.preferences }, set: { model.apply($0, restartAutomaticTranslation: false) }),
            start: formats ?? .list, allowsSpoken: false,
            chosen: { model.refineFormat($0) }, close: { formats = nil }
        ).environment(
            \.setUpWritingService, WritingServiceSetUp(open: { _ in model.openTranslationRecovery?(.writingService) })
        ).glassSheet()
    }
    private var selectionDescription: String {
        guard let selection = model.translationWritingSelection else {
            return L10n.tr(model.translationWritingAvailable ? "Choose a style" : "Writing service…")
        }
        if selection.preset != nil {
            return model.translationWritingLabel + " · " + WritingStylePresentation.title(selection.style)
        }
        return model.translationWritingLabel
    }

    // Refine selected text has no translation to stand in for.
    private var sourceEntryKey: String { model.selectionRefinesOnly ? "Refine" : "Refine instead…" }
    private var labelTitle: String {
        if model.translationWritingSelection != nil { return model.translationWritingLabel }
        if model.canRefineInstead { return L10n.tr(sourceEntryKey) }
        if !model.canRefineTranslation { return L10n.tr("Refined text") }
        return L10n.tr(model.translationWritingAvailable ? "Refine" : "Writing service…")
    }

    @ViewBuilder private var menuContent: some View {
        if model.canRefineTranslation && model.translationWritingAvailable {
            ForEach(Array(OutputPresentation.formatGroups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(group.filter { $0 != CoreOutput.spoken.format }, id: \.self) { format in
                    formatButton(format, title: OutputPresentation.formatTitle(format, presets: presets))
                }
            }
            if !model.availableTranslationWritingPresets.isEmpty {
                Divider()
                ForEach(model.availableTranslationWritingPresets) { record in
                    formatButton(CoreOutput.preset(record.id).format, title: DictationPresetPresentation.title(record))
                }
            }
            Divider()
            Button(L10n.tr("New format…")) {
                formats = .new
            }
            if !YourFormats.records(presets).isEmpty {
                Button(L10n.tr("Edit formats…")) { formats = .list }
            }
        } else if model.canRefineTranslation {
            Button(L10n.tr("Writing service…")) {
                guard model.canRefineTranslation else { return }
                model.openTranslationRecovery?(.writingService)
            }
            if model.preferences.pausedTasks.contains(.writing) {
                Text(L10n.tr("Yullo works on this Mac only. API and CLI services are off."))
            }
        }
        if model.canRestoreUnadjustedTranslation {
            if model.canRefineTranslation { Divider() }
            if model.canCompareTranslation {
                Button(L10n.tr("Compare"), action: model.compareTranslation)
            }
            Button(L10n.tr(model.translationRestoreTitleKey), action: model.restoreUnadjustedTranslation)
        }
    }

    var body: some View {
        let sourceAlternative = model.canRefineInstead
        return Group {
            if model.refiningTranslation {
                Text(L10n.tr("Refining")).foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.tr("Refining"))
            } else if !model.canRefineTranslation && model.canRestoreUnadjustedTranslation
                && !model.canCompareTranslation
            {
                Button(action: model.restoreUnadjustedTranslation) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12)).frame(width: 26, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).help(L10n.tr(model.translationRestoreTitleKey))
                    .accessibilityLabel(L10n.tr(model.translationRestoreTitleKey))
                    .background {
                        #if YULLO_TESTING
                            YulloActionPresentationProbe(
                                title: model.translationRestoreTitleKey, action: model.restoreUnadjustedTranslation)
                        #endif
                    }
            } else if model.canRefineTranslation || model.canRestoreUnadjustedTranslation {
                Menu {
                    menuContent
                } label: {
                    Text(labelTitle).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: compact ? 112 : 180, alignment: .leading)
                }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(
                        L10n.tr(
                            sourceAlternative
                                ? sourceEntryKey : model.canRefineTranslation ? "Refine translation" : "Refined text"
                        )
                    )
                    .accessibilityValue(selectionDescription)
                    .help(
                        (model.translationWritingSelection == nil ? "" : selectionDescription + "\n")
                            + L10n.tr(
                                sourceAlternative
                                    ? (model.selectionRefinesOnly
                                        ? "Refine the text in its own language." : "Refine instead…")
                                    : model.canRefineTranslation
                                        ? "Refine the original translation with your writing service."
                                        : model.translationRestoreTitleKey)
                    )
                    .background {
                        #if YULLO_TESTING
                            YulloActionPresentationProbe(
                                title: sourceAlternative
                                    ? sourceEntryKey
                                    : model.canRefineTranslation ? "Refine translation" : "Refined text",
                                value: selectionDescription, action: {})
                        #endif
                    }
            }
        }.sheet(item: $formats) { _ in formatsSheet }
    }
}

private struct OutputActionButton: View {
    @ObservedObject var model: Model
    // Off while the source is being edited: Return is the editor's then.
    var returnKeyShown = true
    private var returnCopies: Bool {
        returnKeyShown && model.selectionContext && !model.selectionOffersReplacement
    }
    var body: some View {
        Group {
            if model.refiningTranslation {
                Button(L10n.tr("Cancel"), action: model.cancelTranslationRefinement)
                    .buttonStyle(.plain).accessibilityLabel(L10n.tr("Cancel refinement"))
                    .background {
                        #if YULLO_TESTING
                            YulloActionPresentationProbe(
                                title: "Cancel refinement", action: model.cancelTranslationRefinement)
                        #endif
                    }
            } else if model.isTranslationPending {
                Button(L10n.tr("Cancel")) { model.cancelTranslation() }
                    .background {
                        #if YULLO_TESTING
                            YulloActionPresentationProbe(title: "Cancel", action: model.cancelTranslation)
                        #endif
                    }.buttonStyle(.plain).help(
                        L10n.tr("Cancel translation")
                            + (model.canUseBuiltInLocalShortcut(ShortcutProfile.localCancel)
                                ? " · " + ShortcutProfile.localCancel.displayLabel : ""))
            } else if model.shouldOfferManualTranslation {
                Button(L10n.tr(model.shouldOfferTranslationRetry ? "Retry" : "Translate"), action: model.translate)
                    .background {
                        #if YULLO_TESTING
                            YulloActionPresentationProbe(
                                title: model.shouldOfferTranslationRetry ? "Retry" : "Translate",
                                action: model.translate)
                        #endif
                    }
                    .buttonStyle(.borderedProminent).tint(Palette.button)
                    .help(
                        model.preferences.localTranslateShortcut.isAssigned
                            ? L10n.tr("Translate") + " · " + model.preferences.localTranslateShortcut.displayLabel
                            : L10n.tr("Translate")
                    )
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                Button {
                    model.copyTranslation()
                } label: {
                    HStack(spacing: 4) {
                        // Confirm on the button, not in a footer, and keep the glyph's space so nothing resizes.
                        Image(systemName: "doc.on.doc").opacity(model.copyConfirmationVisible ? 0 : 1)
                            .overlay {
                                if model.copyConfirmationVisible {
                                    Image(systemName: "checkmark").foregroundStyle(Palette.accent)
                                }
                            }
                        // In a read-only selection ↩ copies, closes and goes back.
                        if returnCopies {
                            Text("↩").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .background {
                    #if YULLO_TESTING
                        YulloActionPresentationProbe(
                            title: model.outputCopyTitleKey,
                            value: model.copyConfirmationVisible ? "Copied" : "", action: model.copyTranslation)
                    #endif
                }.disabled(!model.canUseOutput)
                .help(
                    model.copyConfirmationVisible
                        ? L10n.tr("Copied")
                        // One action, one key: the one the button shows. ↩ always closes;
                        // the copy shortcut closes unless the window is pinned.
                        : returnCopies
                            ? L10n.tr("Copy and close") + " · ↩"
                            : L10n.tr(model.windowSession.isPinned ? model.outputCopyTitleKey : "Copy and close")
                                + " · " + model.preferences.copyShortcut.displayLabel
                )
                .accessibilityLabel(L10n.tr(model.outputCopyTitleKey))
                .accessibilityValue(model.copyConfirmationVisible ? L10n.tr("Copied") : "")
            }
        }.fixedSize(horizontal: true, vertical: false).frame(minWidth: 46).frame(height: 28)
    }
}

private struct TranslationFooter: View {
    @ObservedObject var model: Model
    let horizontalPadding: CGFloat
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 10 : 12) {
            VStack(alignment: .leading, spacing: 4) {
                if model.copyFailed { Text(L10n.tr("Couldn’t copy. Try again.")) }
                if let review = model.translationWritingReviewNotice {
                    Text(review).fixedSize(horizontal: false, vertical: true)
                }
                if !model.notice.isEmpty {
                    // Beside "Choose Another Service…", the notice gives only the reason.
                    Text(TranslationRecoveryAction.notice(model.notice, fix: model.translationRecoveryAction))
                        .lineLimit(model.translationRecoveryAction == nil ? (compact ? 3 : 2) : nil)
                        .fixedSize(horizontal: false, vertical: true).help(
                            model.notice == L10n.tr("Translated with Apple")
                                ? L10n.tr(
                                    "Your translation service wasn’t available. Check it in Translation settings."
                                )
                                : model.notice)
                }
                // Before any attempt, explain the missing connection the same way a failed attempt does.
                if model.needsTranslationConnection, model.notice.isEmpty, model.translationRecoveryAction == nil {
                    Text(L10n.tr("No translation service is set up."))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: compact ? 0 : 8)
            if let recovery = model.translationRecoveryAction {
                let title = recovery.titleKey(writingSetup: model.needsWritingServiceSetup)
                Button(L10n.tr(title)) {
                    model.openTranslationRecovery?(recovery)
                }.buttonStyle(.link)
                    .accessibilityIdentifier("translation-recovery")
                    .background {
                        #if YULLO_TESTING
                            YulloActionPresentationProbe(
                                title: title,
                                action: { model.openTranslationRecovery?(recovery) })
                        #endif
                    }
            } else if model.needsTranslationConnection {
                Button(L10n.tr("Service settings…")) { model.openTranslationRecovery?(.service) }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("translation-recovery")
                    .background {
                        #if YULLO_TESTING
                            YulloActionPresentationProbe(
                                title: "Service settings…", action: { model.openTranslationRecovery?(.service) })
                        #endif
                    }
            } else if model.shouldOfferTranslationRetryInFooter || model.canRetryPreferredTranslation {
                Button(L10n.tr(model.canRetryPreferredTranslation ? "Retry API" : "Retry")) { model.retryTranslation() }
                    .background {
                        #if YULLO_TESTING
                            YulloActionPresentationProbe(
                                title: model.canRetryPreferredTranslation ? "Retry API" : "Retry",
                                action: model.retryTranslation)
                        #endif
                    }
                    .buttonStyle(.borderedProminent).tint(Palette.button)
            }
        }.font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, horizontalPadding).padding(.vertical, 12)
    }
}

#if YULLO_TESTING
    // Unshown SwiftUI trees do not publish an accessibility action tree. This
    // native background observes the actual control's layout and enabled state;
    // it receives the same action and never participates in hit testing.
    struct YulloActionPresentationProbe: NSViewRepresentable {
        let title: String
        var value = ""
        let action: () -> Void
        @Environment(\.isEnabled) private var isEnabled
        final class ProbeView: NSView {
            var actionTitle = ""
            var actionValue = ""
            var actionEnabled = false
            var action: (() -> Void)?
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
        func makeNSView(context: Context) -> ProbeView { ProbeView(frame: .zero) }
        func updateNSView(_ view: ProbeView, context: Context) {
            view.actionTitle = title
            view.actionValue = value
            view.actionEnabled = isEnabled
            view.action = action
        }
    }
#endif

@available(macOS 26.0, *)
struct SelectionView: View {
    @ObservedObject var model: Model
    @Environment(\.colorScheme) var colorScheme
    @State private var editingSource = false
    @FocusState private var sourceFocused: Bool
    @State private var choosingTarget = false
    // Rebuilt when the interface language changes, so every label follows it.
    var body: some View {
        localizedBody.id(model.preferences.interfaceLanguage)
            .sheet(isPresented: $choosingTarget) {
                MoreLanguagesSheet(
                    localizedNames: model.preferences.showLocalizedLanguageNames,
                    excluded: Language.enabled(model.preferences.enabledLanguages).map(\.id),
                    choose: { id, _ in
                        choosingTarget = false
                        model.chooseNewTargetLanguage(id)
                    }, cancel: { choosingTarget = false }, offersAdding: false
                ).glassSheet()
            }
    }
    private var localizedBody: some View {
        GeometryReader { geometry in
            let sourceHeight = max(64, min(240, 64 + (geometry.size.height - 440) * 0.3))
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    HStack {
                        BrandMark(size: 14)
                        Text(L10n.tr("Yullo")).font(BrandTypography.wordmark(size: 12))
                        Spacer()
                    }.frame(height: 24).allowsHitTesting(false)
                    PinButton(session: model.windowSession)
                    Button {
                        model.openSettings?()
                    } label: {
                        Image(systemName: "gearshape").font(.system(size: 12)).frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(.secondary).help(L10n.tr("Settings · ⌘,")).accessibilityLabel(
                        L10n.tr("Settings"))
                }.padding(.horizontal, 20).padding(.vertical, 16)
                    .background { WindowDragRegion().help(L10n.tr("Drag to move")).accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        Group {
                            if editingSource {
                                TextEditor(text: $model.source).font(.system(size: 13)).scrollContentBackground(.hidden)
                                    .scrollIndicators(.automatic).autohidingTextEditorScrollbars()
                                    .focused($sourceFocused).accessibilityLabel(L10n.tr("Source text"))
                            } else {
                                ScrollView(.vertical) {
                                    Text(model.source).font(.system(size: 13)).foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .lineLimit(nil).fixedSize(horizontal: false, vertical: true).frame(
                                            maxWidth: .infinity, alignment: .leading)
                                }.scrollIndicators(.visible)
                            }
                        }.frame(height: sourceHeight)
                        if model.sourceLanguage == "auto", !model.detectedLanguages.isEmpty {
                            DetectedLanguageIndicator(
                                languages: model.detectedLanguages, names: model.detectedLanguageLabel)
                        }
                        HStack(spacing: 6) {
                            SourceMetrics(words: model.sourceWordCount, characters: model.sourceCharacterCount)
                            Spacer(minLength: 0)
                            Button {
                                editingSource.toggle()
                                sourceFocused = editingSource
                            } label: {
                                Image(systemName: editingSource ? "checkmark" : "pencil").font(.system(size: 12)).frame(
                                    width: 24, height: 28)
                            }.buttonStyle(.plain).help(L10n.tr(editingSource ? "Done editing" : "Edit source text"))
                                .accessibilityLabel(L10n.tr(editingSource ? "Done editing" : "Edit source text"))
                            SourceDictationButton(model: model, action: dictateSource)
                            SourceSpeechButton(model: model)
                        }.frame(height: 22)
                        if let edit = model.editSelectionWithVoice {
                            HStack {
                                Spacer(minLength: 0)
                                Button(L10n.tr("Edit with voice…"), action: edit)
                                    .buttonStyle(.link).font(.system(size: 12))
                                    .keyboardShortcut("e", modifiers: .command)
                                    .disabled(
                                        model.sourceVoiceUnavailable || model.source.isEmpty || model.replacingSelection
                                    )
                                    .help(
                                        L10n.tr("Say how to change the selected text, then review before replacing it.")
                                    )
                                    .accessibilityIdentifier("selection-voice-edit")
                                // The same quiet key look as the guide's key column.
                                Text(verbatim: "⌘E").font(.system(size: 12)).foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                    }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Menu {
                                Button(L10n.tr("Auto-detect")) { model.chooseSourceLanguage("auto") }
                                ForEach(Language.enabled(model.preferences.enabledLanguages)) { language in
                                    Button(
                                        language.displayName(
                                            localized: model.preferences.showLocalizedLanguageNames, locale: L10n.locale
                                        )
                                    ) { model.chooseSourceLanguage(language.id) }
                                }
                            } label: {
                                Text(
                                    Language.catalog.first { $0.id == model.sourceLanguage }?.displayName(
                                        localized: model.preferences.showLocalizedLanguageNames, locale: L10n.locale)
                                        ?? L10n.tr("Auto-detect")
                                ).font(.system(size: 12))
                            }.menuStyle(.borderlessButton)
                                .fixedSize(horizontal: !model.preferences.showLocalizedLanguageNames, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityLabel(L10n.tr("From"))
                                .accessibilityValue(
                                    Language.catalog.first { $0.id == model.sourceLanguage }?.displayName(
                                        localized: model.preferences.showLocalizedLanguageNames, locale: L10n.locale)
                                        ?? L10n.tr("Auto-detect")
                                )
                                .accessibilityIdentifier("selection-source-language")
                                .help(
                                    Language.catalog.first { $0.id == model.sourceLanguage }?.displayName(
                                        localized: model.preferences.showLocalizedLanguageNames, locale: L10n.locale)
                                        ?? L10n.tr("Auto-detect"))
                            Button {
                                model.swapLanguages()
                            } label: {
                                Image(systemName: "arrow.left.arrow.right").font(.system(size: 12)).frame(
                                    width: 36, height: 32
                                ).contentShape(Rectangle())
                            }.buttonStyle(.plain).foregroundStyle(.secondary).help(L10n.tr("Swap languages"))
                                .accessibilityLabel(L10n.tr("Swap languages")).disabled(
                                    model.isTranslationPending || model.outputIsStale)
                            Menu {
                                ForEach(Language.enabled(model.preferences.enabledLanguages)) { language in
                                    Button(
                                        language.displayName(
                                            localized: model.preferences.showLocalizedLanguageNames, locale: L10n.locale
                                        )
                                    ) { model.chooseTargetLanguage(language.id) }
                                }
                                Divider()
                                Button(L10n.tr("More languages…")) { choosingTarget = true }
                            } label: {
                                Text(
                                    Language.catalog.first { $0.id == model.targetLanguage }?.displayName(
                                        localized: model.preferences.showLocalizedLanguageNames, locale: L10n.locale)
                                        ?? "English"
                                ).font(
                                    .system(size: 13, weight: .semibold))
                            }.menuStyle(.borderlessButton)
                                .fixedSize(horizontal: !model.preferences.showLocalizedLanguageNames, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .accessibilityLabel(L10n.tr("To"))
                                .accessibilityValue(
                                    Language.catalog.first { $0.id == model.targetLanguage }?.displayName(
                                        localized: model.preferences.showLocalizedLanguageNames, locale: L10n.locale)
                                        ?? "English"
                                )
                                .accessibilityIdentifier("selection-target-language")
                                .help(
                                    Language.catalog.first { $0.id == model.targetLanguage }?.displayName(
                                        localized: model.preferences.showLocalizedLanguageNames, locale: L10n.locale)
                                        ?? "English")
                        }
                        TranslationOutputViewport(model: model, size: model.textSize - 1)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if model.hasSameLanguageWritingContext {
                            HStack {
                                TranslationWritingActions(model: model)
                                Spacer(minLength: 0)
                            }.font(.system(size: 12)).frame(height: 28)
                        }
                        HStack(spacing: 12) {
                            TranslationSpeechButton(model: model)
                            PronunciationSpeedButton(model: model)
                            Spacer(minLength: 2)
                            if !model.hasSameLanguageWritingContext {
                                TranslationWritingActions(model: model, compact: true)
                            }
                            // Read-only page selections have no write path, so Replace is not offered;
                            // nor is it for a translation with part of the source left as it was.
                            if model.selectionOffersReplacement && !model.translationIncomplete {
                                // ↩ replaces here, so the button names it.
                                Button {
                                    model.replaceSelection()
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(L10n.tr(model.replacingSelection ? "Replacing…" : "Replace"))
                                        if !model.replacingSelection, !sourceFocused {
                                            Text("↩").font(.system(size: 10)).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
                                .background {
                                    #if YULLO_TESTING
                                        YulloActionPresentationProbe(
                                            title: "Replace selection", action: model.replaceSelection)
                                    #endif
                                }
                                .disabled(!model.canReplaceSelection)
                                .help(
                                    // The key the button shows; while the source is edited, ↩ is the editor's.
                                    L10n.tr("Replace the selection in the original app.") + " · "
                                        + (sourceFocused ? model.preferences.replaceShortcut.displayLabel : "↩")
                                )
                                .accessibilityLabel(L10n.tr("Replace selection"))
                            }
                            OutputActionButton(model: model, returnKeyShown: !sourceFocused)
                        }.font(.system(size: 12)).frame(height: 28)
                    }.padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }.background(PaneSurface(vertical: true)).clipShape(RoundedRectangle(cornerRadius: 15)).padding(
                    .horizontal, 10
                ).padding(.bottom, model.showsTranslationFooter ? 0 : 10)
                if model.showsTranslationFooter {
                    TranslationFooter(model: model, horizontalPadding: 20, compact: true)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(
            minWidth: AppWindowSizing.selectionMinimum.width, maxWidth: .infinity,
            minHeight: AppWindowSizing.selectionMinimum.height, maxHeight: .infinity
        ).environment(\.locale, L10n.locale).preferredColorScheme(model.appearance).background {
            YulloPanelBackground(cornerRadius: 23)
        }
        .onAppear { resetSourceEditing() }
        .onChange(of: model.selectionRevision) { _, _ in resetSourceEditing() }
    }
    private func resetSourceEditing() {
        editingSource = model.preferences.selectedTextStartsEditable
        Task { @MainActor in
            await Task.yield()
            sourceFocused = editingSource
        }
    }
    private func dictateSource() {
        if model.sourceVoiceState == .recording || model.sourceVoiceState == .paused {
            model.startSourceDictation?()
            return
        }
        guard model.sourceVoiceState == .idle, !model.sourceVoiceUnavailable else { return }
        editingSource = true
        sourceFocused = true
        let revision = model.selectionRevision
        Task { @MainActor in
            await Task.yield()
            guard model.selectionRevision == revision, model.selectionContext else { return }
            model.startSourceDictation?()
        }
    }

}

@available(macOS 26.0, *)
struct MainView: View {
    @ObservedObject var model: Model
    @Environment(\.colorScheme) var colorScheme
    @FocusState private var sourceFocused: Bool
    private var ink: Color { colorScheme == .dark ? .white : Color(red: 0.12, green: 0.16, blue: 0.19) }
    @State private var choosingTarget = false
    // Rebuilt when the interface language changes, so every label follows it.
    var body: some View {
        localizedBody.id(model.preferences.interfaceLanguage)
            .sheet(isPresented: $choosingTarget) {
                MoreLanguagesSheet(
                    localizedNames: model.preferences.showLocalizedLanguageNames,
                    excluded: Language.enabled(model.preferences.enabledLanguages).map(\.id),
                    choose: { id, _ in
                        choosingTarget = false
                        model.chooseNewTargetLanguage(id)
                    }, cancel: { choosingTarget = false }, offersAdding: false
                ).glassSheet()
            }
    }
    private var localizedBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                HStack(spacing: 9) {
                    BrandMark()
                    Text(L10n.tr("Yullo")).font(BrandTypography.wordmark(size: 14))
                    Spacer()
                }.frame(height: 28).allowsHitTesting(false)
                PinButton(session: model.windowSession)
                Button {
                    model.openSettings?()
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 12)).frame(width: 28, height: 28).contentShape(
                        Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary).help(L10n.tr("Settings · ⌘,")).accessibilityLabel(
                    L10n.tr("Settings"))
            }.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 14)
                .background { WindowDragRegion().help(L10n.tr("Drag to move")).accessibilityHidden(true) }
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        languageMenu(source: true)
                        if model.sourceLanguage == "auto", !model.detectedLanguages.isEmpty {
                            DetectedLanguageIndicator(
                                languages: model.detectedLanguages, names: model.detectedLanguageLabel)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        languageMenu(source: false)
                        Spacer()
                    }.padding(.leading, 22).frame(maxWidth: .infinity)
                }.frame(height: 40, alignment: .top)
                    .overlay(alignment: .top) {
                        Button {
                            model.swapLanguages()
                        } label: {
                            Image(systemName: "arrow.left.arrow.right").font(.system(size: 12)).frame(
                                width: 36, height: 36
                            ).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(.secondary).offset(y: -4).help(L10n.tr("Swap languages"))
                            .accessibilityLabel(L10n.tr("Swap languages")).disabled(
                                model.isTranslationPending || model.outputIsStale)
                    }
                    .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 8)
                HStack(alignment: .top, spacing: 44) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextEditor(text: $model.source)
                            .font(
                                .system(size: model.textSize, weight: model.preferences.textBold ? .semibold : .regular)
                            )
                            .scrollContentBackground(.hidden).lineSpacing(5).foregroundStyle(ink)
                            .frame(minHeight: 64, maxHeight: .infinity).scrollIndicators(.automatic)
                            .autohidingTextEditorScrollbars()
                            .focused($sourceFocused)
                            .accessibilityLabel(L10n.tr("Source text"))
                        HStack(spacing: 8) {
                            SourceMetrics(words: model.sourceWordCount, characters: model.sourceCharacterCount)
                            Spacer(minLength: 0)
                            SourceDictationButton(model: model, action: dictateSource)
                            SourceSpeechButton(model: model)
                            Button {
                                model.source = ""
                                model.notice = ""
                                sourceFocused = true
                            } label: {
                                Image(systemName: "xmark.circle").font(.system(size: 12)).frame(width: 26, height: 28)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).foregroundStyle(.secondary).help(L10n.tr("Clear")).accessibilityLabel(
                                L10n.tr("Clear"))
                        }.font(.system(size: 11)).frame(height: 30)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 12) {
                        TranslationOutputViewport(
                            model: model, size: model.textSize, color: ink, topInset: 4
                        ).frame(maxWidth: .infinity, maxHeight: .infinity)

                        HStack(spacing: 10) {
                            TranslationSpeechButton(model: model)
                            PronunciationSpeedButton(model: model)
                            Spacer(minLength: 0)
                            TranslationWritingActions(model: model)
                            OutputActionButton(model: model)
                        }.font(.system(size: 12, weight: .medium)).frame(height: 30)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 22).padding(.top, 20).padding(
                    .bottom, 14)
            }.background(PaneSurface()).clipShape(RoundedRectangle(cornerRadius: 17)).padding(.horizontal, 12).padding(
                .bottom, model.showsTranslationFooter ? 0 : 12)
            if model.showsTranslationFooter {
                TranslationFooter(model: model, horizontalPadding: 24)
            }
        }.frame(
            minWidth: AppWindowSizing.mainMinimum.width, maxWidth: .infinity,
            minHeight: AppWindowSizing.mainMinimum.height, maxHeight: .infinity
        )
        .background {
            YulloPanelBackground(cornerRadius: 26)
        }
        .environment(\.locale, L10n.locale).preferredColorScheme(model.appearance)
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                guard !model.selectionContext else { return }
                sourceFocused = true
            }
        }
        // The hosting view outlives each presentation, so onAppear runs only once.
        .onChange(of: model.sourceFocusRequest) { _, _ in
            Task { @MainActor in
                await Task.yield()
                guard !model.selectionContext, model.sourceVoiceState == .idle else { return }
                sourceFocused = true
            }
        }
    }
    private func dictateSource() {
        if model.sourceVoiceState == .recording || model.sourceVoiceState == .paused {
            model.startSourceDictation?()
            return
        }
        guard model.sourceVoiceState == .idle, !model.sourceVoiceUnavailable else { return }
        sourceFocused = true
        Task { @MainActor in
            await Task.yield()
            guard !model.selectionContext else { return }
            model.startSourceDictation?()
        }
    }
    func languageMenu(source: Bool) -> some View {
        let id = source ? model.sourceLanguage : model.targetLanguage
        let name =
            id == "auto"
            ? L10n.tr("Auto-detect")
            : Language.displayName(
                for: id, localized: model.preferences.showLocalizedLanguageNames, locale: L10n.locale)
        return Menu {
            if source { Button(L10n.tr("Auto-detect")) { model.chooseSourceLanguage("auto") } }
            ForEach(Language.enabled(model.preferences.enabledLanguages)) { lang in
                Button(lang.displayName(localized: model.preferences.showLocalizedLanguageNames, locale: L10n.locale)) {
                    if source { model.chooseSourceLanguage(lang.id) } else { model.chooseTargetLanguage(lang.id) }
                }
            }
            // Translating out of your languages stays one choice away, even with only one.
            if !source {
                Divider()
                Button(L10n.tr("More languages…")) { choosingTarget = true }
            }
        } label: {
            Text(name)
                .font(.system(size: 13, weight: .semibold)).padding(.vertical, 5)
        }.menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel(L10n.tr(source ? "From" : "To"))
            .accessibilityValue(name).help(name)
            .accessibilityIdentifier(source ? "main-source-language" : "main-target-language")
    }
}
