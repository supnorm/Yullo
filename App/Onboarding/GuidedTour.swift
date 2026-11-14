import SwiftUI

// The guide's last step shows the other everyday tasks, each with its working
// global shortcut and one explicit Try on a sample sentence. A Try runs only on
// click, sends only the sample with the current task settings, and writes no
// preference, History record or translator text.
enum GuidedTourTask: Equatable { case translate, refine, refineInPlace, readAloud, editWithVoice, editWithText }

enum GuidedTourSpeech: Equatable { case idle, preparing, playing, failed(String) }

// The Explore row for dictating into the default mail app. Only a click adds its
// What dictation writes row (Email); nothing else is turned on here.
enum GuidedEmailRule: Equatable {
    case available
    // A row exists; a paused one is turned on with its own click.
    case added(enabled: Bool)
    // One blocker at a time, each named with its own fix.
    case needsWritingService

    static func state(_ preferences: Preferences, mail: MailApplication) -> GuidedEmailRule {
        if let rule = preferences.outputs.rules.first(where: {
            $0.applicationBundleID.caseInsensitiveCompare(mail.bundleID) == .orderedSame
        }) {
            return .added(enabled: rule.enabled)
        }
        return VoiceWritingConnection.isConfigured(preferences) ? .available : .needsWritingService
    }
}

// A Try's result, and when a service other than the chosen one produced it, the words
// that say so (the same as the Yullo window's), never a silent swap.
struct GuidedTourReply: Equatable, Sendable {
    let text: String
    var note: String? = nil
}

// The app owner supplies the real task routes; generated checks inject fakes.
struct GuidedTourActions {
    var translate: @MainActor (_ text: String, _ source: String, _ target: String) async throws -> GuidedTourReply
    var refine: @MainActor (_ text: String) async throws -> GuidedTourReply
    // Refine in place's first row: the sample rewritten as that row's output.
    var refineInPlace: @MainActor (_ text: String) async throws -> GuidedTourReply = { _ in throw CancellationError() }
    var speak: @MainActor (_ text: String, _ language: String) -> Void
    var stopSpeaking: @MainActor () -> Void
    var speech: @MainActor () -> GuidedTourSpeech
    // A Mac voice read the sample in place of the chosen voice service.
    var speechNote: @MainActor () -> String? = { nil }
    // Edit with voice on the sample: the spoken change, then the real review window.
    // False when it cannot start now.
    // Replace hands the edited text back for the Sample card.
    var editWithVoice: @MainActor (_ text: String, _ replace: @escaping (String) -> Void) -> Bool = { _, _ in false }
    // Edit with text on the sample: the review window as its request field, under the Sample card.
    var editWithText: @MainActor (_ text: String, _ replace: @escaping (String) -> Void) -> Bool = { _, _ in false }

    // The same routes Translate selected text, Refine selected text and the
    // translator's speaker use, without their editor, History or retry state.
    // Checks pass their own services with fake engines; the routes stay the same.
    @MainActor static func live(
        _ model: Model, translation: TranslationService = .shared, refinement: RefinementService = .shared
    ) -> GuidedTourActions {
        GuidedTourActions(
            translate: { text, source, target in
                let settings = TranslationSettings(model.preferences)
                do {
                    let result = try await translation.translate(
                        text: text, source: source, target: target, settings: settings)
                    let standIn = result.usedAnyApple && settings.engine != "apple"
                    return .init(text: try result.finished(), note: standIn ? result.appleFallbackNotice : nil)
                } catch let failure as TranslationRoute.Failure {
                    throw failure.api
                }
            },
            refine: { text in
                let choice = model.selectionWritingChoice
                let result = try await refinement.refineNoted(
                    text: text, style: choice.style, settings: model.writingSettings(for: choice))
                return .init(text: result.text, note: result.note)
            },
            refineInPlace: { text in
                let preferences = model.preferences
                guard let row = preferences.outputs.refineInPlace.first else { return .init(text: text) }
                let plan = CoreOutputPlan.make(
                    for: row.output, presets: preferences.dictationPresets,
                    defaultStyle: RewriteStyle(rawValue: preferences.voiceRefinementStyle) ?? .light,
                    fallbackLanguage: GuidedTourSample.language)
                let result = try await RefineInPlaceController.rewriteNoted(text, plan: plan, preferences: preferences)
                return .init(text: result.text, note: result.note)
            },
            speak: { model.speakSample($0, language: $1) },
            stopSpeaking: { if model.speechSide == .sample { model.stopSpeaking() } },
            speech: {
                guard model.speaking, model.speechSide == .sample else {
                    return model.sampleSpeechIssue.map(GuidedTourSpeech.failed) ?? .idle
                }
                return model.speechAudible ? .playing : .preparing
            }, speechNote: { model.sampleSpeechNote })
    }
}

enum GuidedTourSample {
    // Written in the interface language, so the person can read what each Try changes;
    // casual and unpolished, as people type and speak, so every format visibly changes it.
    static var language: String { Language.canonicalCode(L10n.language) }
    // Five everyday notes, one picked at random each launch, so the guide doesn't always
    // show the same text. Checks keep the first, so their stubbed results still match.
    static let keys = [
        "hey so can we push tomorrow’s meeting to thursday afternoon? i’ll bring the notes, thanks",
        "ok so i finished the draft but the intro feels kinda long, can you take a look before friday? no rush",
        "hi! just landed, the flight was late so i’ll get to the hotel around 9, can you please keep my room",
        "so for saturday we could bring the salad and some drinks, just tell me if you need anything else",
        "quick update the numbers look better this week but we still need the slides by monday morning ok"
    ]
    static var index: Int = {
        #if YULLO_TESTING
            return 0
        #else
            return Int.random(in: 0..<keys.count)
        #endif
    }()
    static var text: String {
        switch index {
        case 1:
            L10n.tr(
                "ok so i finished the draft but the intro feels kinda long, can you take a look before friday? no rush")
        case 2:
            L10n.tr(
                "hi! just landed, the flight was late so i’ll get to the hotel around 9, can you please keep my room")
        case 3:
            L10n.tr("so for saturday we could bring the salad and some drinks, just tell me if you need anything else")
        case 4:
            L10n.tr("quick update the numbers look better this week but we still need the slides by monday morning ok")
        default: L10n.tr("hey so can we push tomorrow’s meeting to thursday afternoon? i’ll bring the notes, thanks")
        }
    }
    // A sample to translate when the target is the sample's own language: the same
    // sentence as it reads in another of Yullo's languages, so Try shows a real
    // translation into the person's language rather than a copy.
    static func foreign(into target: String) -> (text: String, language: String)? {
        guard sameFamily(target, language) else { return nil }
        let source = sameFamily(target, "fr") ? "en" : "fr"
        return (L10n.tr(keys[index], in: source), source)
    }
    private static func sameFamily(_ first: String, _ second: String) -> Bool {
        first == second || (first.hasPrefix("zh") && second.hasPrefix("zh"))
    }
    // Where Translate selected text would send this sample: the ordinary
    // target, or the next preferred language when that is the sample's own.
    static func target(_ preferences: Preferences, ordinaryTarget: String) -> String {
        SelectionLanguagePolicy.personalizedTarget(
            detected: [language], enabled: Language.enabled(preferences.enabledLanguages).map(\.id),
            sourceSpecific: nil, global: nil, currentTarget: ordinaryTarget,
            preferredTarget: preferences.defaultTarget, interfaceLanguage: language)
    }
    // Like Welcome, a key shows only for an assigned global shortcut that registered.
    @MainActor static func key(_ id: UInt32, _ shortcut: Shortcut, model: Model) -> WelcomeEntryPoints.Key? {
        guard shortcut.isAssigned, !model.inactiveGlobalShortcutIDs.contains(id) else { return nil }
        return .init(label: shortcut.displayLabel, spokenLabel: shortcut.spokenLabel)
    }
}

// One Try at a time. A newer Try, Cancel or leaving the step revokes the
// previous one, and only the current Try may publish its result.
@MainActor final class GuidedTourSession: ObservableObject {
    struct Outcome: Equatable {
        let text: String
        let caption: String
        let language: String
    }
    // A Try that starts from text other than the sample shows it above its result.
    struct Source: Equatable {
        let text: String
    }
    @Published private(set) var running: GuidedTourTask?
    @Published private(set) var outcome: Outcome?
    @Published private(set) var source: Source?
    @Published private(set) var issue: String?
    @Published private(set) var issueOffersService = false
    // A stand-in service produced the result (Apple's translation, the backup writer, a Mac voice).
    @Published private(set) var note: String?
    // The sample as a Try rewrote it in place; a new Try starts from the original.
    @Published private(set) var rewritten: String?
    private var work: Task<Void, Never>?
    private var ticket = UUID()
    private var stopSpeech: (() -> Void)?

    func run(
        _ task: GuidedTourTask, caption: String, language: String, source: Source? = nil, inPlace: Bool = false,
        operation: @escaping @MainActor () async throws -> GuidedTourReply
    ) {
        cancel()
        let current = ticket
        running = task
        outcome = nil
        rewritten = nil
        self.source = source
        work = Task { @MainActor [weak self] in
            do {
                let reply = try await operation()
                let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let self, self.ticket == current, !Task.isCancelled else { return }
                self.finish()
                self.note = reply.note
                if inPlace {
                    self.rewritten = text
                } else {
                    self.outcome = Outcome(text: text, caption: caption, language: language)
                }
            } catch {
                guard let self, self.ticket == current, !Task.isCancelled, !(error is CancellationError) else {
                    return
                }
                self.finish()
                // A service that can't answer for now names why and offers another one.
                let fix = TranslationRecoveryAction.fixing(error, writing: task != .translate)
                self.issueOffersService = { if case .anotherService = fix { return true } else { return false } }()
                self.issue = TranslationRecoveryAction.notice(error.localizedDescription, fix: fix)
            }
        }
    }
    // Reading keeps the shown result, since that is what it reads.
    func speak(start: () -> Void, stop: @escaping () -> Void) {
        cancel()
        running = .readAloud
        stopSpeech = stop
        start()
    }
    func speechEnded(issue: String?, note: String? = nil) {
        guard running == .readAloud else { return }
        stopSpeech = nil
        running = nil
        self.issue = issue
        self.note = issue == nil ? note : nil
    }
    // Edit with voice starts from the original sample; its Replace lands here.
    func beginRewrite() {
        cancel()
        outcome = nil
        rewritten = nil
    }
    func rewrite(_ text: String) { rewritten = text }
    // A Try that could not start says why, in the sample card.
    func refuse(_ message: String) {
        cancel()
        issue = message
    }
    func cancel() {
        ticket = UUID()
        work?.cancel()
        let stop = stopSpeech
        finish()
        issue = nil
        note = nil
        stop?()
    }
    // Leaving the step: its results belong to that visit.
    func reset() {
        cancel()
        outcome = nil
        source = nil
        rewritten = nil
    }
    private func finish() {
        work = nil
        stopSpeech = nil
        running = nil
    }
}

// The one step that makes a task runnable, shown in place of its Try.
struct GuidedTourFix {
    let title: String
    let status: String
    let action: () -> Void
}

// Same grammar as General's shortcuts: each everyday task is a row with its key
// and one action. What a task does is its help, not a caption.
// The widest action on the step, so every key column and description lines up in each language.
private struct GuideActionWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
// The widest key cap on the step, so every cap has its width and their left edges line up.
private struct GuideKeycapWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct GuideKeycapWidth: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    fileprivate var guideKeycapWidth: CGFloat {
        get { self[GuideKeycapWidth.self] }
        set { self[GuideKeycapWidth.self] = newValue }
    }
}

struct GuidedTourStep: View {
    @State private var actionWidth: CGFloat = 96
    @State private var keycapWidth: CGFloat = 0
    @ObservedObject var session: GuidedTourSession
    let canTry: Bool
    let speech: GuidedTourSpeech
    let yulloKey: WelcomeEntryPoints.Key?
    let translateKey: WelcomeEntryPoints.Key?
    let refineKey: WelcomeEntryPoints.Key?
    var refineInPlaceKey: WelcomeEntryPoints.Key? = nil
    let writingAvailable: Bool
    var translateFix: GuidedTourFix? = nil
    var writeFix: GuidedTourFix? = nil
    let accessibilityMissing: Bool
    // A denied microphone: dictation's row says so and carries the one fix.
    var microphoneMissing = false
    // One language: what they came for leads; translation follows, still one Try away.
    var oneLanguage = false
    let tryFeature: (GuidedTourTask) -> Void
    let cancel: () -> Void
    let showYullo: () -> Void
    let setUpWriting: () -> Void
    let enableAccessibility: () -> Void
    // Hidden when no mail app is known.
    var mail: MailApplication? = nil
    var emailRule = GuidedEmailRule.available
    var emailIssue: String? = nil
    var addEmailRule: () -> Void = {}
    var turnOnEmailRule: () -> Void = {}
    // Shortcuts: dictation and Edit with voice beside the selection keys.
    var dictationKey: WelcomeEntryPoints.Key? = nil
    var editWithVoiceKey: WelcomeEntryPoints.Key? = nil
    var editWithTextKey: WelcomeEntryPoints.Key? = nil
    var dictationTried = false
    var tryDictation: () -> Void = {}
    var openMicrophoneSettings: () -> Void = {}
    // Made to fit you: What dictation writes in Settings.
    var openFormats: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sampleCard.id("guide-tour-sample")
            // The keys that matter, each with the key as it is set now.
            GroupBox {
                SettingsRows {
                    dictateRow
                    // One language: what they came for leads; translation follows, still one Try away.
                    if oneLanguage {
                        refineInPlaceRow
                        editWithVoiceRow
                        editWithTextRow
                        writerNeed
                        translateRow
                    } else {
                        translateRow
                        refineInPlaceRow
                        editWithVoiceRow
                        editWithTextRow
                        writerNeed
                    }
                }
            }
            if accessibilityMissing {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L10n.tr("Shortcuts for selected text need Accessibility."))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    // Asked here, in place; the tour's results stay.
                    Button(L10n.tr("Allow Accessibility…"), action: enableAccessibility).buttonStyle(.link)
                        .fixedSize()
                }.font(.system(size: 12)).padding(.horizontal, 4).accessibilityIdentifier("guide-tour-accessibility")
            }
            SettingsSection(L10n.tr("Also")) {
                SettingsRows {
                    showRow
                    refineWindowRow
                    readAloudRow
                    if let mail { emailRow(mail) }
                    row(
                        "Made to fit you", caption: "A format for each app, in Dictation settings.", key: nil,
                        showsKey: false
                    ) {
                        Button(L10n.tr("Open…"), action: openFormats)
                    }.accessibilityIdentifier("guide-made-to-fit")
                }
            }
        }
        .onPreferenceChange(GuideActionWidthKey.self) { widest in actionWidth = max(96, widest) }
        .onPreferenceChange(GuideKeycapWidthKey.self) { widest in keycapWidth = widest }
        .environment(\.guideKeycapWidth, keycapWidth)
    }

    private var dictateRow: some View {
        row(
            "Dictate",
            caption: microphoneMissing
                ? "Allow microphone access in System Settings to start dictation." : "Speak into any app.",
            key: dictationKey, keyDimmed: microphoneMissing
        ) {
            if microphoneMissing {
                Button(L10n.tr("Open Microphone Settings"), action: openMicrophoneSettings)
                    .background { microphoneProbe }
            } else if dictationTried {
                Label(L10n.tr("Tried"), systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                    .font(.system(size: 12))
            } else {
                Button(L10n.tr("Try"), action: tryDictation)
                    .accessibilityLabel(L10n.tr("Dictate") + ": " + L10n.tr("Try"))
            }
        }
    }
    @ViewBuilder private var microphoneProbe: some View {
        #if YULLO_TESTING
            YulloActionPresentationProbe(title: "guide-dictate-microphone", action: openMicrophoneSettings)
        #endif
    }
    @ViewBuilder private var refineInPlaceRow: some View {
        row(
            "Refine in place", caption: "Rewrites selected text where it is. ⌘Z undoes it.", key: refineInPlaceKey,
            keyDimmed: !writingAvailable
        ) {
            // The Try column keeps its width; without a writer it waits empty.
            if writingAvailable {
                tryButton(.refineInPlace, title: "Refine in place")
            } else {
                Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
            }
        }
    }
    // The three rows that need a writer share one line under them, with its one fix.
    @ViewBuilder private var writerNeed: some View {
        if !writingAvailable {
            HStack(spacing: 12) {
                Text(L10n.tr("These need a writing service.")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                writerFix.fixedSize()
            }.settingsRowAttached().accessibilityIdentifier("guide-tour-writer-need")
        }
    }
    // Without a writer, Refine in place carries the one fix; this row dims its key.
    private var editWithVoiceRow: some View {
        row(
            "Edit with voice",
            caption: "Select text, press the shortcut, say the change. Replace with ↩.",
            key: editWithVoiceKey, keyDimmed: !writingAvailable
        ) {
            // Try says a change for the sample and opens the review window on it.
            if writingAvailable {
                tryButton(.editWithVoice, title: "Edit with voice")
            } else {
                Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
            }
        }
    }
    // The same edit with the change typed: Try opens the review as its field, under the Sample card.
    private var editWithTextRow: some View {
        row(
            "Edit with text",
            caption: "Select text, press the shortcut, type the change. Replace with ↩.",
            key: editWithTextKey, keyDimmed: !writingAvailable
        ) {
            if writingAvailable {
                tryButton(.editWithText, title: "Edit with text")
            } else {
                Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
            }
        }
    }
    @ViewBuilder private var writerFix: some View {
        if let writeFix {
            fixButton(writeFix).background {
                #if YULLO_TESTING
                    YulloActionPresentationProbe(title: "Guide set up writing", action: writeFix.action)
                #endif
            }
        } else {
            Button(L10n.tr("Set up…"), action: setUpWriting)
                .background {
                    #if YULLO_TESTING
                        YulloActionPresentationProbe(title: "Guide set up writing", action: setUpWriting)
                    #endif
                }
        }
    }

    private var showRow: some View {
        row("Show / hide Yullo", caption: "Type or paste to translate or refine.", key: yulloKey) {
            Button(L10n.tr("Show Yullo"), action: showYullo)
        }
    }
    private var translateRow: some View {
        row(
            "Translate selected text",
            caption: "Selected text in any app, PDFs and web pages.",
            key: translateKey
        ) {
            if let translateFix {
                fixButton(translateFix)
            } else {
                tryButton(.translate, title: "Translate selected text")
            }
        }
    }
    // Refine in Yullo window: only once a writer is set, since Refine in place carries the fix.
    @ViewBuilder private var refineWindowRow: some View {
        if writingAvailable {
            row("Refine in Yullo window", caption: "Shows the rewrite first. You choose what to keep.", key: refineKey)
            {
                tryButton(.refine, title: "Refine in Yullo window")
            }
        }
    }
    private var readAloudRow: some View {
        row(
            "Read aloud", caption: "The speaker button in the Yullo window.", key: nil, showsKey: false
        ) { tryButton(.readAloud, title: "Read aloud") }
    }

    private var sampleCard: some View {
        GuideSampleCard(session: session, speech: speech, cancel: cancel, setUpWriting: setUpWriting)
    }

    // The mail app's row: Add makes Email what dictation writes there.
    private func emailRow(_ mail: MailApplication) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.format("Emails in %@", mail.name)).fixedSize(horizontal: false, vertical: true)
                emailDetail
            }.frame(maxWidth: .infinity, alignment: .leading)
                .help(L10n.tr("Dictate and get a clean email."))
            emailAction(mail).fixedSize()
        }.accessibilityElement(children: .contain).accessibilityIdentifier("guide-tour-email")
    }

    @ViewBuilder private var emailDetail: some View {
        switch emailRule {
        // Refine in place names the missing writer once, with its fix.
        case .needsWritingService, .added, .available:
            EmptyView()
        }
        if let emailIssue {
            Text(emailIssue).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func emailAction(_ mail: MailApplication) -> some View {
        switch emailRule {
        case .available:
            Button(L10n.tr("Add"), action: addEmailRule)
                .accessibilityLabel(L10n.format("Emails in %@", mail.name) + ": " + L10n.tr("Add"))
                .background {
                    #if YULLO_TESTING
                        YulloActionPresentationProbe(title: "Guide email rule", action: addEmailRule)
                    #endif
                }
        case .added(enabled: true):
            HStack(spacing: 4) {
                Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
                Text(L10n.tr("Added")).foregroundStyle(.secondary)
            }.accessibilityElement(children: .combine).accessibilityIdentifier("guide-tour-email-added")
        case .added(enabled: false):
            Button(L10n.tr("Turn on"), action: turnOnEmailRule)
                .accessibilityLabel(L10n.format("Emails in %@", mail.name) + ": " + L10n.tr("Turn on"))
                .background {
                    #if YULLO_TESTING
                        YulloActionPresentationProbe(title: "Guide email turn on", action: turnOnEmailRule)
                    #endif
                }
        case .needsWritingService:
            EmptyView()
        }
    }

    // A task row: its name, its key on a quiet column ("—" when none), one action.
    private func row<Action: View>(
        _ title: String, caption: String, key: WelcomeEntryPoints.Key?, showsKey: Bool = true,
        keyDimmed: Bool = false, @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr(title))
                Text(L10n.tr(caption)).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if showsKey {
                // The key as it is set now, on a cap; a missing key reads as a quiet dash.
                Group {
                    if let key {
                        GuideKeycap(key: key).opacity(keyDimmed ? 0.45 : 1)
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }.frame(width: 64, alignment: .trailing).accessibilityLabel(key?.spokenLabel ?? L10n.tr("None"))
            }
            // One action column, so every key sits on the same edge.
            action().fixedSize()
                .background {
                    GeometryReader { Color.clear.preference(key: GuideActionWidthKey.self, value: $0.size.width) }
                }
                .frame(minWidth: actionWidth, alignment: .trailing)
        }
    }

    private func fixButton(_ fix: GuidedTourFix) -> some View {
        Button(fix.title, action: fix.action).help(fix.status)
    }

    @ViewBuilder private func tryButton(_ task: GuidedTourTask, title: String) -> some View {
        if canTry {
            Button(L10n.tr("Try")) { tryFeature(task) }
                .disabled(session.running != nil)
                .accessibilityLabel(L10n.tr(title) + ": " + L10n.tr("Try"))
                .background {
                    #if YULLO_TESTING
                        YulloActionPresentationProbe(title: "Guide try " + title, action: { tryFeature(task) })
                    #endif
                }
        }
    }
}

// The guide's sample: the text each Try works on, the step's own Try when it has one,
// then what the Try is doing, its result or why it could not run.
struct GuideSampleCard: View {
    struct TryAction {
        let title: String
        let enabled: Bool
        // Why Try can't run yet, while the step's fix is above it.
        var help: String? = nil
        let action: () -> Void
    }
    @ObservedObject var session: GuidedTourSession
    let speech: GuidedTourSpeech
    let cancel: () -> Void
    let setUpWriting: () -> Void
    var tryAction: TryAction? = nil

    // The Sample card reports where it is, so windows and pills a Try opens sit by it.
    @Environment(\.guideSampleFrame) private var reportFrame
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.tr("Sample")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let tryAction {
                    Button(L10n.tr("Try"), action: tryAction.action).disabled(!tryAction.enabled)
                        .help(tryAction.help ?? "")
                        .accessibilityLabel(L10n.tr(tryAction.title) + ": " + L10n.tr("Try"))
                        .accessibilityIdentifier("guide-step-try")
                        .background {
                            #if YULLO_TESTING
                                YulloActionPresentationProbe(
                                    title: "Guide try " + tryAction.title, action: tryAction.action)
                            #endif
                        }
                }
            }
            // A Try that rewrites in place changes the sample itself, with a soft cross-fade.
            Text(session.rewritten ?? GuidedTourSample.text).font(.system(size: 14)).lineSpacing(2).textSelection(
                .enabled
            )
            .fixedSize(horizontal: false, vertical: true)
            .id(session.rewritten ?? GuidedTourSample.text).transition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: session.rewritten)
            .accessibilityIdentifier("guide-tour-sample-text")
            if session.outcome != nil || session.running != nil || session.issue != nil || session.note != nil {
                Divider().padding(.vertical, 3)
                if let outcome = session.outcome {
                    Text(outcome.caption).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    // A translation from another language shows that line first; the sample stays as it was.
                    if let source = session.source {
                        Text(source.text).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(2)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("guide-tour-source")
                    }
                    Text(outcome.text).font(.system(size: 14)).lineSpacing(2).textSelection(.enabled)
                        .foregroundStyle(
                            session.running == nil || session.running == .readAloud ? .primary : .secondary
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("guide-tour-result")
                }
                // Which service stood in, in the same words as the Yullo window.
                if let note = session.note, session.running == nil {
                    Label(note, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("guide-tour-note")
                }
                if let running = session.running {
                    HStack(spacing: 8) {
                        status(running).frame(maxWidth: .infinity, alignment: .leading)
                        Button(L10n.tr("Cancel"), action: cancel)
                            .background {
                                #if YULLO_TESTING
                                    YulloActionPresentationProbe(title: "Guide cancel try", action: cancel)
                                #endif
                            }
                    }
                }
                if let issue = session.issue {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(issue).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if session.issueOffersService {
                            Spacer(minLength: 8)
                            Button(L10n.tr("Choose Another Service…"), action: setUpWriting).font(.system(size: 11))
                                .fixedSize()
                                .background {
                                    #if YULLO_TESTING
                                        YulloActionPresentationProbe(
                                            title: "Guide another service", action: setUpWriting)
                                    #endif
                                }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
        .settingsCard()
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { reportFrame?($0) }
        .onDisappear { reportFrame?(.null) }
    }

    @ViewBuilder private func status(_ task: GuidedTourTask) -> some View {
        switch task {
        case .translate: ActivityStatus(title: L10n.tr("Translating…"))
        case .refine, .refineInPlace: ActivityStatus(title: L10n.tr("Refining…"))
        // The same word as the review window it opens.
        case .editWithVoice, .editWithText: ActivityStatus(title: L10n.tr("Editing…"))
        case .readAloud:
            if speech == .playing {
                ActivityStatus(title: L10n.tr("Playing sample"), glyph: .playing, elapsedAfter: nil)
            } else {
                ActivityStatus(title: L10n.tr("Preparing sample…"))
            }
        }
    }

}

// A key as it reads on the keyboard: the live shortcut's own label on a quiet cap.
struct GuideKeycap: View {
    let key: WelcomeEntryPoints.Key
    @Environment(\.guideKeycapWidth) private var shared
    var body: some View {
        Text(key.label).font(.system(size: 13, weight: .medium)).monospacedDigit()
            .padding(.horizontal, 8)
            .background {
                GeometryReader { Color.clear.preference(key: GuideKeycapWidthKey.self, value: $0.size.width) }
            }
            .frame(minWidth: max(30, shared), minHeight: 24)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .fixedSize().accessibilityLabel(key.spokenLabel)
    }
}

// While the guide's trial is on screen and its window is in front, the dictation
// key starts that trial instead of dictating into the app behind.
@MainActor enum GuidedTrialShortcut {
    static var start: (() -> Void)?
}
