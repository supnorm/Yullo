import SwiftUI
import AppKit
import Combine

enum VoiceOverlayPlacement: String, Codable, CaseIterable { case bottom, notch, caret }
enum VoiceLivePreviewSize: String, CaseIterable {
    case compact, expanded, scrolling
    var titleKey: String {
        switch self {
        case .compact: return "2 lines"
        case .expanded: return "4 lines"
        case .scrolling: return "Scrollable preview"
        }
    }
    var lineCount: Int? { self == .scrolling ? nil : self == .expanded ? 4 : 2 }
    var textHeight: CGFloat { self == .scrolling ? 144 : self == .expanded ? 72 : 36 }
}
enum VoiceOverlayPhase: Equatable {
    case preparing, recording, paused, transcribing, translating, refining, preview, error
}
enum VoiceOverlayResultContext: Equatable {
    case preview, insertionUnconfirmed, earlierOutputInserted, earlierOutputNotInserted, earlierOutputUnconfirmed
    var isEarlierOutput: Bool {
        self == .earlierOutputInserted || self == .earlierOutputNotInserted || self == .earlierOutputUnconfirmed
    }
    var message: String? {
        switch self {
        case .preview: return nil
        case .insertionUnconfirmed:
            return L10n.tr("Your text may already be in the original app. Check before pasting to avoid duplicates.")
        case .earlierOutputInserted:
            return L10n.tr("Earlier output was inserted. Check the original app before pasting.")
        case .earlierOutputNotInserted: return L10n.tr("Nothing was inserted automatically.")
        case .earlierOutputUnconfirmed:
            return L10n.tr("Earlier output may already be in the original app. Check before pasting.")
        }
    }
}

enum VoiceOutputChoice: Equatable {
    case original, translation(String), refinement(RewriteStyle)
    var title: String { title(localizedLanguageNames: false) }
    func title(localizedLanguageNames: Bool, locale: Locale = L10n.locale) -> String {
        switch self {
        case .original: return L10n.tr("Original")
        case .translation(let language):
            return Language.displayName(for: language, localized: localizedLanguageNames, locale: locale)
        case .refinement(let style): return Self.styleTitle(style)
        }
    }
    static func styleTitle(_ style: RewriteStyle) -> String {
        WritingStylePresentation.title(style)
    }
    func isAvailable(languages: [String], refinement: Bool) -> Bool {
        switch self {
        case .original: return true
        case .translation(let language): return languages.contains(language)
        case .refinement: return refinement
        }
    }
}

// The recording window's format menu for one ordinary dictation: What I say,
// Cleaned up, the format this recording resolved to, two recent picks, and
// More with the rest. A pick applies to this dictation only.
struct VoiceFormatMenu: Equatable {
    var top: [String]
    // What I say and Cleaned up lead; a separator follows them.
    var pinned = 2
    var more: [[String]]
    var selected: String
    var titles: [String: String]
    // Formats that need the writing service; they stay visible but unavailable without one.
    var writes: Set<String>

    func title(_ format: String) -> String { titles[format] ?? format }
}

// The recording window's language switch: each click moves to the next of the
// chosen languages, then Same as I speak, then around again.
enum VoiceLanguageSwitch {
    static func next(after current: String?, in languages: [String]) -> String? {
        let cycle = languages.map { Optional($0) } + [nil]
        guard let index = cycle.firstIndex(of: current) else { return cycle[0] }
        return cycle[(index + 1) % cycle.count]
    }
    // Never a phrase that reads like a format: a target shows its language;
    // "same as spoken" is a small waveform, with the spoken language's code
    // when the recognizer's language is set.
    // One language, one label, with or without the waveform: its code, and
    // its script only when two of the person's languages share that code.
    static func label(_ language: String?, among languages: [String] = []) -> String {
        guard let language else { return "" }
        let base = { (id: String) in String(id.split(separator: "-").first ?? Substring(id)) }
        let siblings = Set(languages.filter { base($0) == base(language) } + [language])
        return (siblings.count > 1 && language.contains("-") ? language : base(language)).uppercased()
    }
    static func spokenCode(_ language: String?, among languages: [String] = []) -> String {
        label(language, among: languages)
    }
    // Every label the switch can show, so its slot fits the widest one. The
    // spoken state is a small waveform (about an em) before the spoken language.
    static func labels(_ languages: [String], spoken: String? = nil) -> [String] {
        languages.isEmpty
            ? []
            : languages.map { label($0, among: languages) } + [
                "\u{2003}\u{2002}" + spokenCode(spoken, among: languages)
            ]
    }
}

// AX uses a top-left desktop origin; native text views use AppKit's bottom-left
// origin. Keep the conversion in one place, including displays above/left.
enum VoiceCaretCoordinates {
    static func isValid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width >= 0 && rect.height > 0 && !rect.isNull
    }
    static func accessibilityRect(fromAppKit rect: CGRect, primaryScreenTop: CGFloat) -> CGRect? {
        guard isValid(rect), primaryScreenTop.isFinite else { return nil }
        return CGRect(x: rect.minX, y: primaryScreenTop - rect.maxY, width: max(1, rect.width), height: rect.height)
    }
    static func appKitRect(fromAccessibility rect: CGRect, primaryScreenTop: CGFloat) -> CGRect? {
        accessibilityRect(fromAppKit: rect, primaryScreenTop: primaryScreenTop)
    }
}

struct VoiceOverlayScreen: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect
    var safeTop: CGFloat = 0
    var auxiliaryLeft: CGRect = .zero
    var auxiliaryRight: CGRect = .zero
}
struct VoiceOverlayLayout: Equatable {
    enum Surface: Equatable { case glass, notch }
    let frame: CGRect
    let surface: Surface
    var cameraWidth: CGFloat = 0
    var cameraBandHeight: CGFloat = 0
    var transcriptAboveControls = false
    var liveTextHeight: CGFloat = 36
}

// Geometry is pure so negative-origin displays, Dock margins and a physically
// reserved camera area can be tested without displaying an app window.
enum VoiceOverlayGeometry {
    static func layout(
        placement: VoiceOverlayPlacement, phase: VoiceOverlayPhase,
        anchor: CGRect?, screen: VoiceOverlayScreen, hasPreviewText: Bool = true,
        compactWidth: CGFloat = 180, hasLiveTranscript: Bool = false, recordingNoticeHeight: CGFloat = 0,
        showsPause: Bool = false, confirmationWidth: CGFloat = 180, hasRecognitionRecovery: Bool = false,
        liveTextHeight: CGFloat = 36, previewSlack: CGFloat = 0
    ) -> VoiceOverlayLayout {
        let margin: CGFloat = 12
        let visible = screen.visibleFrame
        let confirmation = phase == .preview && !hasPreviewText
        let live = hasLiveTranscript && VoiceLiveTranscriptPresentation.displays(in: phase)
        let noticeHeight =
            (phase == .recording || phase == .paused) && recordingNoticeHeight.isFinite
            ? min(48, max(0, recordingNoticeHeight)) : 0
        let hasNotice = noticeHeight > 0
        let requestedLiveHeight = liveTextHeight.isFinite ? min(144, max(36, liveTextHeight)) : 36
        let boundedLiveHeight = min(
            requestedLiveHeight, max(0, visible.height - 2 * margin - 60 - (hasNotice ? noticeHeight + 8 : 0)))
        let expanded = (phase == .preview && !confirmation) || phase == .error || live || hasNotice
        let requestedWidth = compactWidth.isFinite ? max(140, compactWidth) : 180
        let noticeWidth = confirmationWidth.isFinite ? max(180, confirmationWidth) : 180
        let width = min(
            confirmation ? noticeWidth : expanded ? 360 : requestedWidth, max(80, visible.width - 2 * margin))
        let baseHeight: CGFloat =
            live
            ? 60 + boundedLiveHeight
            : phase == .preview && !confirmation
                ? 180 - (previewSlack.isFinite ? min(74, max(0, previewSlack)) : 0)
                : phase == .error ? (hasRecognitionRecovery ? 340 : 112) : 46
        let height = baseHeight + (hasNotice ? noticeHeight + 8 : 0)
        func clamped(_ origin: CGPoint) -> CGRect {
            CGRect(
                x: max(visible.minX + margin, min(origin.x, visible.maxX - width - margin)),
                y: max(visible.minY + margin, min(origin.y, visible.maxY - height - margin)), width: width,
                height: height)
        }
        if placement == .notch {
            let cameraLeft = screen.auxiliaryLeft.maxX, cameraRight = screen.auxiliaryRight.minX
            let cameraWidth = cameraRight - cameraLeft
            let controlsWidth: CGFloat = showsPause ? 112 : 96
            if screen.safeTop > 0, screen.auxiliaryLeft.width > 0, screen.auxiliaryRight.width > 0,
                cameraWidth > 0, cameraWidth + controlsWidth < screen.frame.width
            {
                let panelWidth =
                    live || hasNotice
                    ? min(max(360, cameraWidth + controlsWidth), screen.frame.width - 2 * margin)
                    : max(confirmation ? noticeWidth : expanded ? 360 : 0, cameraWidth + controlsWidth)
                let contentHeight: CGFloat =
                    hasNotice
                    ? (live ? 38 + boundedLiveHeight : 30) + noticeHeight + 8
                    : (live ? 38 + boundedLiveHeight : expanded ? height : 30)
                let panelHeight = screen.safeTop + contentHeight
                return VoiceOverlayLayout(
                    frame: CGRect(
                        x: (cameraLeft + cameraRight - panelWidth) / 2,
                        y: screen.frame.maxY - panelHeight, width: panelWidth, height: panelHeight),
                    surface: .notch, cameraWidth: cameraWidth, cameraBandHeight: screen.safeTop,
                    liveTextHeight: boundedLiveHeight)
            }
            return VoiceOverlayLayout(
                frame: clamped(CGPoint(x: visible.midX - width / 2, y: visible.maxY - height - margin)),
                surface: .glass,
                liveTextHeight: boundedLiveHeight
            )
        }
        if placement == .caret, let anchor, anchor.origin.x.isFinite, anchor.origin.y.isFinite,
            anchor.width.isFinite, anchor.height.isFinite, anchor.height > 0, screen.frame.intersects(anchor)
        {
            let below = anchor.minY - height - 9
            let fitsBelow = below >= visible.minY + margin
            let y = fitsBelow ? below : anchor.maxY + 9
            return VoiceOverlayLayout(
                frame: clamped(CGPoint(x: anchor.minX, y: y)), surface: .glass,
                transcriptAboveControls: !fitsBelow, liveTextHeight: boundedLiveHeight)
        }
        return VoiceOverlayLayout(
            frame: clamped(CGPoint(x: visible.midX - width / 2, y: visible.minY + 20)), surface: .glass,
            transcriptAboveControls: true, liveTextHeight: boundedLiveHeight)
    }
}

enum VoiceLiveTranscriptPresentation {
    static let updateInterval: TimeInterval = 0.18
    static let maximumCharacters = 480
    static func tail(_ text: String, size: VoiceLivePreviewSize = .compact) -> String {
        let text = VoiceLiveTextBuffer.suffix(text)
        if size == .scrolling { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(text.suffix(size == .expanded ? maximumCharacters * 2 : maximumCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func displays(in phase: VoiceOverlayPhase) -> Bool {
        [.recording, .paused, .transcribing, .translating, .refining].contains(phase)
    }
    @MainActor static func visibleTail(_ text: String, width: CGFloat, size: VoiceLivePreviewSize = .compact) -> String
    {
        let text = tail(text, size: size)
        guard let lineCount = size.lineCount else { return text }
        guard !text.isEmpty else { return "" }
        let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        var lines: [NSRange] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, glyphs, _ in
            lines.append(glyphs)
        }
        guard lines.count > lineCount, let first = lines.suffix(lineCount).first else { return text }
        let start = layout.characterRange(forGlyphRange: first, actualGlyphRange: nil).location
        return (text as NSString).substring(from: start)
    }
}

// Match the compact surface to the content it actually shows. In particular,
// plain dictation reserves no space for an optional output-mode control.
enum VoiceOverlayContentMetrics {
    // A short result shouldn't sit in a tall empty card: its reader grows
    // with the text, up to the usual maximum, and the panel shrinks to match.
    static func resultMaximum(_ context: VoiceOverlayResultContext) -> CGFloat { context == .preview ? 74 : 58 }
    static func resultTextHeight(_ text: String, width: CGFloat, maximum: CGFloat) -> CGFloat {
        guard !text.isEmpty, width.isFinite, width > 0 else { return maximum }
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13)])
        return min(maximum, max(18, ceil(bounds.height) + 2))
    }
    static func status(_ phase: VoiceOverlayPhase, resultContext: VoiceOverlayResultContext = .preview) -> String {
        switch phase {
        case .preparing: return L10n.tr("Preparing…")
        case .recording: return L10n.tr("Listening")
        case .paused: return L10n.tr("Paused")
        case .transcribing: return L10n.tr("Transcribing")
        case .translating: return L10n.tr("Translating")
        case .refining: return L10n.tr("Refining")
        case .preview:
            if resultContext.isEarlierOutput { return L10n.tr("Recent result") }
            return L10n.tr(resultContext == .insertionUnconfirmed ? "Insertion not confirmed" : "Ready to copy")
        case .error: return L10n.tr("Dictation needs attention")
        }
    }
    static func menuWidth(_ title: String) -> CGFloat {
        min(105, max(48, textWidth(title, size: 11, weight: .medium) + 20))
    }
    // One slot for the language switch, sized to its widest label, so the HUD
    // and its actions stay put while the switch cycles.
    static func languageWidth(_ labels: [String]) -> CGFloat {
        min(96, (labels.map { textWidth($0, size: 11, weight: .medium) }.max() ?? 0) + 12)
    }
    // The active preset names the output; its fields stay in the output menu.
    static func caption(status: String, modeLabel: String, presetLabel: String) -> String {
        let detail = presetLabel.isEmpty ? modeLabel : presetLabel
        return detail.isEmpty ? status : "\(status) · \(detail)"
    }
    static func width(
        phase: VoiceOverlayPhase, modeLabel: String, showsOutputChoice: Bool, choiceTitle: String,
        showsPause: Bool = false, presetLabel: String = "", languageLabels: [String] = []
    )
        -> CGFloat
    {
        let status = status(phase)
        let pauseWidth: CGFloat = showsPause && (phase == .recording || phase == .paused) ? 28 : 0
        if showsOutputChoice {
            let label = caption(status: status, modeLabel: "", presetLabel: presetLabel)
            // Padding + waveform + status + native popup + stop + three gaps, and the language switch.
            let language = languageLabels.isEmpty ? 0 : languageWidth(languageLabels) + 8
            return ceil(
                28 + 28 + textWidth(label, size: 12) + menuWidth(choiceTitle) + language + 24 + 3 * 8 + pauseWidth)
        }
        let caption = caption(status: status, modeLabel: modeLabel, presetLabel: presetLabel)
        // Padding + waveform + caption + Stop + two gaps; Pause shares the action group.
        return ceil(28 + 28 + textWidth(caption, size: 12) + 24 + 2 * 9 + pauseWidth)
    }
    static func recordingNoticeHeight(_ message: String?, width: CGFloat) -> CGFloat {
        guard let message, !message.isEmpty else { return 0 }
        let bounds = (message as NSString).boundingRect(
            with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 12)])
        return min(48, max(17, ceil(bounds.height) + 3))
    }
    static let confirmationIconWidth: CGFloat = 16
    static func confirmationWidth(_ message: String, briefNotice: Bool = false) -> CGFloat {
        // Glass padding, the icon/text gap and the explicitly sized checkmark.
        min(340, max(briefNotice ? 250 : 180, textWidth(message, size: 12) + 28 + 8 + confirmationIconWidth))
    }
    private static func textWidth(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        ceil((value as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width)
    }
}

@MainActor private final class VoiceOverlayModel: ObservableObject {
    @Published var phase: VoiceOverlayPhase = .recording
    @Published var modeLabel = ""
    @Published var presetLabel = ""
    @Published var localizedLanguageNames = false
    @Published var languageNameLocale = ""
    var outputChoiceTitle: String {
        formats.flatMap { $0.selected.isEmpty ? nil : $0.title($0.selected) }
            ?? shownOutputChoice.title(localizedLanguageNames: localizedLanguageNames)
    }
    // Ordinary dictation's formats; nil for voice translation and other fixed outputs.
    @Published var formats: VoiceFormatMenu?
    var onFormatChange: ((String) -> Void)?
    // The format menu names the output, so the status beside it doesn't repeat it.
    var recordingPresetLabel: String { formats == nil ? presetLabel : "" }
    // With the language switch, the menu names only the format; the switch names the language.
    var shownOutputChoice: VoiceOutputChoice {
        if !languageSwitch.isEmpty, case .translation = outputChoice { return .original }
        return outputChoice
    }
    @Published var languageSwitch: [String] = []
    @Published var outputLanguage: String?
    // The recognizer's language when it is set, so "same as spoken" can show it.
    @Published var spokenLanguage: String?
    var onOutputLanguageChange: ((String?) -> Void)?
    @Published var result = ""
    @Published var recognitionRecovery: VoiceRecognitionRecoverySnapshot?
    @Published var resultContext = VoiceOverlayResultContext.preview
    @Published var livePreviewSize = VoiceLivePreviewSize.compact
    @Published var liveTranscript = ""
    @Published var liveVisibleText = ""
    @Published var liveTranscriptStatus: String?
    @Published var liveRegionActive = false
    @Published var message: String?
    var statusTitle: String {
        phase == .preview && result.isEmpty
            ? message ?? L10n.tr("Inserted")
            // A reviewed result that ↩ can still put in place names that, not copying.
            : phase == .preview && resultContext == .preview && previewInsertLabel != nil
                ? L10n.tr("Ready to insert")
                : VoiceOverlayContentMetrics.status(phase, resultContext: resultContext)
    }
    @Published var recordingNoticeHeight: CGFloat = 0
    var recordingNotice: String? {
        (phase == .recording || phase == .paused) && message?.isEmpty == false ? message : nil
    }
    @Published var levels = [Double](repeating: 0, count: 7)
    @Published var layout = VoiceOverlayLayout(frame: .zero, surface: .glass)
    @Published var outputLanguages: [String] = []
    @Published var outputChoice: VoiceOutputChoice = .original
    @Published var allowsRefinement = false
    @Published var refinementAvailable = false
    @Published var changingOutput = false
    @Published var copyShortcutLabel: String?
    // Set while a reviewed result can still go where it was dictated: its key.
    @Published var previewInsertLabel: String?
    @Published var copyFeedback: String?
    @Published var comparisonAvailable = false
    @Published var pauseAvailable = false
    @Published var showsPause = false
    // Names what the setup button does when it fixes something outside Settings.
    @Published var settingsTitleKey = "Settings"
    var onFinish: (() -> Void)?
    var onPauseResume: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCopy: (() -> Void)?
    var onInsert: (() -> Void)?
    var onCopyDraft: (() -> Void)?
    var onSettings: (() -> Void)?
    var onCompare: (() -> Void)?
    var onOutputChoiceChange: ((VoiceOutputChoice) -> Void)?
    var onOutputMenuTracking: ((Bool) -> Void)?
    #if YULLO_TESTING
        var onActionEnabled: ((String, Bool) -> Void)?
        var onTranslucentFillChange: ((Bool) -> Void)?
        var testReduceTransparency: Bool?
        var testIncreasedContrast: Bool?
    #endif
}

final class VoiceOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@available(macOS 26.0, *)
@MainActor final class VoiceRecordingOverlay {
    var onFinish: (() -> Void)? { didSet { model.onFinish = onFinish } }
    var onPauseResume: (() -> Void)? { didSet { model.onPauseResume = onPauseResume } }
    var onCancel: (() -> Void)? { didSet { model.onCancel = onCancel } }
    var onCopy: (() -> Void)? { didSet { model.onCopy = onCopy } }
    var onInsert: (() -> Void)? { didSet { model.onInsert = onInsert } }
    var onCopyDraft: (() -> Void)? { didSet { model.onCopyDraft = onCopyDraft } }
    var onSettings: (() -> Void)? { didSet { model.onSettings = onSettings } }
    var settingsTitleKey = "Settings" { didSet { model.settingsTitleKey = settingsTitleKey } }
    var onCompare: (() -> Void)? { didSet { model.onCompare = onCompare } }
    var onOutputChoiceChange: ((VoiceOutputChoice) -> Void)? {
        didSet { model.onOutputChoiceChange = onOutputChoiceChange }
    }
    var onOutputMenuTracking: ((Bool) -> Void)? { didSet { model.onOutputMenuTracking = onOutputMenuTracking } }
    var onFormatChange: ((String) -> Void)? { didSet { model.onFormatChange = onFormatChange } }
    var onOutputLanguageChange: ((String?) -> Void)? {
        didSet { model.onOutputLanguageChange = onOutputLanguageChange }
    }
    private let model = VoiceOverlayModel()
    private var panel: VoiceOverlayPanel?
    private var placement: VoiceOverlayPlacement = .bottom
    private var caretBounds: CGRect?
    private var preferredDisplay: NSNumber?
    private var appearanceValue = "system"
    private var lastLevelUpdate: TimeInterval = 0
    private var layoutLanguage = ""
    private var displayObserver: NSObjectProtocol?
    private var pendingLiveText: String?
    private var liveUpdateTask: Task<Void, Never>?
    private var liveUpdateGeneration: UInt64 = 0
    private var lastLiveUpdate: TimeInterval = 0
    private var laidOutLiveText = ""
    private var liveTextWidth: CGFloat = 0
    private var completionNoticeTask: Task<Void, Never>?
    private var completionNoticeGeneration: UInt64 = 0
    private var completionNoticeActive = false
    private var animatesNextResize = false
    #if YULLO_TESTING
        private(set) var testLivePublishCount = 0
        var testLiveTranscript: String { model.liveTranscript }
        var testLivePreviewSize: VoiceLivePreviewSize { model.livePreviewSize }
        var testLiveRegionActive: Bool { model.liveRegionActive }
        var testLiveTranscriptStatus: String? { model.liveTranscriptStatus }
        var testRecordingNotice: String? { model.recordingNotice }
        var testUnshownPanel: NSPanel? { panel }
        func testPrepareUnshown(
            placement: VoiceOverlayPlacement = .bottom, caretBounds: CGRect? = nil, preferredScreen: NSScreen? = nil
        ) {
            preparePresentation(placement: placement, caretBounds: caretBounds, preferredScreen: preferredScreen)
        }
        var testResultContext: VoiceOverlayResultContext { model.resultContext }
        var testResultText: String { model.result }
        var testChangingOutput: Bool { model.changingOutput }
        var testPauseAvailable: Bool { model.pauseAvailable }
        var testShowsPause: Bool { model.showsPause }
        var testCompletionNoticeActive: Bool { completionNoticeActive }
        func testShowCompletionNotice(_ message: String, duration: Duration = .seconds(3)) {
            presentCompletionNotice(message, showPanel: false, duration: duration)
        }
        var testStatusTitle: String { model.statusTitle }
        func testResetLiveTranscript() {
            clearLiveTranscript()
            model.phase = .recording
        }
    #endif

    init() {
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.relayout() } }
    }
    deinit { if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) } }

    func setAppearance(_ value: String) {
        appearanceValue = value
        if let panel { AppTheme.apply(value, to: panel) }
    }
    // Preserve the accepted result/phase and visibility, including while a
    // different output is pending or a Settings surface has hidden the HUD.
    func configureLanguageNames(localized: Bool, modeLabel: String) {
        let changed =
            model.localizedLanguageNames != localized || model.languageNameLocale != L10n.language
            || model.modeLabel != modeLabel
        if model.localizedLanguageNames != localized { model.localizedLanguageNames = localized }
        if model.languageNameLocale != L10n.language { model.languageNameLocale = L10n.language }
        if model.modeLabel != modeLabel { model.modeLabel = modeLabel }
        if changed { relayout() }
    }
    func configureFormats(_ menu: VoiceFormatMenu?) {
        guard model.formats != menu else { return }
        let resizes = model.formats?.title(model.formats?.selected ?? "") != menu?.title(menu?.selected ?? "")
        model.formats = menu
        if resizes { relayout() }
    }
    func configurePreset(_ title: String) {
        guard model.presetLabel != title else { return }
        model.presetLabel = title
        relayout()
    }
    func configureOutputChoice(
        languages: [String], refinement: Bool, refinementAvailable: Bool, selected: VoiceOutputChoice, changing: Bool
    ) {
        let changesSize = model.outputLanguages.isEmpty != languages.isEmpty || model.outputChoice != selected
        if model.outputLanguages != languages { model.outputLanguages = languages }
        if model.allowsRefinement != refinement { model.allowsRefinement = refinement }
        if model.refinementAvailable != refinementAvailable { model.refinementAvailable = refinementAvailable }
        if model.outputChoice != selected { model.outputChoice = selected }
        if model.changingOutput != changing { model.changingOutput = changing }
        if changesSize { relayout() }
    }
    func configureSpokenLanguage(_ language: String?) {
        guard model.spokenLanguage != language else { return }
        model.spokenLanguage = language
        relayout()
    }
    func configureOutputLanguage(_ languages: [String], selected: String?) {
        guard model.languageSwitch != languages || model.outputLanguage != selected else { return }
        model.languageSwitch = languages
        model.outputLanguage = selected
        relayout()
    }
    func configureResultContext(_ context: VoiceOverlayResultContext) {
        if model.resultContext != context { model.resultContext = context }
    }
    func configureRecognitionRecovery(_ snapshot: VoiceRecognitionRecoverySnapshot?) {
        guard model.recognitionRecovery != snapshot else { return }
        model.recognitionRecovery = snapshot
        relayout()
    }
    func configureCopyShortcut(_ label: String?) { model.copyShortcutLabel = label }
    func configurePreviewInsert(_ label: String?) {
        if model.previewInsertLabel != label { model.previewInsertLabel = label }
    }
    func showCopyFeedback(_ message: String?) { model.copyFeedback = message }
    func configureComparison(_ available: Bool) {
        if model.comparisonAvailable != available { model.comparisonAvailable = available }
    }
    func configurePause(_ supported: Bool) {
        let changesSize = supported && !model.showsPause
        if supported && !model.showsPause { model.showsPause = true }
        if model.pauseAvailable != supported { model.pauseAvailable = supported }
        if changesSize { relayout() }
    }

    func show(placement: VoiceOverlayPlacement = .bottom, caretBounds: CGRect? = nil, preferredScreen: NSScreen? = nil)
    {
        preparePresentation(placement: placement, caretBounds: caretBounds, preferredScreen: preferredScreen)
        panel?.orderFrontRegardless()  // Never activates Yullo or steals the editor's focus.
    }
    private func preparePresentation(
        placement: VoiceOverlayPlacement, caretBounds: CGRect?, preferredScreen: NSScreen?
    ) {
        if completionNoticeActive {
            model.phase = .recording
            model.message = nil
        }
        cancelCompletionNotice()
        clearLiveTranscript()
        self.placement = placement
        self.caretBounds = caretBounds
        preferredDisplay = preferredScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        if panel == nil { panel = makePanel() }
        panel?.ignoresMouseEvents = false
        relayout()
    }
    private func makePanel() -> VoiceOverlayPanel {
        let window = VoiceOverlayPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        AppTheme.apply(appearanceValue, to: window)
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isExcludedFromWindowsMenu = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = ThemeHostingView(
            rootView: VoiceRecordingOverlayView(model: model), theme: appearanceValue,
            inheritedAppearance: window.effectiveAppearance)
        window.contentView?.focusRingType = .none
        return window
    }
    // Builds the hidden indicator and draws it once offscreen, so the first
    // recording orders an already prepared window front. It is never shown here.
    func prewarm() {
        guard panel == nil else { return }
        let window = makePanel()
        panel = window
        relayout()
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
    }

    func showCompletionNotice(_ message: String) {
        presentCompletionNotice(message, showPanel: true, duration: .seconds(3))
    }

    func dismissCompletionNotice() {
        guard completionNoticeActive else { return }
        hide()
    }

    private func presentCompletionNotice(_ message: String, showPanel: Bool, duration: Duration) {
        let screen = NSScreen.screens.first {
            preferredDisplay != nil
                && $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == preferredDisplay
        }
        preparePresentation(placement: placement, caretBounds: caretBounds, preferredScreen: screen)
        configureOutputChoice(
            languages: [], refinement: false, refinementAvailable: false, selected: .original, changing: false)
        model.comparisonAvailable = false
        model.pauseAvailable = false
        model.showsPause = false
        model.resultContext = .preview
        update(phase: .preview, modeLabel: "", message: message)
        completionNoticeActive = true
        relayout()
        panel?.ignoresMouseEvents = true
        if showPanel { panel?.orderFrontRegardless() }
        let generation = completionNoticeGeneration
        completionNoticeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self, self.completionNoticeActive, generation == self.completionNoticeGeneration else { return }
            self.hide()
        }
    }

    private func cancelCompletionNotice() {
        completionNoticeGeneration &+= 1
        completionNoticeTask?.cancel()
        completionNoticeTask = nil
        completionNoticeActive = false
    }

    func update(
        phase: VoiceOverlayPhase, modeLabel: String, level: Double = 0, result: String = "", message: String? = nil
    ) {
        if model.phase != phase || model.result != result {
            model.copyFeedback = nil
        }
        if completionNoticeActive {
            cancelCompletionNotice()
            panel?.ignoresMouseEvents = false
        }
        let recordingMessage =
            phase == .recording || phase == .paused
            ? message?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let changedNotice = model.recordingNotice != (recordingMessage?.isEmpty == false ? recordingMessage : nil)
        let changedPhase = model.phase != phase
        let changedSize =
            changedPhase || changedNotice || model.modeLabel != modeLabel || layoutLanguage != L10n.language
            || (phase == .preview && model.result.isEmpty != result.isEmpty)
            || (phase == .preview && result.isEmpty && model.message != message)
        // Preparing gives way to Listening with an eased width change around the same anchor.
        if changedPhase, model.phase == .preparing, phase == .recording, panel?.isVisible == true,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        {
            animatesNextResize = true
        }
        if changedPhase { model.phase = phase }
        if VoiceLiveTranscriptPresentation.displays(in: phase) {
            if model.liveTranscriptStatus != nil { model.liveRegionActive = true }
        } else if phase != .preparing {
            clearLiveTranscript()
        }
        if model.modeLabel != modeLabel { model.modeLabel = modeLabel }
        if model.result != result { model.result = result }
        let displayedMessage = phase == .recording || phase == .paused ? recordingMessage : message
        if model.message != displayedMessage { model.message = displayedMessage }
        let now = ProcessInfo.processInfo.systemUptime
        let interval = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.2 : 1.0 / 30
        if phase == .recording, now - lastLevelUpdate >= interval {
            lastLevelUpdate = now
            let value = level.isFinite ? min(1, max(0, level)) : 0
            model.levels = Array(model.levels.dropFirst()) + [value]
        } else if changedPhase {
            model.levels = Array(repeating: 0, count: 7)
        }
        if changedSize { relayout() }
    }

    // The coordinator calls this once for each recording's frozen preferences.
    func configureLivePreview(size: VoiceLivePreviewSize) {
        guard model.livePreviewSize != size else { return }
        clearLiveTranscript()
        model.livePreviewSize = size
        relayout()
    }

    func updateLiveTranscript(_ text: String) {
        guard VoiceLiveTranscriptPresentation.displays(in: model.phase), model.liveTranscriptStatus == nil else {
            return
        }
        let text = VoiceLiveTranscriptPresentation.tail(text, size: model.livePreviewSize)
        guard pendingLiveText != text, model.liveTranscript != text || pendingLiveText != nil else { return }
        pendingLiveText = text
        let delay =
            VoiceLiveTranscriptPresentation.updateInterval - (ProcessInfo.processInfo.systemUptime - lastLiveUpdate)
        if delay <= 0 {
            liveUpdateTask?.cancel()
            liveUpdateTask = nil
            liveUpdateGeneration &+= 1
            publishLiveTranscript()
            return
        }
        guard liveUpdateTask == nil else { return }
        let generation = liveUpdateGeneration
        liveUpdateTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, generation == self.liveUpdateGeneration else { return }
            self.liveUpdateTask = nil
            self.publishLiveTranscript()
        }
    }
    func updateLiveTranscriptStatus(_ message: String?) {
        guard model.phase == .preparing || VoiceLiveTranscriptPresentation.displays(in: model.phase) else { return }
        clearLiveTranscript()
        let message = message.map { String($0.prefix(240)).trimmingCharacters(in: .whitespacesAndNewlines) }
        model.liveTranscriptStatus = message?.isEmpty == false ? message : nil
        model.liveRegionActive =
            model.liveTranscriptStatus != nil && VoiceLiveTranscriptPresentation.displays(in: model.phase)
        relayout()
    }
    private func publishLiveTranscript() {
        guard let text = pendingLiveText, VoiceLiveTranscriptPresentation.displays(in: model.phase) else { return }
        pendingLiveText = nil
        lastLiveUpdate = ProcessInfo.processInfo.systemUptime
        guard model.liveTranscript != text else { return }
        let changesSize = !model.liveRegionActive && !text.isEmpty
        if !text.isEmpty { model.liveRegionActive = true }
        model.liveTranscript = text
        #if YULLO_TESTING
            testLivePublishCount += 1
        #endif
        if changesSize { relayout() }
        updateVisibleLiveTail()
    }
    private func updateVisibleLiveTail() {
        let width = max(1, model.layout.frame.width - (model.layout.surface == .notch ? 30 : 28))
        guard laidOutLiveText != model.liveTranscript || liveTextWidth != width else { return }
        laidOutLiveText = model.liveTranscript
        liveTextWidth = width
        let text = VoiceLiveTranscriptPresentation.visibleTail(
            model.liveTranscript, width: width, size: model.livePreviewSize)
        if model.liveVisibleText != text { model.liveVisibleText = text }
    }
    private func clearLiveTranscript() {
        liveUpdateGeneration &+= 1
        liveUpdateTask?.cancel()
        liveUpdateTask = nil
        pendingLiveText = nil
        lastLiveUpdate = 0
        if !model.liveTranscript.isEmpty { model.liveTranscript = "" }
        if !model.liveVisibleText.isEmpty { model.liveVisibleText = "" }
        laidOutLiveText = ""
        liveTextWidth = 0
        if model.liveTranscriptStatus != nil { model.liveTranscriptStatus = nil }
        if model.liveRegionActive { model.liveRegionActive = false }
    }

    func hide() {
        model.copyShortcutLabel = nil
        model.previewInsertLabel = nil
        model.copyFeedback = nil
        configureRecognitionRecovery(nil)
        onCopyDraft = nil
        cancelCompletionNotice()
        clearLiveTranscript()
        panel?.orderOut(nil)
        panel?.ignoresMouseEvents = false
        model.result = ""
        model.resultContext = .preview
        model.message = nil
        model.recordingNoticeHeight = 0
        model.modeLabel = ""
        model.phase = .recording
        model.comparisonAvailable = false
        model.pauseAvailable = false
        model.showsPause = false
        model.levels = Array(repeating: 0, count: 7)
        caretBounds = nil
        preferredDisplay = nil
        configureOutputChoice(
            languages: [], refinement: false, refinementAvailable: false, selected: .original, changing: false)
    }

    func suspendPresentation() -> Bool {
        let wasVisible = panel?.isVisible == true
        if wasVisible { panel?.orderOut(nil) }
        return wasVisible
    }

    func restorePresentation() {
        relayout()
        panel?.orderFrontRegardless()
    }

    func updateCaretBounds(_ bounds: CGRect) {
        guard placement == .caret, VoiceCaretCoordinates.isValid(bounds), caretBounds != bounds else { return }
        caretBounds = bounds
        relayout()
    }

    #if YULLO_TESTING
        static func testPreviewStatus(insertLabel: String?) -> String {
            let fixture = VoiceOverlayModel()
            fixture.phase = .preview
            fixture.result = "Generated result."
            fixture.previewInsertLabel = insertLabel
            return fixture.statusTitle
        }
        static func testContent(
            phase: VoiceOverlayPhase, layout: VoiceOverlayLayout, choices: [String],
            selected: VoiceOutputChoice = .original,
            refinement: Bool = false, refinementAvailable: Bool = true, onChoose: ((VoiceOutputChoice) -> Void)? = nil,
            onTracking: ((Bool) -> Void)? = nil,
            theme: String = "system", liveTranscript: String = "", liveStatus: String? = nil,
            livePreviewSize: VoiceLivePreviewSize = .compact,
            changingOutput: Bool = false, onCopy: (() -> Void)? = nil, onSettings: (() -> Void)? = nil,
            onCompare: (() -> Void)? = nil,
            onActionEnabled: ((String, Bool) -> Void)? = nil,
            resultContext: VoiceOverlayResultContext = .preview, resultText: String? = nil,
            recordingNotice: String? = nil, onFinish: (() -> Void)? = nil,
            localizedLanguageNames: Bool = false, pauseAvailable: Bool = false, showsPause: Bool? = nil,
            onPauseResume: (() -> Void)? = nil, completionNotice: String? = nil,
            recognitionRecovery: VoiceRecognitionRecoverySnapshot? = nil, onCopyDraft: (() -> Void)? = nil,
            errorMessage: String? = nil, reduceTransparency: Bool? = nil, increasedContrast: Bool? = nil,
            onTranslucentFillChange: ((Bool) -> Void)? = nil,
            copyShortcutLabel: String? = nil, insertLabel: String? = nil, onInsert: (() -> Void)? = nil,
            copyFeedback: String? = nil, modeLabel: String? = nil,
            presetLabel: String = "", languageSwitch: [String] = [], outputLanguage: String? = nil,
            spokenLanguage: String? = nil, onLanguageChange: ((String?) -> Void)? = nil
        ) -> NSView {
            let fixture = VoiceOverlayModel()
            fixture.languageSwitch = languageSwitch
            fixture.outputLanguage = outputLanguage
            fixture.spokenLanguage = spokenLanguage
            fixture.onOutputLanguageChange = onLanguageChange
            fixture.presetLabel = presetLabel
            fixture.copyShortcutLabel = copyShortcutLabel
            fixture.previewInsertLabel = insertLabel
            fixture.onInsert = onInsert
            fixture.copyFeedback = copyFeedback
            fixture.phase = phase
            fixture.localizedLanguageNames = localizedLanguageNames
            fixture.languageNameLocale = L10n.language
            fixture.layout = layout
            fixture.outputLanguages = choices
            fixture.outputChoice = selected
            fixture.allowsRefinement = refinement
            fixture.refinementAvailable = refinementAvailable
            fixture.onOutputChoiceChange = onChoose
            fixture.onOutputMenuTracking = onTracking
            fixture.changingOutput = changingOutput
            fixture.onCopy = onCopy
            fixture.onCopyDraft = onCopyDraft
            fixture.recognitionRecovery = recognitionRecovery
            fixture.onFinish = onFinish
            fixture.onPauseResume = onPauseResume
            fixture.pauseAvailable = pauseAvailable
            fixture.showsPause = showsPause ?? pauseAvailable
            fixture.onSettings = onSettings
            fixture.onCompare = onCompare
            fixture.comparisonAvailable = onCompare != nil
            fixture.onActionEnabled = onActionEnabled
            fixture.onTranslucentFillChange = onTranslucentFillChange
            fixture.testReduceTransparency = reduceTransparency
            fixture.testIncreasedContrast = increasedContrast
            // An error card carries its output name without a menu, as the coordinator presents it.
            fixture.modeLabel =
                modeLabel
                ?? (choices.isEmpty && !resultContext.isEarlierOutput
                    ? "" : selected.title(localizedLanguageNames: localizedLanguageNames))
            fixture.result = phase == .preview ? resultText ?? "Generated mixed-language preview 中文 français." : ""
            fixture.resultContext = resultContext
            fixture.message = phase == .recording || phase == .paused ? recordingNotice : resultContext.message
            if phase == .error { fixture.message = errorMessage }
            if phase == .preview && fixture.result.isEmpty { fixture.message = completionNotice }
            fixture.recordingNoticeHeight = VoiceOverlayContentMetrics.recordingNoticeHeight(
                fixture.recordingNotice, width: layout.frame.width - (layout.surface == .notch ? 30 : 28))
            fixture.livePreviewSize = livePreviewSize
            fixture.liveTranscript = VoiceLiveTranscriptPresentation.tail(liveTranscript, size: livePreviewSize)
            fixture.liveVisibleText = VoiceLiveTranscriptPresentation.visibleTail(
                fixture.liveTranscript,
                width: layout.frame.width - (layout.surface == .notch ? 30 : 28), size: livePreviewSize)
            fixture.liveTranscriptStatus = liveStatus
            fixture.liveRegionActive = !fixture.liveTranscript.isEmpty || liveStatus != nil
            return ThemeHostingView(
                rootView: VoiceRecordingOverlayView(model: fixture), theme: theme,
                inheritedAppearance: NSApp.effectiveAppearance)
        }
    #endif

    private func relayout() {
        guard let panel, !NSScreen.screens.isEmpty else { return }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let anchor = caretBounds.flatMap {
            VoiceCaretCoordinates.appKitRect(fromAccessibility: $0, primaryScreenTop: top)
        }
        let target =
            anchor.flatMap { anchor in
                NSScreen.screens.max(by: {
                    $0.frame.intersection(anchor).area < $1.frame.intersection(anchor).area
                }).flatMap { $0.frame.intersects(anchor) ? $0 : nil }
            }
            ?? NSScreen.screens.first(where: {
                $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == preferredDisplay
                    && preferredDisplay != nil
            })
            ?? NSScreen.main ?? NSScreen.screens[0]
        let geometry = VoiceOverlayScreen(
            frame: target.frame, visibleFrame: target.visibleFrame, safeTop: target.safeAreaInsets.top,
            auxiliaryLeft: target.auxiliaryTopLeftArea ?? .zero, auxiliaryRight: target.auxiliaryTopRightArea ?? .zero)
        let showsPause = model.showsPause && (model.phase == .recording || model.phase == .paused)
        let confirmationWidth = VoiceOverlayContentMetrics.confirmationWidth(
            model.message ?? L10n.tr("Inserted"), briefNotice: completionNoticeActive)
        let compactWidth = VoiceOverlayContentMetrics.width(
            phase: model.phase, modeLabel: model.modeLabel,
            showsOutputChoice: (model.phase == .recording || model.phase == .paused) && !model.outputLanguages.isEmpty,
            choiceTitle: model.outputChoiceTitle, showsPause: showsPause, presetLabel: model.recordingPresetLabel,
            languageLabels: VoiceLanguageSwitch.labels(model.languageSwitch, spoken: model.spokenLanguage))
        let resultMaximum = VoiceOverlayContentMetrics.resultMaximum(model.resultContext)
        let previewSlack =
            model.phase == .preview && !model.result.isEmpty
            ? resultMaximum
                - VoiceOverlayContentMetrics.resultTextHeight(model.result, width: 360 - 30, maximum: resultMaximum)
            : 0
        var layout = VoiceOverlayGeometry.layout(
            placement: placement, phase: model.phase, anchor: anchor, screen: geometry,
            hasPreviewText: !model.result.isEmpty, compactWidth: compactWidth,
            hasLiveTranscript: model.liveRegionActive, recordingNoticeHeight: model.recordingNotice == nil ? 0 : 1,
            showsPause: showsPause, confirmationWidth: confirmationWidth,
            hasRecognitionRecovery: model.recognitionRecovery != nil,
            liveTextHeight: model.liveTranscriptStatus == nil ? model.livePreviewSize.textHeight : 36,
            previewSlack: previewSlack)
        let noticeHeight = VoiceOverlayContentMetrics.recordingNoticeHeight(
            model.recordingNotice, width: layout.frame.width - (layout.surface == .notch ? 30 : 28))
        if model.recordingNoticeHeight != noticeHeight { model.recordingNoticeHeight = noticeHeight }
        if noticeHeight > 0 {
            layout = VoiceOverlayGeometry.layout(
                placement: placement, phase: model.phase, anchor: anchor, screen: geometry,
                hasPreviewText: !model.result.isEmpty, compactWidth: compactWidth,
                hasLiveTranscript: model.liveRegionActive, recordingNoticeHeight: noticeHeight,
                showsPause: showsPause, confirmationWidth: confirmationWidth,
                hasRecognitionRecovery: model.recognitionRecovery != nil,
                liveTextHeight: model.liveTranscriptStatus == nil ? model.livePreviewSize.textHeight : 36,
                previewSlack: previewSlack)
        }
        layoutLanguage = L10n.language
        let animates = animatesNextResize && panel.isVisible
        animatesNextResize = false
        if model.layout != layout {
            if animates {
                withAnimation(.easeInOut(duration: Self.resizeDuration)) { model.layout = layout }
            } else {
                model.layout = layout
            }
        }
        if model.liveRegionActive { updateVisibleLiveTail() }
        let shadow = layout.surface == .glass
        if panel.hasShadow != shadow { panel.hasShadow = shadow }
        guard panel.frame != layout.frame else { return }
        if animates {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.resizeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(layout.frame, display: true)
            }
        } else {
            panel.setFrame(layout.frame, display: true)
        }
    }
    private static let resizeDuration = 0.18
}

private extension CGRect { var area: CGFloat { isNull || isEmpty ? 0 : width * height } }

// The recording indicator's flat HUD fill, shared with its Settings miniature:
// black at 0.78 in light appearance, rgb(58, 58, 62) at 0.92 in dark, opaque
// when transparency is reduced or contrast increased. Content is white.
enum VoiceHUDFill {
    static let light = Color.black.opacity(0.78)
    static let lightOpaque = Color(white: 0.08)
    static let darkOpaque = Color(red: 58 / 255, green: 58 / 255, blue: 62 / 255)
    static let dark = darkOpaque.opacity(0.92)
    static func color(dark: Bool, opaque: Bool) -> Color {
        dark ? (opaque ? darkOpaque : Self.dark) : (opaque ? lightOpaque : light)
    }
}

@available(macOS 26.0, *)
@MainActor private struct VoiceRecordingOverlayView: View {
    @ObservedObject var model: VoiceOverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    private var processing: Bool {
        model.phase == .preparing || model.phase == .transcribing || model.phase == .translating
            || model.phase == .refining
    }
    private var status: String {
        model.statusTitle
    }
    private var compactCaption: String {
        VoiceOverlayContentMetrics.caption(status: status, modeLabel: model.modeLabel, presetLabel: model.presetLabel)
    }
    private var recordingStatus: String {
        VoiceOverlayContentMetrics.caption(status: status, modeLabel: "", presetLabel: model.recordingPresetLabel)
    }
    private var showsRecordingLanguage: Bool {
        (model.phase == .recording || model.phase == .paused) && !model.outputLanguages.isEmpty
    }
    private var showsLiveTranscript: Bool {
        model.liveRegionActive && VoiceLiveTranscriptPresentation.displays(in: model.phase)
    }
    private var showsPause: Bool {
        model.showsPause && (model.phase == .recording || model.phase == .paused)
    }
    private var compactSurface: Bool {
        (model.phase != .error && model.phase != .preview || model.phase == .preview && model.result.isEmpty)
            && !showsLiveTranscript && model.recordingNotice == nil
    }
    // Keep the complete voice workflow on one flat dark HUD fill in both
    // appearances. Accessibility preferences make it opaque, not a white card.
    private var usesTranslucentFill: Bool {
        #if YULLO_TESTING
            // These system environment values are read-only. Inject their
            // reported values in fixtures, never change system preferences.
            let reducedTransparency = model.testReduceTransparency ?? reduceTransparency
            let highContrast = model.testIncreasedContrast ?? (contrast == .increased)
        #else
            let reducedTransparency = reduceTransparency
            let highContrast = contrast == .increased
        #endif
        return model.layout.surface == .glass && !reducedTransparency && !highContrast
    }
    private var usesHUDSurface: Bool { model.layout.surface == .glass }
    private var hudFill: Color {
        VoiceHUDFill.color(dark: colorScheme == .dark, opaque: !usesTranslucentFill)
    }
    private var supportingInk: AnyShapeStyle {
        usesHUDSurface
            ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(HierarchicalShapeStyle.secondary)
    }
    private var liveTextInk: AnyShapeStyle {
        usesHUDSurface ? AnyShapeStyle(Color.white) : AnyShapeStyle(HierarchicalShapeStyle.secondary)
    }
    var body: some View {
        Group {
            if model.layout.surface == .notch {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        activity.frame(maxWidth: .infinity)
                        Color.clear.frame(width: model.layout.cameraWidth).accessibilityHidden(true)
                        Group {
                            if model.phase == .preview && model.result.isEmpty {
                                Color.clear.accessibilityHidden(true)
                            } else {
                                recordingActions
                            }
                        }.frame(maxWidth: .infinity)
                    }.frame(height: model.layout.cameraBandHeight)
                    content.padding(.horizontal, 15).padding(.bottom, 8)
                }
                .foregroundStyle(.white.opacity(0.92))
                .background(
                    Color(white: 0.025),
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: 0, bottomLeadingRadius: 18, bottomTrailingRadius: 18, topTrailingRadius: 0)
                )
                .environment(\.colorScheme, .dark)
            } else {
                // A flat HUD fill, not glass; the hairline keeps its edge
                // readable over dark windows, and the panel adds the shadow.
                let shape = RoundedRectangle(cornerRadius: compactSurface ? 23 : 16)
                content.padding(.horizontal, 14).padding(.vertical, 10)
                    .foregroundStyle(Color.white, Color.white.opacity(0.92))
                    .environment(\.colorScheme, .dark)
                    .background(hudFill, in: shape)
                    .overlay { shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5) }
            }
        }
        .frame(width: model.layout.frame.width, height: model.layout.frame.height)
        .environment(\.locale, L10n.locale)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(status)
        #if YULLO_TESTING
            .onAppear { model.onTranslucentFillChange?(usesTranslucentFill) }
            .onChange(of: usesTranslucentFill) { _, value in model.onTranslucentFillChange?(value) }
        #endif
    }
    @ViewBuilder private var content: some View {
        if model.phase == .preview && model.result.isEmpty {
            HStack(spacing: 8) {
                if model.layout.surface == .glass {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .medium))
                        .frame(width: VoiceOverlayContentMetrics.confirmationIconWidth).accessibilityHidden(true)
                }
                Text(model.message ?? L10n.tr("Inserted")).font(.system(size: 12)).lineLimit(1)
            }.frame(maxWidth: .infinity).accessibilityIdentifier("voice-completion-notice")
                .background {
                    #if YULLO_TESTING
                        VoiceActionEnabledProbe(action: "Completion notice", report: model.onActionEnabled)
                    #endif
                }
        } else if model.phase == .preview || model.phase == .error {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(nsImage: BrandArtwork.templateImage).renderingMode(.template).resizable().scaledToFit().frame(
                        width: 15, height: 15
                    ).accessibilityHidden(true)
                    if model.phase == .error, model.recognitionRecovery != nil {
                        Text(L10n.tr("Partial draft")).font(.system(size: 12, weight: .semibold))
                    } else if model.phase == .preview, !model.outputLanguages.isEmpty, model.resultContext == .preview {
                        outputLanguageMenu()
                    } else {
                        // An error names the problem first; the output stays a quiet caption.
                        if model.resultContext.isEarlierOutput || model.phase == .error {
                            Text(status).font(BrandTypography.wordmark(size: 12)).layoutPriority(1)
                                .background {
                                    #if YULLO_TESTING
                                        VoiceActionEnabledProbe(action: "Header status", report: nil)
                                    #endif
                                }
                            if !model.modeLabel.isEmpty && model.outputLanguages.isEmpty {
                                Text(model.modeLabel).font(.system(size: 11)).foregroundStyle(supportingInk).lineLimit(
                                    1)
                            }
                        } else {
                            Text(
                                model.resultContext == .insertionUnconfirmed || model.modeLabel.isEmpty
                                    ? status : model.modeLabel
                            ).font(BrandTypography.wordmark(size: 12))
                        }
                    }
                    if model.changingOutput { activity }
                    Spacer()
                    if model.layout.surface == .glass { cancelButton }
                }
                if model.phase == .error, model.recognitionRecovery != nil, let message = model.message {
                    Text(message).font(.system(size: 11)).foregroundStyle(supportingInk).lineLimit(3)
                }
                if !model.result.isEmpty || (model.phase == .error && model.recognitionRecovery != nil) {
                    ScrollView {
                        Text(model.phase == .error ? model.recognitionRecovery?.text ?? "" : model.result).font(
                            .system(size: 13)
                        ).textSelection(.disabled).frame(
                            maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(
                        height: model.phase == .error && model.recognitionRecovery != nil
                            ? nil
                            : VoiceOverlayContentMetrics.resultTextHeight(
                                model.result,
                                width: model.layout.frame.width - (model.layout.surface == .notch ? 30 : 28),
                                maximum: VoiceOverlayContentMetrics.resultMaximum(model.resultContext))
                    )
                    .frame(maxHeight: model.phase == .error && model.recognitionRecovery != nil ? 110 : nil)
                    .background {
                        #if YULLO_TESTING
                            if model.phase == .error && model.recognitionRecovery != nil {
                                VoiceActionEnabledProbe(action: "Recovery text", report: model.onActionEnabled)
                            }
                        #endif
                    }
                }
                if model.phase == .error, let snapshot = model.recognitionRecovery {
                    Text(
                        [
                            L10n.tr(
                                snapshot.coverage == .latestWords
                                    ? "Latest words only. Review before use." : "Review before use."),
                            snapshot.truncated ? L10n.tr("Text limit reached.") : nil
                        ].compactMap { $0 }.joined(separator: " ")
                    ).font(.system(size: 11)).foregroundStyle(supportingInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.phase != .error || model.recognitionRecovery == nil, let message = model.message {
                    Text(message).font(.system(size: 11)).foregroundStyle(supportingInk).lineLimit(3)
                }
                HStack(spacing: 15) {
                    if model.phase == .error, model.recognitionRecovery != nil, model.onCopyDraft != nil {
                        Button {
                            model.onCopyDraft?()
                        } label: {
                            copyLabel("Copy draft")
                        }
                        .accessibilityIdentifier("voice-copy-draft")
                        .background {
                            #if YULLO_TESTING
                                VoiceActionEnabledProbe(action: "Copy draft", report: model.onActionEnabled)
                            #endif
                        }
                    }
                    if model.phase == .preview, !model.result.isEmpty, let key = model.previewInsertLabel,
                        model.onInsert != nil
                    {
                        // Leads the row: it is what ↩ does. Same label grammar as Copy.
                        Button {
                            model.onInsert?()
                        } label: {
                            actionLabel("Insert", key: key)
                        }
                        .accessibilityIdentifier("voice-insert")
                        .background {
                            #if YULLO_TESTING
                                VoiceActionEnabledProbe(action: "Insert", report: model.onActionEnabled)
                            #endif
                        }.disabled(model.changingOutput)
                    }
                    if !model.result.isEmpty, model.onCopy != nil {
                        Button {
                            model.onCopy?()
                        } label: {
                            copyLabel("Copy")
                        }
                        .background {
                            #if YULLO_TESTING
                                VoiceActionEnabledProbe(action: "Copy", report: model.onActionEnabled)
                            #endif
                        }.disabled(model.changingOutput)
                    }
                    if model.onSettings != nil {
                        Button(L10n.tr(model.settingsTitleKey)) { model.onSettings?() }
                            .background {
                                #if YULLO_TESTING
                                    VoiceActionEnabledProbe(action: "Settings", report: model.onActionEnabled)
                                #endif
                            }.disabled(model.changingOutput)
                    }
                    if model.phase == .preview, model.comparisonAvailable, model.onCompare != nil {
                        Button(L10n.tr("Compare")) { model.onCompare?() }
                            .accessibilityIdentifier("voice-compare")
                            .background {
                                #if YULLO_TESTING
                                    VoiceActionEnabledProbe(action: "Compare", report: model.onActionEnabled)
                                #endif
                            }.disabled(model.changingOutput)
                    }
                    if model.phase == .preview, model.resultContext != .preview,
                        !model.outputLanguages.isEmpty
                    {
                        outputLanguageMenu()
                    }
                }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(
                    model.layout.surface == .notch ? Color.white : Palette.accent)
                if let feedback = model.copyFeedback {
                    Text(feedback).font(.system(size: 11)).foregroundStyle(supportingInk)
                        .accessibilityIdentifier("voice-copy-feedback")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else if showsLiveTranscript || model.recordingNotice != nil {
            VStack(alignment: .leading, spacing: 8) {
                if showsLiveTranscript && model.layout.transcriptAboveControls { liveTranscript }
                recordingHeader
                if let notice = model.recordingNotice {
                    Text(notice).font(.system(size: 12)).foregroundStyle(supportingInk).lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: model.recordingNoticeHeight, alignment: .topLeading)
                        .accessibilityIdentifier("voice-recording-notice")
                        .background {
                            #if YULLO_TESTING
                                VoiceActionEnabledProbe(action: "Recording notice", report: nil)
                            #endif
                        }
                }
                if showsLiveTranscript && !model.layout.transcriptAboveControls { liveTranscript }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            recordingHeader
        }
    }
    private func copyLabel(_ title: String) -> some View { actionLabel(title, key: model.copyShortcutLabel) }
    // An action's name with its key in quieter ink, as in "Insert ↩" and "Copy ⇧⌘C".
    private func actionLabel(_ title: String, key: String?) -> some View {
        HStack(spacing: 5) {
            Text(L10n.tr(title))
            if let key {
                Text(key).font(.system(size: 10)).foregroundStyle(supportingInk)
            }
        }.accessibilityLabel(L10n.tr(title))
            .help([L10n.tr(title), key].compactMap { $0 }.joined(separator: " · "))
    }
    private var liveTranscript: some View {
        liveTranscriptContent.background {
            #if YULLO_TESTING
                VoiceActionEnabledProbe(action: "Live transcript", report: nil)
            #endif
        }
    }
    @ViewBuilder private var liveTranscriptContent: some View {
        if let message = model.liveTranscriptStatus {
            Text(message).font(.system(size: 12)).foregroundStyle(liveTextInk).lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
        } else if model.livePreviewSize == .scrolling {
            VoiceLiveTranscriptViewport(
                text: model.liveTranscript,
                textColor: usesHUDSurface ? .white : .secondaryLabelColor
            )
            .frame(height: model.layout.liveTextHeight)
            .accessibilityIdentifier("voice-live-text-scroll")
        } else {
            Text(model.liveVisibleText)
                .font(.system(size: 13)).foregroundStyle(liveTextInk).lineLimit(model.livePreviewSize.lineCount)
                .frame(
                    maxWidth: .infinity, minHeight: model.layout.liveTextHeight,
                    maxHeight: model.layout.liveTextHeight, alignment: .topLeading
                )
                .clipped()
                .accessibilityLabel(L10n.tr("Draft transcript"))
                .accessibilityValue(model.liveVisibleText)
        }
    }

    @ViewBuilder private var recordingHeader: some View {
        if model.layout.surface == .notch {
            if showsRecordingLanguage {
                HStack(spacing: 7) {
                    Text(recordingStatus).font(.system(size: 11)).lineLimit(1)
                    outputLanguageMenu(compact: true)
                    if !model.languageSwitch.isEmpty { languageSwitch }
                }.frame(maxWidth: .infinity)
            } else {
                Text(compactCaption).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity).accessibilityLabel(compactCaption)
            }
        } else {
            HStack(spacing: showsRecordingLanguage ? 8 : 9) {
                activity
                if showsRecordingLanguage {
                    Text(recordingStatus).font(.system(size: 12)).lineLimit(1).minimumScaleFactor(0.8)
                        .layoutPriority(1)
                    outputLanguageMenu(compact: true)
                    if !model.languageSwitch.isEmpty { languageSwitch }
                } else {
                    Text(compactCaption).font(.system(size: 12)).lineLimit(1).minimumScaleFactor(0.8)
                        .accessibilityLabel(compactCaption)
                }
                recordingActions
            }.frame(maxWidth: .infinity)
        }
    }
    private func outputLanguageMenu(compact: Bool = false) -> some View {
        VoiceOutputMenu(
            choices: model.outputLanguages, allowsRefinement: model.allowsRefinement,
            refinementAvailable: model.refinementAvailable, selected: model.shownOutputChoice, compact: compact,
            switchesLanguage: !model.languageSwitch.isEmpty, formats: model.formats,
            onChoose: model.onOutputChoiceChange, onFormat: model.onFormatChange,
            onTracking: model.onOutputMenuTracking,
            localizedLanguageNames: model.localizedLanguageNames, languageNameLocale: model.languageNameLocale
        )
        .fixedSize(horizontal: !compact, vertical: true)
        .frame(width: compact ? VoiceOverlayContentMetrics.menuWidth(model.outputChoiceTitle) : nil)
        .frame(height: compact ? 18 : 20)
        .accessibilityIdentifier("voice-output-choice")
        .help(model.localizedLanguageNames ? model.outputChoiceTitle : L10n.tr("Output mode"))
        .accessibilityLabel(L10n.tr("Output mode"))
    }
    // The output language in the menu's quiet type; a click moves to the next one.
    private var languageSwitch: some View {
        let label = VoiceLanguageSwitch.label(model.outputLanguage, among: model.languageSwitch)
        let name =
            model.outputLanguage.map {
                L10n.format(
                    "Write in %@",
                    Language.displayName(for: $0, localized: model.localizedLanguageNames, locale: L10n.locale))
            } ?? L10n.tr("Write in the language you speak")
        return Button {
            model.onOutputLanguageChange?(
                VoiceLanguageSwitch.next(after: model.outputLanguage, in: model.languageSwitch))
        } label: {
            if model.outputLanguage == nil {
                sameAsSpoken
            } else {
                Text(label).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
        }
        .buttonStyle(VoiceLanguageTagStyle())
        .frame(
            width: VoiceOverlayContentMetrics.languageWidth(
                VoiceLanguageSwitch.labels(model.languageSwitch, spoken: model.spokenLanguage))
        )
        .accessibilityIdentifier("voice-output-language")
        .accessibilityLabel(L10n.tr("Language"))
        .accessibilityValue(name)
        .accessibilityHint(L10n.tr("Changes the output language for this recording."))
        .help(name)
        .background {
            #if YULLO_TESTING
                VoiceActionEnabledProbe(action: "Output language", report: model.onActionEnabled)
            #endif
        }
    }
    @ViewBuilder private var sameAsSpoken: some View {
        if model.spokenLanguage == nil {
            Image(systemName: "waveform").font(.system(size: 10, weight: .medium))
        } else {
            HStack(spacing: 3) {
                Image(systemName: "waveform").font(.system(size: 8, weight: .semibold)).opacity(0.75)
                Text(VoiceLanguageSwitch.spokenCode(model.spokenLanguage, among: model.languageSwitch))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
        }
    }
    @ViewBuilder private var activity: some View {
        if model.phase == .preview && model.result.isEmpty {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .medium)).frame(width: 28, height: 18)
                .accessibilityHidden(true)
        } else if model.phase == .paused {
            Image(systemName: "pause.fill").font(.system(size: 11, weight: .medium)).frame(width: 28, height: 18)
                .foregroundStyle(supportingInk).accessibilityHidden(true)
        } else if processing || model.changingOutput {
            TimelineView(.animation(minimumInterval: 0.35, paused: reduceMotion)) { context in
                let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.35) % 3
                HStack(spacing: 3) {
                    ForEach(0..<3) { index in
                        Circle().fill(.primary.opacity(reduceMotion || tick == index ? 0.85 : 0.3)).frame(
                            width: 3, height: 3)
                    }
                }.frame(width: 28, height: 18)
            }.accessibilityHidden(true)
        } else {
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(model.levels.enumerated()), id: \.offset) { sample in
                    Capsule().frame(width: 2, height: 2 + 16 * sample.element)
                }
            }.frame(width: 28, height: 18).accessibilityHidden(true)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: model.levels)
        }
    }
    private var recordingActions: some View {
        HStack(spacing: 4) {
            if showsPause {
                Button {
                    guard model.pauseAvailable else { return }
                    model.onPauseResume?()
                } label: {
                    Image(systemName: model.phase == .paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 10)).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).focusable(false)
                .help(L10n.tr(model.phase == .paused ? "Resume recording" : "Pause recording"))
                .accessibilityLabel(L10n.tr(model.phase == .paused ? "Resume recording" : "Pause recording"))
                .background {
                    #if YULLO_TESTING
                        VoiceActionEnabledProbe(
                            action: model.phase == .paused ? "Resume recording" : "Pause recording",
                            report: model.onActionEnabled)
                    #endif
                }
                .disabled(!model.pauseAvailable)
            }
            primaryAction
        }.fixedSize()
    }
    @ViewBuilder private var primaryAction: some View {
        if model.phase == .recording || model.phase == .paused {
            Button {
                model.onFinish?()
            } label: {
                Image(systemName: "stop.fill").font(.system(size: 9)).frame(width: 24, height: 24).contentShape(
                    Rectangle())
            }
            .buttonStyle(.plain).focusable(false).help(L10n.tr("Finish recording"))
            .background {
                #if YULLO_TESTING
                    VoiceActionEnabledProbe(action: "Finish recording", report: model.onActionEnabled)
                #endif
            }
            .accessibilityLabel(L10n.tr("Finish recording"))
        } else {
            cancelButton
        }
    }
    private var cancelButton: some View {
        // A finished result or error card only closes; work in progress is cancelled.
        let key = model.phase == .preview || model.phase == .error ? "Close" : "Cancel"
        return Button {
            model.onCancel?()
        } label: {
            Image(systemName: "xmark").font(.system(size: 10)).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusable(false).help(L10n.tr(key))
        .background {
            #if YULLO_TESTING
                VoiceActionEnabledProbe(action: "Dismiss " + key, report: nil)
            #endif
        }
        .accessibilityLabel(L10n.tr(key))
    }
}

#if YULLO_TESTING
    private struct VoiceActionEnabledProbe: NSViewRepresentable {
        let action: String
        let report: ((String, Bool) -> Void)?
        @Environment(\.isEnabled) private var isEnabled
        final class ProbeView: NSView {
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
        func makeNSView(context: Context) -> NSView {
            let view = ProbeView(frame: .zero)
            view.identifier = NSUserInterfaceItemIdentifier("voice-action-" + action)
            view.setAccessibilityElement(false)
            return view
        }
        func updateNSView(_ view: NSView, context: Context) { report?(action, isEnabled) }
    }
#endif

// A quiet tag, so the language reads as something to click rather than a status.
private struct VoiceLanguageTagStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Tag(configuration: configuration) }
    private struct Tag: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label.padding(.horizontal, 6).padding(.vertical, 2)
                .frame(maxWidth: .infinity)
                .background(
                    Color.white.opacity(configuration.isPressed ? 0.22 : hovering ? 0.16 : 0.12),
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5))
                .onHover { hovering = $0 }
        }
    }
}

// Own native menu tracking instead of watching unrelated application menus.
// The recording remains nonactivating; AppKit handles menu keyboard navigation.
@MainActor private struct VoiceOutputMenu: NSViewRepresentable {
    let choices: [String]
    let allowsRefinement: Bool
    let refinementAvailable: Bool
    let selected: VoiceOutputChoice
    let compact: Bool
    // The language switch names languages, so the menu holds formats only.
    var switchesLanguage = false
    var formats: VoiceFormatMenu? = nil
    let onChoose: ((VoiceOutputChoice) -> Void)?
    var onFormat: ((String) -> Void)? = nil
    let onTracking: ((Bool) -> Void)?
    var localizedLanguageNames = false
    var languageNameLocale = ""

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.focusRingType = .none
        button.setAccessibilityIdentifier("voice-output-choice")
        button.setAccessibilityLabel(L10n.tr("Output mode"))
        button.toolTip = L10n.tr("Output mode")
        if let cell = button.cell as? NSPopUpButtonCell {
            cell.usesItemFromMenu = true
            cell.altersStateOfSelectedItem = false
            cell.lineBreakMode = .byTruncatingTail
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        button.menu = menu
        context.coordinator.button = button
        context.coordinator.update(self, force: true)
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let appearance: NSAppearance.Name = context.environment.colorScheme == .dark ? .darkAqua : .aqua
        if button.appearance?.name != appearance { button.appearance = NSAppearance(named: appearance) }
        context.coordinator.update(self)
    }
    static func dismantleNSView(_ button: NSPopUpButton, coordinator: Coordinator) {
        button.menu?.cancelTracking()
        coordinator.endTracking()
        button.menu?.delegate = nil
    }

    @MainActor final class Coordinator: NSObject, NSMenuDelegate {
        private final class Choice: NSObject {
            let output: VoiceOutputChoice
            let select: ((VoiceOutputChoice) -> Void)?
            init(_ output: VoiceOutputChoice, select: ((VoiceOutputChoice) -> Void)?) {
                self.output = output
                self.select = select
            }
        }
        private final class FormatChoice: NSObject {
            let format: String
            let select: ((String) -> Void)?
            init(_ format: String, select: ((String) -> Void)?) {
                self.format = format
                self.select = select
            }
        }
        private var renderedFormats: VoiceFormatMenu?
        private var parent: VoiceOutputMenu
        weak var button: NSPopUpButton?
        private var tracking = false
        private var trackingCallback: ((Bool) -> Void)?
        private var renderedChoices: [String] = []
        private var renderedSelection: VoiceOutputChoice?
        private var renderedRefinement = false
        private var renderedAvailability = false
        private var renderedCompact: Bool?
        private var renderedSwitchesLanguage = false
        private var renderedLocalizedNames: Bool?
        private var renderedNameLocale = ""
        init(_ parent: VoiceOutputMenu) { self.parent = parent }

        func update(_ parent: VoiceOutputMenu, force: Bool = false) {
            self.parent = parent
            guard !tracking, let button, let menu = button.menu,
                force || renderedChoices != parent.choices || renderedSelection != parent.selected
                    || renderedCompact != parent.compact || renderedRefinement != parent.allowsRefinement
                    || renderedSwitchesLanguage != parent.switchesLanguage
                    || renderedAvailability != parent.refinementAvailable
                    || renderedLocalizedNames != parent.localizedLanguageNames
                    || renderedNameLocale != parent.languageNameLocale || renderedFormats != parent.formats
            else { return }
            renderedFormats = parent.formats
            renderedChoices = parent.choices
            renderedSelection = parent.selected
            renderedCompact = parent.compact
            renderedSwitchesLanguage = parent.switchesLanguage
            renderedRefinement = parent.allowsRefinement
            renderedAvailability = parent.refinementAvailable
            renderedLocalizedNames = parent.localizedLanguageNames
            renderedNameLocale = parent.languageNameLocale
            menu.removeAllItems()
            let title =
                parent.formats.flatMap { $0.selected.isEmpty ? nil : $0.title($0.selected) }
                ?? parent.selected.title(localizedLanguageNames: parent.localizedLanguageNames)
            button.setAccessibilityLabel(L10n.tr("Output mode"))
            button.setAccessibilityValue(title)
            button.toolTip = parent.localizedLanguageNames ? title : L10n.tr("Output mode")
            let display = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            menu.addItem(display)
            display.isHidden = true
            func add(_ output: VoiceOutputChoice, title: String, to destination: NSMenu) {
                let item = NSMenuItem(title: title, action: #selector(selectOutput(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = Choice(output, select: parent.onChoose)
                item.state = output == parent.selected ? .on : .off
                destination.addItem(item)
                item.isHidden = false
            }
            if let formats = parent.formats {
                addFormats(formats, to: menu)
                button.font = .systemFont(ofSize: parent.compact ? 11 : 12, weight: .medium)
                button.selectItem(at: 0)
                button.invalidateIntrinsicContentSize()
                return
            }
            add(.original, title: L10n.tr("Original"), to: menu)
            if !parent.switchesLanguage {
                menu.addItem(.separator())
                let translations = NSMenu()
                for language in parent.choices {
                    add(
                        .translation(language),
                        title: Language.displayName(
                            for: language, localized: parent.localizedLanguageNames, locale: L10n.locale),
                        to: translations)
                }
                let translate = NSMenuItem(title: L10n.tr("Translate"), action: nil, keyEquivalent: "")
                translate.submenu = translations
                menu.addItem(translate)
            }
            if parent.allowsRefinement {
                if parent.switchesLanguage { menu.addItem(.separator()) }
                let styles = NSMenu()
                for style in RewriteStyle.everyday {
                    add(.refinement(style), title: VoiceOutputChoice.styleTitle(style), to: styles)
                }
                let refine = NSMenuItem(title: L10n.tr("Refine"), action: nil, keyEquivalent: "")
                refine.submenu = styles
                refine.isEnabled = parent.refinementAvailable
                menu.addItem(refine)
            }
            button.font = .systemFont(ofSize: parent.compact ? 11 : 12, weight: .medium)
            button.selectItem(at: 0)
            button.invalidateIntrinsicContentSize()
        }
        // What I say and Cleaned up, then this recording's own formats, then More.
        // Without the language switch, Translate keeps its languages after More.
        private func addFormats(_ formats: VoiceFormatMenu, to menu: NSMenu) {
            func add(_ format: String, to destination: NSMenu) {
                let item = NSMenuItem(
                    title: formats.title(format), action: #selector(selectFormat(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = FormatChoice(format, select: parent.onFormat)
                item.state = format == formats.selected ? .on : .off
                item.isEnabled = !formats.writes.contains(format) || parent.refinementAvailable
                destination.addItem(item)
            }
            for (index, format) in formats.top.enumerated() {
                if index == formats.pinned { menu.addItem(.separator()) }
                add(format, to: menu)
            }
            menu.addItem(.separator())
            if !formats.more.isEmpty {
                let more = NSMenu()
                for (index, group) in formats.more.enumerated() {
                    if index > 0 { more.addItem(.separator()) }
                    for format in group { add(format, to: more) }
                }
                let item = NSMenuItem(title: L10n.tr("More"), action: nil, keyEquivalent: "")
                item.submenu = more
                menu.addItem(item)
            }
            if !parent.switchesLanguage {
                let translations = NSMenu()
                for language in parent.choices {
                    let item = NSMenuItem(
                        title: Language.displayName(
                            for: language, localized: parent.localizedLanguageNames, locale: L10n.locale),
                        action: #selector(selectOutput(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = Choice(.translation(language), select: parent.onChoose)
                    item.state = parent.selected == .translation(language) ? .on : .off
                    translations.addItem(item)
                }
                let translate = NSMenuItem(title: L10n.tr("Translate"), action: nil, keyEquivalent: "")
                translate.submenu = translations
                menu.addItem(translate)
            }
        }
        @objc private func selectFormat(_ item: NSMenuItem) {
            guard let choice = item.representedObject as? FormatChoice else { return }
            choice.select?(choice.format)
        }
        @objc private func selectOutput(_ item: NSMenuItem) {
            guard let choice = item.representedObject as? Choice else { return }
            choice.select?(choice.output)
        }
        func menuWillOpen(_ menu: NSMenu) {
            update(parent, force: true)
            tracking = true
            trackingCallback = parent.onTracking
            trackingCallback?(true)
        }
        func menuDidClose(_ menu: NSMenu) { endTracking() }
        func endTracking() {
            guard tracking else { return }
            tracking = false
            let finished = trackingCallback
            trackingCallback = nil
            finished?(false)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.update(self.parent)
            }
        }
    }
}

// A small read-only viewport keeps all currently available provisional text
// scrollable without letting the HUD grow or taking the insertion target's focus.
@MainActor struct VoiceLiveTranscriptViewport: NSViewRepresentable {
    let text: String
    let textColor: NSColor
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    final class TextView: NSTextView {
        override var acceptsFirstResponder: Bool { false }
    }
    final class ScrollView: NSScrollView {
        var layoutContent: (@MainActor () -> Void)?
        override func layout() {
            super.layout()
            layoutContent?()
        }
    }
    @MainActor final class Coordinator {
        var text = ""
        var renderedText: String?
        var width: CGFloat = -1
        var viewportHeight: CGFloat = -1
        var updating = false
        func render(in scroll: NSScrollView) {
            guard !updating, let editor = scroll.documentView as? NSTextView,
                scroll.contentSize.width > 1, scroll.contentSize.height > 1
            else { return }
            let nextWidth = scroll.contentSize.width, nextHeight = scroll.contentSize.height
            guard renderedText != text || width != nextWidth || viewportHeight != nextHeight else { return }
            updating = true
            defer { updating = false }
            let visible = scroll.contentView.documentVisibleRect
            let followsEnd = renderedText == nil || visible.maxY >= editor.frame.height - 3
            let oldOrigin = scroll.contentView.bounds.origin
            width = nextWidth
            viewportHeight = nextHeight
            if renderedText != text {
                let paragraph = NSMutableParagraphStyle()
                paragraph.minimumLineHeight = 18
                paragraph.lineBreakMode = .byWordWrapping
                editor.textStorage?.setAttributedString(
                    NSAttributedString(
                        string: text,
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 13), .paragraphStyle: paragraph,
                            .foregroundColor: editor.textColor ?? NSColor.secondaryLabelColor
                        ]))
                renderedText = text
            }
            if let container = editor.textContainer, let layout = editor.layoutManager {
                // AppKit can change the clip width when a scrollbar appears.
                // Finish that one transition before following the end; automatic
                // text-view resizing must not move the target after we scroll.
                for _ in 0..<2 {
                    let contentWidth = scroll.contentSize.width
                    editor.setFrameSize(NSSize(width: contentWidth, height: editor.frame.height))
                    container.containerSize = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
                    layout.ensureLayout(for: container)
                    let height = max(nextHeight, ceil(layout.usedRect(for: container).maxY))
                    editor.setFrameSize(NSSize(width: contentWidth, height: height))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    scroll.tile()
                    if scroll.contentSize.width == contentWidth { break }
                }
                width = scroll.contentSize.width
                let height = editor.frame.height
                scroll.contentView.scroll(
                    to: NSPoint(
                        x: 0,
                        y: followsEnd ? max(0, height - nextHeight) : min(oldOrigin.y, max(0, height - nextHeight))))
                scroll.reflectScrolledClipView(scroll.contentView)
            }

        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> ScrollView {
        let scroll = ScrollView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.verticalScroller?.controlSize = .small
        scroll.horizontalScrollElasticity = .none
        let editor = TextView()
        editor.isEditable = false
        editor.isSelectable = false
        editor.isRichText = false
        editor.drawsBackground = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.writingToolsBehavior = .none
        editor.font = .systemFont(ofSize: 13)
        editor.textColor = textColor
        editor.textContainerInset = .zero
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = false
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.lineFragmentPadding = 0
        editor.setAccessibilityLabel(L10n.tr("Draft transcript"))
        editor.setAccessibilityIdentifier("voice-live-text")
        scroll.documentView = editor
        let coordinator = context.coordinator
        scroll.layoutContent = { [weak coordinator, weak scroll] in
            guard let scroll else { return }
            coordinator?.render(in: scroll)
        }
        return scroll
    }
    static func dismantleNSView(_ scroll: ScrollView, coordinator: Coordinator) {
        scroll.layoutContent = nil
        coordinator.text = ""
        coordinator.renderedText = nil
        coordinator.width = -1
        coordinator.viewportHeight = -1
        if let editor = scroll.documentView as? NSTextView { editor.string = "" }
    }

    func updateNSView(_ scroll: ScrollView, context: Context) {
        let name: NSAppearance.Name =
            contrast == .increased
            ? (colorScheme == .dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (colorScheme == .dark ? .darkAqua : .aqua)
        if scroll.appearance?.name != name { scroll.appearance = NSAppearance(named: name) }
        if let editor = scroll.documentView as? NSTextView, editor.textColor?.isEqual(textColor) != true {
            editor.textColor = textColor
        }
        context.coordinator.text = text
        context.coordinator.render(in: scroll)
    }
}
