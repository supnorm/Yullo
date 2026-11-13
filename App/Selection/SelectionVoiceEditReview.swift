import AppKit
import Combine
import NaturalLanguage
import SwiftUI

// The review after Edit with voice, drawn as the Yullo selection window: its
// glass, brand row and pane, with the revised text as the hero. One row of
// actions says what each does and its key: Undo, Try again (⌘R), Change… (⌘↩,
// or just start typing), Copy and Replace (↩). Esc steps back: out of a change
// being typed, out of a running change, then out of the review. Copy goes
// through the injected writer only while the review is current.
@MainActor final class SelectionVoiceEditReview: NSView {
    // What the review says under its text. On the guide's sample there is no app in
    // front to warn about, but every status and problem still shows.
    static func lines(message: String, appWarning: String?, onSample: Bool) -> [String] {
        var lines = [message]
        if !onSample, let appWarning, !appWarning.isEmpty, !message.contains(appWarning) {
            lines.insert(appWarning, at: 0)
        }
        return lines.filter { !$0.isEmpty }
    }
    struct Content: Equatable {
        var edited: String
        var message: String
        var canReplace: Bool
        var replacing: Bool
        var canUndo = false
        // A further change is in progress; the result it refines stays shown.
        var working = false
        // The selection can still be written: Replace stays in place, disabled, while a change runs.
        var replaceable = false
        // The Yullo window's result size; long text is set a step smaller.
        var textSize: CGFloat = 20
        // The text before any change (the guide's sample): read as source, not as a result.
        var unchanged = false
        // Edit with text before its first result: only the request field shows, and
        // the result takes its place in the same window, at its left edge and width.
        var asking = false
        // The Edit with voice key, to say a change with ("⌃⇧S"); nil when it has none.
        var voiceKey: String? = nil
        // The text as it was selected: what changed from it is marked, quietly; it is never shown.
        var original: String? = nil
    }
    struct Actions {
        var isCurrent: () -> Bool
        var close: () -> Void
        var replace: () -> Void
        var recordAgain: (() -> Void)?
        var request: ((String) -> Void)?
        var undo: (() -> Void)?
        var tryAgain: (() -> Void)? = nil
        var fix: (title: String, run: () -> Void)?
        var copy: (String) -> Bool
        // Ends just the change in progress, keeping the earlier result.
        var stop: (() -> Void)? = nil
    }
    static let width: CGFloat = 440
    static let minimumWidth: CGFloat = 400
    // How the revised text is set for its length: short text at the Yullo
    // window's result size in the usual width; longer text a step smaller in a
    // wider window (about 70 characters a line), as tall as the screen near the
    // selection allows. It scrolls only past that.
    struct Layout: Equatable {
        var width: CGFloat
        var textSize: CGFloat
        var textLimit: CGFloat
    }
    // The window around the text: brand row, pane padding and the action row.
    static let chrome: CGFloat = 56 + 28 + 12 + 28 + 12 + 10
    static func layout(for text: String, resultSize: CGFloat, screenHeight: CGFloat, screenWidth: CGFloat)
        -> Layout
    {
        let room = max(200, screenHeight * 0.8 - chrome)
        let short = SelectionVoiceEditReviewView.height(of: text, size: resultSize, width: width - 56)
        if short <= min(room, 5 * resultSize * 1.6) {
            return .init(width: width, textSize: resultSize, textLimit: room)
        }
        let reading = min(resultSize, 16)
        let wide = min(580, max(width, screenWidth - 48))
        return .init(width: wide, textSize: reading, textLimit: room)
    }
    // The Yullo selection window's corners.
    static let cornerRadius: CGFloat = 23

    let state: SelectionVoiceEditReviewState
    private let host: ThemeHostingView<TopAlignedReview>
    private var keyMonitor: Any?
    private var changingObserver: AnyCancellable?
    private var showsChangesObserver: AnyCancellable?
    private var outsideMonitor: Any?
    private var visibleObserver: NSObjectProtocol?

    init(
        content: Content, backend: VoiceComparisonBackend, isCurrent: @escaping () -> Bool,
        close: @escaping () -> Void, replace: @escaping () -> Void, recordAgain: (() -> Void)?,
        request: ((String) -> Void)? = nil, undo: (() -> Void)? = nil, tryAgain: (() -> Void)? = nil,
        stop: (() -> Void)? = nil, fix: (title: String, run: () -> Void)?, theme: String = "system"
    ) {
        state = SelectionVoiceEditReviewState(
            content: content,
            actions: Self.actions(
                backend: backend, isCurrent: isCurrent, close: close, replace: replace, recordAgain: recordAgain,
                request: request, undo: undo, tryAgain: tryAgain, stop: stop, fix: fix))
        host = ThemeHostingView(
            rootView: TopAlignedReview(review: SelectionVoiceEditReviewView(state: state)), theme: theme,
            inheritedAppearance: NSApp.effectiveAppearance)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 300))
        // A typed request starts in its field.
        if content.asking { state.changing = true }
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        // Opening or closing Change… resizes the window, keeping its top edge.
        changingObserver = state.$changing.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.fitWindow(animated: true) }
        }
        // Showing changes, and a change landing, change the text's length: the bottom follows, eased.
        showsChangesObserver = state.$showsChanges.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.fitWindow(animated: true, reflow: true) }
        }
        state.morphLanded = { [weak self] in self?.fitWindow(animated: true, reflow: true) }
        state.textHeight = { [weak self] height, final in self?.follow(height, final: final) }
        state.shown = { [weak self] in self?.window?.isVisible == true }
        // The first result arrives from the selection as it was.
        state.beginMorph(from: content.original)
    }

    // The window hugs the review at its width, its top edge where it was. A reflow (a change
    // landing, changes shown or hidden) moves the bottom with the same ease-in-out as the text.
    func fitWindow(animated: Bool, reflow: Bool = false) {
        guard let window else { return }
        let least = minimumContentWidth
        let width = max(window.contentLayoutRect.width, least)
        let height = fittingHeight(width: width)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: width, height: height)))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let screen = window.screen?.visibleFrame {
            if frame.minY < screen.minY + 8 { frame.origin.y = screen.minY + 8 }
            // Widened for its actions, it stays on the screen.
            if frame.maxX > screen.maxX - 8 { frame.origin.x = max(screen.minX + 8, screen.maxX - 8 - frame.width) }
        }
        guard
            abs(frame.height - window.frame.height) > 0.5 || abs(frame.width - window.frame.width) > 0.5
                || frame.origin != window.frame.origin
        else { return }
        window.contentMinSize = NSSize(width: least, height: height)
        if animated, window.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            state.settlesAt = Date().addingTimeInterval(reflow ? MorphTiming.reflow : 0.18)
            NSAnimationContext.runAnimationGroup { context in
                // A reflow rides the words' spring: critically damped, no overshoot.
                context.duration = reflow ? MorphTiming.reflow : 0.18
                context.timingFunction =
                    reflow
                    ? CAMediaTimingFunction(controlPoints: 0.3, 0, 0.1, 1) : CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }
    required init?(coder: NSCoder) { fatalError("Use init(content:backend:isCurrent:close:replace:recordAgain:fix:)") }

    // A newer state of the same review: the text changes in place, softly.
    func update(
        content: Content, backend: VoiceComparisonBackend, isCurrent: @escaping () -> Bool,
        close: @escaping () -> Void, replace: @escaping () -> Void, recordAgain: (() -> Void)?,
        request: ((String) -> Void)? = nil, undo: (() -> Void)? = nil, tryAgain: (() -> Void)? = nil,
        stop: (() -> Void)? = nil, fix: (title: String, run: () -> Void)?
    ) {
        state.actions = Self.actions(
            backend: backend, isCurrent: isCurrent, close: close, replace: replace, recordAgain: recordAgain,
            request: request, undo: undo, tryAgain: tryAgain, stop: stop, fix: fix)
        state.invalidated = false
        let previous = state.content
        if content.edited != previous.edited { state.changing = false }
        if previous.asking, !content.asking, !content.edited.isEmpty, window?.isVisible == true {
            state.awaitingSize = true
        }
        // A new result arrives from the text it changes: the earlier result, or the selection.
        let morphs = content.edited != previous.edited && !content.edited.isEmpty
        withAnimation(
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || morphs ? nil : .easeOut(duration: 0.22)
        ) {
            state.content = content
        }
        if morphs {
            let fresh = previous.edited.isEmpty || previous.asking
            state.beginMorph(from: fresh ? content.original : previous.edited, firstLook: fresh)
        }
        // A typed request that couldn't be used: its field takes typing again, the text kept.
        if content.asking, !content.working, !state.changing {
            state.fieldReady = false
            state.pendingKeys = []
            state.changing = true
        }
    }

    private static func actions(
        backend: VoiceComparisonBackend, isCurrent: @escaping () -> Bool, close: @escaping () -> Void,
        replace: @escaping () -> Void, recordAgain: (() -> Void)?, request: ((String) -> Void)?,
        undo: (() -> Void)?, tryAgain: (() -> Void)?, stop: (() -> Void)?, fix: (title: String, run: () -> Void)?
    ) -> Actions {
        .init(
            isCurrent: isCurrent, close: close, replace: replace, recordAgain: recordAgain, request: request,
            undo: undo, tryAgain: tryAgain, fix: fix,
            copy: { text in
                guard isCurrent(), !text.isEmpty else { return false }
                return backend.write(text, backend.pasteboard())
            }, stop: stop)
    }

    func setTheme(_ value: String) { host.setTheme(value) }
    // The height the review hugs at a width, measured on the same view.
    // Sets the text for its length on this screen; returns the width to use.
    @discardableResult func applyLayout(screen: CGRect) -> CGFloat {
        let layout = Self.layout(
            for: state.content.edited, resultSize: state.content.textSize, screenHeight: screen.height,
            screenWidth: screen.width)
        state.textLimit = layout.textLimit
        state.readingSize = layout.textSize
        return max(layout.width, minimumContentWidth)
    }
    // As wide as the action row can ever be in this language: every action it may show (Undo,
    // Try Again, Change…, Copy or Replace, Copied), so no button is cut off and the window never
    // has to widen later. Never narrower than the review's own minimum.
    var minimumContentWidth: CGFloat {
        var widest: CGFloat = 0
        for replaces in [true, false] {
            var content = state.content
            content.asking = false
            content.working = false
            content.unchanged = false
            content.canUndo = true
            content.canReplace = replaces
            content.replaceable = replaces
            // The row doesn't depend on the text: a stand-in keeps the measure quick.
            content.edited = "x"
            content.original = nil
            let row = SelectionVoiceEditReviewState(
                content: content,
                actions: .init(
                    isCurrent: { true }, close: {}, replace: {}, recordAgain: nil, request: { _ in }, undo: {},
                    tryAgain: {}, fix: nil, copy: { _ in false }))
            row.copied = !replaces
            let measure = NSHostingController(rootView: SelectionVoiceEditReviewView(state: row, actionsOnly: true))
            widest = max(widest, measure.sizeThatFits(in: CGSize(width: 10_000, height: 100)).width)
        }
        // The pane's inset (18 each side) inside the window's (10 each side).
        return max(Self.minimumWidth, ceil(widest) + 56)
    }
    // Where the window goes and how big it is, for a new review: the text set
    // for its length, under (or above) the selection's last line. When the
    // whole text can't fit beside the selection, the text scrolls inside the
    // larger free space rather than covering the selection.
    func placement(in visible: CGRect, selection: CGRect?, end: CGRect?, pointer: CGPoint, chrome: NSSize = .zero)
        -> NSRect
    {
        let width = min(applyLayout(screen: visible), visible.width - 24)
        func frame(_ height: CGFloat) -> NSRect {
            let size = NSSize(width: width + chrome.width, height: height + chrome.height)
            let origin = resultPanelOrigin(
                selection: selection, end: end, pointer: pointer, visible: visible, size: size)
            return NSRect(origin: origin, size: size)
        }
        var placed = frame(fittingHeight(width: width))
        let covered = [selection, end].compactMap { $0 }.reduce(CGRect.null) { $0.union($1) }
        guard !covered.isNull, placed.intersects(covered) else { return placed }
        let line = end ?? CGRect(x: covered.minX, y: covered.minY, width: covered.width, height: 1)
        let below = line.minY - visible.minY - 22, above = visible.maxY - covered.maxY - 22
        let room = max(below, above) - chrome.height
        guard room >= 180 else { return placed }
        let size = state.readingSize ?? state.content.textSize
        var text = min(
            state.textLimit,
            SelectionVoiceEditReviewView.height(of: state.content.edited, size: size, width: width - 56))
        // Measure again until the window fits the room; the text scrolls inside it.
        for _ in 0..<4 where placed.height > room {
            text -= placed.height - room + 2
            guard text >= 60 else { break }
            state.textLimit = text
            placed = frame(fittingHeight(width: width))
        }
        return placed
    }
    // During an arrival the window's bottom edge moves with the text area, frame by frame, its
    // top edge where it was: the window at rest around the result, less what the text still has to grow.
    private var growth: (id: UUID, final: CGFloat)?
    private func follow(_ height: CGFloat, final: CGFloat) {
        guard let window, let morph = state.morph else { return }
        let width = window.contentLayoutRect.width
        if growth?.id != morph.id {
            state.measuringResult = true
            growth = (morph.id, fittingHeight(width: width))
            state.measuringResult = false
        }
        guard let whole = growth?.final else { return }
        let content = whole - (final - height)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: width, height: content)))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        guard abs(frame.height - window.frame.height) > 0.5 else { return }
        window.contentMinSize = NSSize(width: Self.minimumWidth, height: min(content, window.contentMinSize.height))
        window.setFrame(frame, display: true)
    }
    func fittingHeight(width: CGFloat) -> CGFloat {
        state.width = width
        let measure = NSHostingController(rootView: SelectionVoiceEditReviewView(state: state))
        return ceil(measure.sizeThatFits(in: CGSize(width: width, height: 10_000)).height)
    }
    override func layout() {
        if state.width != bounds.width { state.width = bounds.width }
        super.layout()
        // Laid out in a window on screen: an arrival waiting to be seen starts now.
        if window?.isVisible == true, state.morph?.start == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.isVisible == true else { return }
                self.state.startMorph()
            }
        }
    }

    // Keys reach the review whatever has focus inside it, while its panel is key.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for monitor in [keyMonitor, outsideMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        keyMonitor = nil
        outsideMonitor = nil
        state.window = window
        visibleObserver.map(NotificationCenter.default.removeObserver)
        visibleObserver = nil
        guard let window else { return }
        // On screen at last: an arrival waiting to be seen starts.
        visibleObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true else { return }
                self.state.startMorph()
            }
        }
        // A click in another app or on the desktop dismisses it; its own clicks never reach here.
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true else { return }
                self.state.clickedOutside()
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.window?.isKeyWindow == true else { return event }
            return self.handle(event) ? nil : event
        }
    }

    // ↩ replaces (or sends a change being typed); ⌘↩ opens Change…; ⌘R tries
    // again; ⌘Z steps back a version; ⌘C copies the whole result unless some of
    // it is selected; Esc steps back one level; any other typing starts a change.
    @discardableResult func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        let returnKey = [36, 76].contains(event.keyCode)
        // While an input method is composing (Pinyin, Kana, Hangul, a dead key),
        // every key but a ⌘ shortcut is its own: ↩ commits and Esc cancels the
        // composition, never the review.
        if !flags.contains(.command), Self.composing(window?.firstResponder) { return false }
        if event.keyCode == 53, flags.isEmpty {
            state.escape()
            return true
        }
        if returnKey, flags == .command {
            // In a change being typed, ⌘↩ replaces with the text as it is.
            if state.changing { state.accept() } else { state.openChange() }
            return true
        }
        // ↩ typed right behind keys the field hasn't had yet waits for them,
        // so it sends what was typed rather than acting on the empty field.
        if returnKey, flags.isEmpty || flags == .shift, state.changing, !state.fieldReady, !state.pendingKeys.isEmpty {
            state.pendingKeys.append(event)
            state.attachField()
            return true
        }
        if returnKey, flags.isEmpty || flags == .shift {
            if state.changing {
                state.send()
            } else {
                state.primary()
            }
            return true
        }
        // ⇧⌘D shows or hides the changes.
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "d" {
            state.toggleShowsChanges()
            return true
        }
        if flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "r" where !state.changing:
                state.tryAgain()
                return true
            case "z" where !state.changing:
                state.undo()
                return true
            case "c":
                if let text = window?.firstResponder as? NSTextView, text.selectedRange().length > 0 { return false }
                state.copy()
                return true
            default: return false
            }
        }
        guard Self.typing(event, flags: flags) else { return false }
        // Once the field has focus it takes typing itself, through its input method.
        if state.changing, state.fieldReady { return false }
        // Typing starts a change with no click. Keys typed before the field has
        // focus are kept as keys, in order, and handed to it once it does, so an
        // input method or a dead key composes them as it would in the field.
        if !state.changing {
            guard state.canChange else { return false }
            state.openChange()
        }
        state.pendingKeys.append(event)
        // The field may already have focus (a change reopened within one frame).
        state.attachField()
        return true
    }

    // A key that types: no ⌘ or ⌃, and not a control, arrow or function key.
    // Dead keys and ⌥ letters count, though they have no characters yet.
    static func typing(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.isDisjoint(with: [.command, .control]),
            let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first
        else { return false }
        return !CharacterSet.controlCharacters.contains(scalar) && scalar.value < 0xF700
    }
    static func composing(_ responder: NSResponder?) -> Bool {
        (responder as? NSTextInputClient)?.hasMarkedText() == true
    }

    func invalidate() { state.invalidated = true }
    deinit {
        for monitor in [keyMonitor, outsideMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
    }
}

@MainActor final class SelectionVoiceEditReviewState: ObservableObject {
    @Published var content: SelectionVoiceEditReview.Content {
        didSet { if content != oldValue { refreshSegments() } }
    }
    @Published var draft = ""
    @Published var changing = false
    // The change field has focus and takes typing itself.
    var fieldReady = false
    // Keys typed before the field had focus, handed to it once it has.
    var pendingKeys: [NSEvent] = []
    weak var window: NSWindow?
    @Published var invalidated = false
    #if YULLO_TESTING
        // Whether each named control was drawn enabled, as SwiftUI drew it.
        var drawn: [String: Bool] = [:]
    #endif
    @Published var copied = false
    @Published var width = SelectionVoiceEditReview.width
    // The size the text is set at, for its length.
    @Published var readingSize: CGFloat?
    // The tallest the text gets before it scrolls.
    @Published var textLimit: CGFloat = 320
    var actions: SelectionVoiceEditReview.Actions
    private var copiedReset: Task<Void, Never>?
    // A result arriving, shown changing from the text it came from; then it rests clean.
    struct Morph: Equatable {
        let id = UUID()
        let from: String
        let to: String
        let segments: [TextChangeMarks.Segment]
        // When the arrival began to be seen: once its window is on screen, not when it was made.
        var start: Date?
        let plan: MorphPlan
        // Both texts, built once: a long one is costly to build every frame.
        let texts: (from: Text, to: Text)
        // Where each kept word sat before, read as the earlier text is drawn.
        let positions = MorphPositions()
        // The kept words have begun moving to their new places; the earlier text is gone.
        var landed = false
        static func == (lhs: Morph, rhs: Morph) -> Bool {
            lhs.id == rhs.id && lhs.landed == rhs.landed && lhs.start == rhs.start
        }
    }
    @Published var morph: Morph?
    // Called as a change lands, or is skipped to: the window follows the text's new length.
    var morphLanded: (() -> Void)?
    // The arrival's frames.
    let ticker = MorphTicker()
    // Whether the review is on screen, so an arrival starts when it can be seen.
    var shown: () -> Bool = { false }
    // The window is still fading in; whoever shows it starts the arrival once it has.
    var fadingIn = false
    // The window is still easing to its size until then; the rest starts once it has settled.
    var settlesAt: Date?
    // A first result after the request field: no text is drawn until the window has grown to
    // hold it, so nothing shows clipped in the field's small window.
    @Published var awaitingSize = false
    // The text area's height as it changes, and where it ends: the window follows it.
    var textHeight: ((CGFloat, CGFloat) -> Void)?
    // Measuring the result at rest, as the window will end, while an arrival is still under way.
    var measuringResult = false
    #if YULLO_TESTING
        // Checks set the time into the arrival, to draw it frame by frame.
        @Published var morphClock: Double?
    #endif
    // Removed and added words, shown in place; remembered for the next review.
    static let showsChangesKey = ReviewDisplay.showsChangesKey
    @Published var showsChanges = ReviewDisplay.store.bool(forKey: showsChangesKey) {
        didSet { ReviewDisplay.store.set(showsChanges, forKey: Self.showsChangesKey) }
    }
    // The difference Show Changes shows: from the selection as it was. Nil when there is none.
    @Published private(set) var changeSegments: [TextChangeMarks.Segment]?
    // The changes view of it, built once.
    private(set) var shownText: Text?
    // The texts differ too much, or are too long, to show what changed: the review says so.
    @Published private(set) var changesTooLarge = false
    private var diffing: Task<Void, Never>?
    // A short text is compared at once; a long one away from the main thread, so the result
    // shows the moment it is written, and the changes view follows when ready.
    private func refreshSegments() {
        diffing?.cancel()
        changesTooLarge = false
        guard !content.asking, !content.unchanged, !content.edited.isEmpty, let original = content.original,
            original != content.edited
        else { return setSegments(nil) }
        let edited = content.edited
        if max(TextChangeMarks.size(original), TextChangeMarks.size(edited)) <= MorphTiming.quickDiff {
            return setSegments(TextChangeMarks.segments(original: original, revised: edited))
        }
        setSegments(nil)
        diffing = Task { [weak self] in
            let segments = await Task.detached(priority: .userInitiated) {
                TextChangeMarks.segments(original: original, revised: edited)
            }.value
            guard let self, !Task.isCancelled, self.content.edited == edited, self.content.original == original
            else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                self.setSegments(segments)
                self.changesTooLarge = segments == nil
            }
        }
    }
    private func setSegments(_ segments: [TextChangeMarks.Segment]?) {
        shownText = segments.map(SelectionVoiceEditReviewView.shown)
        changeSegments = segments
    }
    #if YULLO_TESTING
        // The actions of the buttons as drawn, so checks press what a person would.
        var renderedActions: [String: () -> Void] = [:]
    #endif

    init(content: SelectionVoiceEditReview.Content, actions: SelectionVoiceEditReview.Actions) {
        self.content = content
        self.actions = actions
        refreshSegments()
    }
    // What the view draws depends only on what it observes: the review is still
    // in use, and its content. Whether an action may still act on its lease is
    // asked when it is pressed (`current`), never read while drawing: the window
    // is not on screen yet when the view first draws, and nothing would redraw it.
    var live: Bool { !invalidated }
    var current: Bool { live && actions.isCurrent() }
    var idle: Bool { live && !content.working && !content.replacing }
    // Untouched text has nothing to replace yet: Replace appears with the first result.
    var offersReplace: Bool {
        !content.unchanged && (content.canReplace || content.replacing || content.replaceable)
    }
    var canAccept: Bool { live && content.canReplace && !content.working }
    var canChange: Bool { idle && actions.request != nil }
    var canTryAgain: Bool { idle && actions.tryAgain != nil }
    // While a change has text, ↩ sends it; Replace steps back to a plain button.
    var returnSends: Bool { changing && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // Where nothing can be replaced, Copy is the filled action and ↩ presses it.
    // On text that is still the original, there is nothing to copy or replace
    // yet: ↩ opens Change….
    var copyIsPrimary: Bool { !offersReplace && !content.unchanged }
    // ↩ does what the filled action says: Replace, Copy, or opens Change….
    func primary() {
        if offersReplace {
            accept()
        } else if content.unchanged {
            openChange()
        } else {
            copy()
        }
    }
    // The change arriving from `from`. Reduce Motion, or nothing to compare, shows the result at once.
    // `firstLook`: the text it comes from wasn't on screen before (the selection, after a request
    // field), so it rests long enough to be recognised; the window settles first. An earlier result
    // rests as long, so every change is seen.
    func beginMorph(from: String?, firstLook: Bool = true) {
        morph = nil
        guard let from, from != content.edited, !content.asking, !content.unchanged, !content.edited.isEmpty,
            !MorphTiming.reducesMotion()
        else { return }
        if max(TextChangeMarks.size(from), TextChangeMarks.size(content.edited)) > MorphTiming.wordMorphLimit {
            // Too long to glide word by word: the text it was rests, then cross-fades into the result.
            morph = Morph(
                from: from, to: content.edited, segments: [], start: nil,
                plan: MorphTiming.current.crossfade(firstLook: firstLook),
                texts: (Text(verbatim: from), Text(verbatim: content.edited)))
        } else {
            guard let segments = TextChangeMarks.segments(original: from, revised: content.edited),
                segments.contains(where: { $0.change != .kept })
            else { return }
            let plan = MorphTiming.current.plan(segments, showing: showsChanges, firstLook: firstLook)
            morph = Morph(
                from: from, to: content.edited, segments: segments, start: nil, plan: plan,
                texts: SelectionVoiceEditReviewView.morphTexts(segments, showing: plan.showing))
        }
        // On screen already: the clock starts once the text it comes from has been drawn.
        if shown() {
            DispatchQueue.main.async { [weak self] in DispatchQueue.main.async { self?.startMorph() } }
        }
    }
    // Checks that set the time themselves keep the arrival until they let it go.
    private var clockSet: Bool {
        #if YULLO_TESTING
            return morphClock != nil
        #else
            return false
        #endif
    }
    // The arrival's clock: from the moment its window is on screen, so the whole change is seen.
    func startMorph() {
        guard !fadingIn, !awaitingSize, let pending = morph, pending.start == nil else { return }
        if let settles = settlesAt, settles > Date() {
            DispatchQueue.main.asyncAfter(deadline: .now() + settles.timeIntervalSinceNow + 0.02) { [weak self] in
                self?.startMorph()
            }
            return
        }
        morph?.start = Date()
        let plan = pending.plan
        // Its own frame clock: a panel of an app in the background isn't redrawn on its own.
        ticker.run(until: { [weak self] in self?.morph?.id != pending.id })
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((plan.hold + plan.reflowStart) * 1_000_000_000))
            guard let self, self.morph?.id == pending.id, !self.clockSet else { return }
            self.land()
            try? await Task.sleep(nanoseconds: UInt64((plan.end - plan.reflowStart) * 1_000_000_000))
            guard self.morph?.id == pending.id, !self.clockSet else { return }
            self.morph = nil
        }
    }
    // The words leaving are gone: the kept words move once to their new places, the
    // window's bottom following, and the new words fade in.
    func land() {
        guard morph?.landed == false else { return }
        morph?.landed = true
        // A cross-fade's window eases to the result as it fades in: one movement, never an empty box.
        if morph?.plan.crossfade == true { morphLanded?() }
    }
    // Any press, or a new result, goes straight to the result at rest.
    func skipMorph() {
        guard morph != nil else { return }
        morph = nil
        morphLanded?()
    }
    func toggleShowsChanges() {
        guard changeSegments != nil || changesTooLarge else { return }
        skipMorph()
        withAnimation(
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.18)
        ) { showsChanges.toggle() }
        if showsChanges, let window {
            NSAccessibility.post(
                element: window, notification: .announcementRequested,
                userInfo: [.announcement: L10n.tr("Changes shown"), .priority: NSAccessibilityPriorityLevel.high])
        }
    }
    func accept() {
        skipMorph()
        guard canAccept, current else { return }
        actions.replace()
    }
    func openChange(typing: String = "") {
        skipMorph()
        guard canChange, current else { return }
        if !changing {
            draft = ""
            fieldReady = false
            pendingKeys = []
        }
        draft += typing
        changing = true
    }
    // Once the change field has focus: what was typed is in it, the caret after
    // it, and keys typed before then go through its own input handling, in order.
    // Only the field editor of a field in this window now counts; one put away a
    // moment ago can still hold it.
    @discardableResult func attachField() -> Bool {
        guard changing, !fieldReady, let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
            let field = editor.delegate as? NSView, field.window === window
        else { return false }
        if editor.string != draft {
            editor.string = draft
            editor.didChangeText()
        }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        fieldReady = true
        let keys = pendingKeys
        pendingKeys = []
        for key in keys {
            // A held-back ↩ sends the text as typed, unless an input method is still
            // composing it: then the ↩ is the input method's, as in the field.
            if [36, 76].contains(key.keyCode), !editor.hasMarkedText() {
                draft = editor.string
                send()
                break
            }
            editor.keyDown(with: key)
        }
        return true
    }
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard idle, current, let request = actions.request else { return }
        guard !text.isEmpty else {
            primary()
            return
        }
        // Before its first result, a typed request stays in its field while it runs.
        if !content.asking { draft = "" }
        changing = false
        request(text)
    }
    // Esc: out of a change being typed, else out of a running change, else close.
    // A click outside: closes like Esc, stopping a running change first; never
    // while a change is being typed.
    func clickedOutside() {
        // Before any result, an empty request field is nothing to keep.
        guard !changing || (content.asking && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        else { return }
        if content.asking {
            actions.close()
            return
        }
        if content.working, actions.stop != nil { stop() }
        actions.close()
    }
    func escape() {
        if morph != nil { return skipMorph() }
        // Before any result there is nothing to step back to: Esc closes.
        if content.asking {
            actions.close()
        } else if changing {
            changing = false
            draft = ""
            pendingKeys = []
        } else if content.working, actions.stop != nil {
            stop()
        } else {
            actions.close()
        }
    }
    func recordAgain() {
        guard idle, current else { return }
        changing = false
        actions.recordAgain?()
    }
    func undo() {
        skipMorph()
        guard idle, current, content.canUndo else { return }
        actions.undo?()
    }
    func tryAgain() {
        skipMorph()
        guard canTryAgain, current else { return }
        changing = false
        actions.tryAgain?()
    }
    func stop() {
        guard !invalidated, content.working, actions.isCurrent() else { return }
        actions.stop?()
    }
    func copy() {
        guard !invalidated, !content.working, actions.copy(content.edited) else { return }
        // Confirmed on the button, as the Yullo window confirms its copy.
        copied = true
        copiedReset?.cancel()
        copiedReset = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self?.copied = false
        }
    }
}

// The view itself, from the Yullo selection window's parts and measures: the
// brand row at 20 by 16, one pane inset 10 with 15 pt corners, the result at
// the window's text size with 5 pt line spacing, and the 12 pt action row.
// The review in its window, held to the window's top edge: while the window is still easing
// to a new size, the text starts where it will rest, never centred and cut off.
struct TopAlignedReview: View {
    let review: SelectionVoiceEditReviewView
    var body: some View { review.frame(maxHeight: .infinity, alignment: .top) }
}

struct SelectionVoiceEditReviewView: View {
    @ObservedObject var state: SelectionVoiceEditReviewState
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    // The action row alone, at its natural width: what the window must be at least as wide as.
    var actionsOnly = false

    var body: some View {
        if actionsOnly {
            if !state.content.asking { actions(state.content).fixedSize() }
        } else {
            review
        }
    }
    private var review: some View {
        let content = state.content
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack {
                    BrandMark(size: 14)
                    Text(L10n.tr("Yullo")).font(BrandTypography.wordmark(size: 12))
                }.allowsHitTesting(false)
                Spacer()
                if state.changeSegments != nil || state.changesTooLarge { showChangesButton }
            }.frame(height: 24)
                .padding(.leading, 20).padding(.trailing, 14).padding(.vertical, 16)
                .background { WindowDragRegion().accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 12) {
                if !content.asking { result(content) }
                if state.changing || content.asking {
                    change.disabled(content.working)
                        .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
                }
                status(content)
                // Before any result, only the field and what it says.
                if !content.asking { actions(content) }
            }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
                .background(PaneSurface(vertical: true)).clipShape(RoundedRectangle(cornerRadius: 15))
                .padding(.horizontal, 10).padding(.bottom, 10)
        }
        .frame(minWidth: SelectionVoiceEditReview.minimumWidth, maxWidth: .infinity, alignment: .topLeading)
        .environment(\.locale, L10n.locale)
        .background { YulloPanelBackground(cornerRadius: SelectionVoiceEditReview.cornerRadius) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: state.changing)
        .onChange(of: state.changing) { _, changing in
            if changing {
                // Opened again: the field may be reused rather than appear anew.
                focusField(tries: 150)
            } else {
                fieldFocused = false
                state.fieldReady = false
                // The field is gone: its editor lets go too, so a later change starts clean.
                if let editor = state.window?.firstResponder as? NSTextView, editor.isFieldEditor {
                    state.window?.makeFirstResponder(nil)
                }
            }
        }
    }

    // The field takes focus once it is in the window; what was typed before then
    // is already in it, and the caret goes after it. Until then keys are kept.
    private func focusField(tries: Int) {
        fieldFocused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            guard state.changing, !state.fieldReady, !state.attachField(), tries > 0 else { return }
            focusField(tries: tries - 1)
        }
    }

    // The revised text, the hero: at its own height up to a limit; past it, it scrolls.
    // The revised text in pieces: what changed from the original selection, and
    // what did not. Untouched text, or text without an original, is one piece.
    static func pieces(_ content: SelectionVoiceEditReview.Content) -> [(text: String, changed: Bool)] {
        let text = content.edited
        guard !content.unchanged, let original = content.original else { return [(text, false)] }
        var pieces: [(String, Bool)] = []
        var index = text.startIndex
        for range in TextChangeMarks.changed(original: original, revised: text) {
            if index < range.lowerBound { pieces.append((String(text[index..<range.lowerBound]), false)) }
            pieces.append((String(text[range]), true))
            index = range.upperBound
        }
        if index < text.endIndex { pieces.append((String(text[index...]), false)) }
        return pieces
    }
    // The text with its changed pieces tagged for the mark renderer; the words keep their ink.
    // Spaces inside a change are tinted only between changed words on one line.
    static func marked(_ content: SelectionVoiceEditReview.Content) -> Text {
        var parts: [Text] = []
        for piece in pieces(content) {
            guard piece.changed else {
                parts.append(Text(verbatim: piece.text))
                continue
            }
            for span in spans(piece.text) {
                let part = Text(verbatim: span.text)
                parts.append(span.space ? part.customAttribute(ChangeGap()) : part.customAttribute(ChangeMark()))
            }
        }
        return joined(parts)
    }
    // A changed piece as runs of words and of spaces, in order.
    static func spans(_ text: String) -> [(text: String, space: Bool)] {
        var result: [(text: String, space: Bool)] = []
        for character in text {
            let space = character.isWhitespace
            if let last = result.last, last.space == space {
                result[result.count - 1].text.append(character)
            } else {
                result.append((String(character), space))
            }
        }
        return result
    }

    // The words as set in the review: its size, spacing and ink.
    private func styled(_ text: Text, size: CGFloat, quiet: Bool) -> some View {
        text.font(.system(size: size)).lineSpacing(size >= 18 ? 5 : 4)
            .foregroundStyle(quiet ? .secondary : .primary)
    }
    private func marks(_ fill: Color) -> ChangeMarkRenderer {
        ChangeMarkRenderer(fill: fill, underline: contrast == .increased ? Palette.accent : nil)
    }

    // The revised text, the hero: arriving as a change from what it was, then at rest;
    // with Show Changes, the difference in place. At its own height up to a limit; past it, it scrolls.
    @ViewBuilder private func result(_ content: SelectionVoiceEditReview.Content) -> some View {
        let size = state.readingSize ?? content.textSize
        let fill = Palette.accent.opacity(colorScheme == .dark ? 0.26 : 0.16)
        let morph = reduceMotion || state.measuringResult ? nil : state.morph
        let shown = state.showsChanges ? state.changeSegments : nil
        let measured =
            morph.map {
                // A cross-fade is as tall as the text on screen: the one it was while it rests, the
                // result once it fades in, so the window grows with the change. A glide is as tall
                // as the taller of the two, never both end to end.
                $0.plan.crossfade
                    ? ($0.landed ? $0.to : $0.from)
                    : $0.plan.showing
                        ? Self.shownString($0.segments) : ($0.from.count > $0.to.count ? $0.from : $0.to)
            } ?? shown.map(Self.shownString) ?? content.edited
        let long = Self.height(of: measured, size: size, width: state.width - 56) > state.textLimit - 12
        let text = Group {
            if let morph {
                arriving(morph, size: size, fill: fill, scrolls: long)
            } else if let shown {
                // The difference is for reading: copied and replaced text is always the result.
                styled(state.shownText ?? Self.shown(shown), size: size, quiet: false).textRenderer(marks(fill))
            } else {
                styled(Text(verbatim: content.edited), size: size, quiet: content.unchanged)
                    .textSelection(.enabled)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        Group {
            if long {
                // Always from its top, even in the moment before the window has grown to it.
                ScrollView(.vertical) { text.padding(.vertical, 10) }.scrollIndicators(.automatic)
                    .defaultScrollAnchor(.top)
                    .frame(height: state.textLimit)
                    // Soft edges say there is more above or below.
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                .init(color: .black, location: 0.96), .init(color: .clear, location: 1)
                            ], startPoint: .top, endPoint: .bottom)
                    }
            } else {
                text
            }
        }
        // A changes view worked out after the result showed fades in over it.
        .id("\(content.edited)\(shown == nil ? "" : "\u{1}")").transition(reduceMotion ? .identity : .opacity)
        .opacity(content.working ? 0.7 : state.awaitingSize ? 0 : 1)
        // VoiceOver reads the result itself, never the struck words.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("Edited"))
        .accessibilityValue(content.edited)
    }

    // A change arriving: the earlier text, its leaving words fading out; then the result,
    // its kept words moving from where they were and its new words fading in.
    private func arriving(
        _ morph: SelectionVoiceEditReviewState.Morph, size: CGFloat, fill: Color, scrolls: Bool
    ) -> some View {
        let plan = morph.plan
        return MorphFrames(ticker: state.ticker) { now in
            // Until the window is on screen, and through the hold, the text rests as it was.
            let time = (clock ?? morph.start.map { now.timeIntervalSince($0) } ?? 0) - plan.hold
            let texts = morph.texts
            if plan.crossfade {
                crossfading(morph, texts: texts, time: time, size: size, fill: fill)
            } else {
                gliding(morph, texts: texts, time: time, size: size, fill: fill, scrolls: scrolls)
            }
        }
    }
    // A long text: the one it was rests, then fades out and the result fades in, both laid out
    // once, the size following the result once it starts. With Show changes on and its changes
    // ready, it fades into the changes view.
    @ViewBuilder private func crossfading(
        _ morph: SelectionVoiceEditReviewState.Morph, texts: (from: Text, to: Text), time: Double, size: CGFloat,
        fill: Color
    ) -> some View {
        // Out, then in, never both: two texts that wrap differently never show doubled.
        let out = MorphTiming.crossfadeLength * 0.4
        let into = MorphTiming.eased(time, from: out, over: MorphTiming.crossfadeLength - out)
        let leaving = styled(texts.from, size: size, quiet: false)
            .opacity(1 - MorphTiming.easedIn(time, from: 0, over: out))
        let arriving = Group {
            if state.showsChanges, let shown = state.shownText {
                styled(shown, size: size, quiet: false).textRenderer(marks(fill))
            } else {
                styled(texts.to, size: size, quiet: false)
            }
        }.opacity(into)
        // The base takes the whole width, so the text over it wraps exactly as it will rest.
        if morph.landed {
            arriving.frame(maxWidth: .infinity, alignment: .topLeading)
                .overlay(alignment: .topLeading) { leaving.fixedSize(horizontal: false, vertical: true) }.clipped()
        } else {
            leaving.frame(maxWidth: .infinity, alignment: .topLeading)
                .overlay(alignment: .topLeading) { arriving.fixedSize(horizontal: false, vertical: true) }.clipped()
        }
    }
    @ViewBuilder private func gliding(
        _ morph: SelectionVoiceEditReviewState.Morph, texts: (from: Text, to: Text), time: Double, size: CGFloat,
        fill: Color, scrolls: Bool
    ) -> some View {
        let timing = MorphTiming.current, plan = morph.plan
        // The earlier text is drawn first and says where the kept words were. Until the change
        // starts it also sets the size, so the window settles on it at rest; from then on the
        // result does, and the window's edge follows the words.
        let leaving = styled(texts.from, size: size, quiet: false)
            .textRenderer(LeavingRenderer(time: time, plan: plan, fade: timing.fade, positions: morph.positions))
        let arriving = styled(texts.to, size: size, quiet: false)
            .textRenderer(
                ArrivingRenderer(time: time, plan: plan, fade: timing.fade, positions: morph.positions, fill: fill))
        if let from = morph.positions.fromHeight, let to = morph.positions.toHeight {
            // The text area grows or shrinks on the words' spring, the window with it; no ink
            // is drawn outside it, so nothing reaches the actions below.
            let height = from + (to - from) * CGFloat(plan.move(time))
            ZStack(alignment: .topLeading) {
                leaving.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .topLeading)
                arriving.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: ceil(height), alignment: .top).clipped()
            .onChange(of: ceil(height)) { _, height in
                if !scrolls { state.textHeight?(height, ceil(to)) }
            }
        } else {
            // Before either is laid out: the earlier text sets the size, the result drawn within
            // it at the whole width, so its words land where they will rest.
            leaving.frame(maxWidth: .infinity, alignment: .topLeading).overlay(alignment: .topLeading) {
                arriving.fixedSize(horizontal: false, vertical: true)
            }.clipped()
        }
    }
    private var clock: Double? {
        #if YULLO_TESTING
            return state.morphClock
        #else
            return nil
        #endif
    }

    // The two texts of an arrival, with each word tagged: the earlier text (kept and
    // leaving words) and the result (kept and arriving words). A kept word has the same
    // place number in both, so it can move from one to the other.
    // Ending in Show Changes, the result is the changes view: removed words stay, struck
    // through, just before their replacement, set exactly as Show Changes sets them.
    static func morphTexts(_ segments: [TextChangeMarks.Segment], showing: Bool = false) -> (from: Text, to: Text) {
        var from: [Text] = [], to: [Text] = []
        var kept = 0, staying = 0
        for (index, segment) in segments.enumerated() {
            // Removed words that stay in the changes view move like kept words, with ids of their own.
            let stays =
                showing && segment.change == .removed && segment.text.contains { $0.isLetter || $0.isNumber }
                && !TextChangeMarks.onlyRecased(segments, at: index)
            for span in spans(segment.text) {
                if span.space {
                    if segment.change != .added { from.append(Text(verbatim: span.text)) }
                    if segment.change != .removed || stays { to.append(Text(verbatim: span.text)) }
                    continue
                }
                let id: Int
                switch segment.change {
                case .kept:
                    id = kept
                    kept += 1
                case .removed where stays:
                    id = MorphToken.staying + staying
                    staying += 1
                default: id = -1
                }
                let word = Text(verbatim: span.text)
                    .customAttribute(MorphToken(change: segment.change, run: segment.run, id: id))
                if segment.change != .added { from.append(word) }
                if segment.change != .removed || stays { to.append(word) }
            }
            // Struck words and their replacement sit a space apart, in the changes view alone.
            if stays, index + 1 < segments.count, segments[index + 1].change == .added,
                segment.text.last?.isWhitespace == false, segments[index + 1].text.first?.isWhitespace == false
            {
                to.append(Text(verbatim: " "))
            }
        }
        return (joined(from), joined(to))
    }
    // Pieces as one text, joined in halves, so a long text stays quick to build and to draw.
    static func joined(_ parts: ArraySlice<Text>) -> Text {
        switch parts.count {
        case 0: return Text(verbatim: "")
        case 1: return parts[parts.startIndex]
        default:
            let middle = parts.startIndex + parts.count / 2
            return Text("\(joined(parts[..<middle]))\(joined(parts[middle...]))")
        }
    }
    static func joined(_ parts: [Text]) -> Text { joined(parts[...]) }
    // Show Changes: each change as one run, its removed words struck through in quiet ink just
    // before the words that replace them, on one tint per line.
    static func shown(_ segments: [TextChangeMarks.Segment]) -> Text {
        func wordy(_ text: String) -> Bool { text.contains { $0.isLetter || $0.isNumber } }
        var parts: [Text] = []
        for (index, segment) in segments.enumerated() {
            switch segment.change {
            case .kept:
                parts.append(Text(verbatim: segment.text))
            case .removed:
                // Punctuation or spacing alone that left isn't worth a strike, nor a change of
                // capitals or apostrophes; the result shows them.
                guard wordy(segment.text), !TextChangeMarks.onlyRecased(segments, at: index) else { continue }
                var piece = segment.text
                // Struck words and their replacement sit a space apart.
                if index + 1 < segments.count, segments[index + 1].change == .added,
                    piece.last?.isWhitespace == false, segments[index + 1].text.first?.isWhitespace == false
                {
                    piece += " "
                }
                // Only the words are struck; the spaces between them stay clear.
                for span in spans(piece) {
                    let part = Text(verbatim: span.text).foregroundStyle(.secondary)
                    parts.append(span.space ? part : part.strikethrough(color: .secondary))
                }
            case .added:
                // The tint runs from the first word to the last; punctuation alone is never marked.
                for span in spans(segment.text) {
                    let part = Text(verbatim: span.text)
                    parts.append(
                        span.space || !wordy(span.text)
                            ? part.customAttribute(ChangeGap()) : part.customAttribute(ChangeMark()))
                }
            }
        }
        return joined(parts)
    }
    static func shownString(_ segments: [TextChangeMarks.Segment]) -> String {
        segments.map(\.text).joined(separator: " ")
    }
    // The result with what changed from `original` tagged for the mark renderer.
    static func marked(_ text: String, against original: String) -> Text {
        var content = SelectionVoiceEditReview.Content(edited: text, message: "", canReplace: false, replacing: false)
        content.original = original
        return marked(content)
    }

    // Show Changes: removed words struck through before the tinted words that replace them.
    private var showChangesButton: some View {
        let on = state.showsChanges
        return Button(action: state.toggleShowsChanges) {
            Image(systemName: "strikethrough").font(.system(size: 13))
                .frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(on ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.secondary))
        .help(L10n.tr(on ? "Hide Changes" : "Show Changes") + " ⇧⌘D")
        .accessibilityLabel(L10n.tr("Show Changes"))
        .accessibilityValue(L10n.tr(on ? "On" : "Off"))
        .renderedAction("Show Changes", state.toggleShowsChanges, state)
    }

    // Change…: a field under the result, the way the Yullo window takes text,
    // with its mic. ↩ sends it; Esc puts it away.
    private var change: some View {
        // Before any change, the prompt just says what the field is for.
        let prompt =
            state.content.unchanged || state.content.asking
            ? L10n.tr("Type a change")
            : state.content.voiceKey.map { L10n.format("Describe a change, or press %@ to say it", $0) }
                ?? L10n.tr("Describe a change")
        // A place to type: one line on a quiet rounded fill, the mic, and once
        // there is text, the send button that ↩ presses.
        return HStack(spacing: 4) {
            TextField(prompt, text: $state.draft).textFieldStyle(.plain).font(.system(size: 13))
                .focused($fieldFocused).accessibilityLabel(L10n.tr("Describe a change"))
                .onAppear { focusField(tries: 150) }
            if state.actions.recordAgain != nil {
                Button(action: state.recordAgain) {
                    Image(systemName: "mic").font(.system(size: 12)).frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L10n.tr("Say another change")).accessibilityLabel(L10n.tr("Say another change"))
            }
            if state.returnSends {
                Button(action: state.send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 17))
                        .foregroundStyle(Palette.button).frame(width: 24, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).help(L10n.tr("Send") + " ↩").accessibilityLabel(L10n.tr("Send"))
                    .transition(.opacity)
            }
        }.padding(.leading, 10).padding(.trailing, 4).frame(height: 32)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: state.returnSends)
    }

    @ViewBuilder private func status(_ content: SelectionVoiceEditReview.Content) -> some View {
        if content.working {
            // The change in progress, and a quiet way to stop just it.
            HStack(spacing: 14) {
                Text(L10n.tr("Editing…")).foregroundStyle(.secondary)
                if state.actions.stop != nil {
                    Button(L10n.tr("Stop"), action: state.stop).buttonStyle(.plain)
                        .foregroundStyle(.secondary).fixedSize()
                        .help(L10n.tr("Stop this change")).accessibilityLabel(L10n.tr("Stop this change"))
                }
            }.font(.system(size: 12)).accessibilityIdentifier("voice-edit-status")
        } else if state.showsChanges, state.changesTooLarge {
            // Changes shown, but too many to show: said quietly, the result as it is.
            Text(L10n.tr("Too many changes to show.")).font(.system(size: 12)).foregroundStyle(.secondary)
        } else if !content.message.isEmpty {
            // A blocker and its one fix share a line: the reason, then the button that clears it.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(content.message).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("voice-edit-status")
                if let fix = state.actions.fix {
                    Button(fix.title) { if state.current { fix.run() } }.buttonStyle(.plain).fixedSize()
                        .disabled(!state.live).accessibilityIdentifier("voice-edit-fix")
                }
            }.font(.system(size: 12))
        }
    }

    // One row says what each action does and its key, quiet beside the one
    // filled action: Undo and Try again lead; Change…, Copy and Replace trail.
    private func actions(_ content: SelectionVoiceEditReview.Content) -> some View {
        HStack(spacing: 14) {
            if content.canUndo {
                Button(action: state.undo) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 12)).frame(width: 22, height: 28)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!state.idle)
                    .help(L10n.tr("Undo") + " ⌘Z")
                    .accessibilityLabel(L10n.tr("Undo the last change"))
                    .transition(.opacity)
            }
            if state.actions.tryAgain != nil {
                Button(action: state.tryAgain) { Self.labeled(L10n.tr("Try Again"), key: "⌘R") }
                    .buttonStyle(.plain).drawnEnabled("Try Again", state).disabled(!state.canTryAgain).fixedSize()
                    .accessibilityLabel(L10n.tr("Try Again"))
            }
            Spacer(minLength: 4)
            if state.actions.request != nil, !state.changing {
                Button {
                    state.openChange()
                } label: {
                    Self.labeled(L10n.tr("Change…"), key: "⌘↩")
                }
                .buttonStyle(.plain).drawnEnabled("Change", state).disabled(!state.canChange).fixedSize()
                .accessibilityLabel(L10n.tr("Change…"))
            }
            if state.copyIsPrimary, !state.returnSends {
                // Nothing to replace: Copy is the one filled action, and ↩ presses it.
                // While a change has text, ↩ sends it and Copy steps back to its glyph.
                Button(action: state.copy) {
                    Self.labeled(L10n.tr(state.copied ? "Copied" : "Copy"), key: "↩", prominent: true)
                }
                .buttonStyle(.borderedProminent).tint(Palette.button).fixedSize()
                .disabled(state.invalidated || content.working)
                .accessibilityLabel(L10n.tr("Copy")).renderedAction("Copy", state.copy, state)
                .accessibilityIdentifier("voice-edit-review-action")
            } else {
                Button(action: state.copy) {
                    Image(systemName: state.copied ? "checkmark" : "doc.on.doc").font(.system(size: 12))
                        .frame(width: 22, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(state.invalidated || content.working)
                    .help(L10n.tr("Copy") + " ⌘C").accessibilityLabel(L10n.tr("Copy")).renderedAction(
                        "Copy", state.copy, state)
            }
            if state.offersReplace, state.returnSends {
                // ↩ belongs to the change being typed; Replace stays one key away.
                Button(action: state.accept) { Self.labeled(L10n.tr("Replace"), key: "⌘↩") }
                    .buttonStyle(.bordered).fixedSize().drawnEnabled("Replace", state).disabled(!state.canAccept)
                    .accessibilityLabel(L10n.tr("Replace selection")).renderedAction("Replace", state.accept, state)
                    .accessibilityIdentifier("voice-edit-review-action")
            } else if state.offersReplace {
                Button(action: state.accept) {
                    Self.labeled(L10n.tr(content.replacing ? "Replacing…" : "Replace"), key: "↩", prominent: true)
                }
                .buttonStyle(.borderedProminent).tint(Palette.button).fixedSize()
                .drawnEnabled("Replace", state).disabled(!state.canAccept)
                .help(L10n.tr("Replace the selection in the original app."))
                .accessibilityLabel(L10n.tr("Replace selection")).renderedAction("Replace", state.accept, state)
                .accessibilityIdentifier("voice-edit-review-action")
            }
        }.font(.system(size: 12)).frame(height: 28)
            // Starting or ending a change swaps the buttons' state at once, never as two drawn copies.
            .animation(nil, value: content.working)
    }

    // An action's name with its key, the key a step quieter.
    static func labeled(_ title: String, key: String, prominent: Bool = false) -> some View {
        HStack(spacing: 5) {
            Text(title)
            Text(verbatim: key).foregroundStyle(
                prominent ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary)
            )
            .accessibilityHidden(true)
        }
    }

    // The result's height at its width, with the Yullo window's line spacing.
    static func height(of text: String, size: CGFloat, width: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: size), .paragraphStyle: paragraph])
        return max(ceil(size * 1.3), ceil(bounds.height) + 2)
    }
}

// What changed, word by word: the parts of the revised text that are not in the
// original, so the review can mark them without showing the original beside it.
// Whitespace alone is never marked; very long texts are left unmarked.
enum TextChangeMarks {
    static let tokenLimit = 20_000
    // Up to this many comparisons the exact table is used; past it, the edit-path search.
    static let tableLimit = 4_000_000
    // The edit-path search gives up past this many differences: too much rewritten to show.
    static let differenceLimit = 2_000
    // About how many words a text has, quickly: words between spaces, and each character of a
    // script written without them (Chinese, Japanese, Thai) as one.
    static func size(_ text: String) -> Int {
        var words = 0, inWord = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                inWord = false
            } else if scalar.value >= 0x2E80 {
                words += 1
                inWord = false
            } else if !inWord {
                words += 1
                inWord = true
            }
        }
        return words
    }

    // Longest common subsequence over tokens: the indices kept on each side.
    // The tokens kept on each side, or nil when the texts differ too much to show. Short texts
    // use the full table; long ones the shortest edit path (Myers), whose cost grows with how
    // much changed rather than with the texts' lengths multiplied.
    static func kept(_ a: [String], _ b: [String]) -> (old: Set<Int>, new: Set<Int>)? {
        #if YULLO_TESTING
            if alwaysEditPath { return editPath(a, b) }
        #endif
        return a.count * b.count <= tableLimit ? alignment(a, b) : editPath(a, b)
    }
    #if YULLO_TESTING
        // Checks compare the two ways on the same texts.
        nonisolated(unsafe) static var alwaysEditPath = false
    #endif
    // Myers' shortest edit script, keeping a snapshot of each step to walk back the path.
    static func editPath(_ a: [String], _ b: [String]) -> (old: Set<Int>, new: Set<Int>)? {
        let n = a.count, m = b.count, offset = n + m + 1
        var frontier = [Int](repeating: 0, count: 2 * offset + 1)
        var steps: [[Int]] = []
        for d in 0...min(n + m, differenceLimit) {
            // The frontier as it stood before this step, across the diagonals it can reach.
            steps.append(Array(frontier[(offset - d - 1)...(offset + d + 1)]))
            for k in stride(from: -d, through: d, by: 2) {
                var x =
                    k == -d || (k != d && frontier[offset + k - 1] < frontier[offset + k + 1])
                    ? frontier[offset + k + 1] : frontier[offset + k - 1] + 1
                var y = x - k
                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                frontier[offset + k] = x
                guard x >= n, y >= m else { continue }
                // Walk back from the end, step by step, marking each diagonal run as kept.
                var old = Set<Int>(), new = Set<Int>()
                var cx = n, cy = m
                for step in stride(from: d, through: 1, by: -1) {
                    let before = steps[step], diagonal = cx - cy
                    func at(_ k: Int) -> Int { before[k + step + 1] }
                    let down = diagonal == -step || (diagonal != step && at(diagonal - 1) < at(diagonal + 1))
                    let previous = down ? diagonal + 1 : diagonal - 1
                    let px = at(previous)
                    // This step's kept run, back to where it left the previous diagonal.
                    let start = down ? px : px + 1
                    while cx > start {
                        cx -= 1
                        cy -= 1
                        old.insert(cx)
                        new.insert(cy)
                    }
                    cx = px
                    cy = px - previous
                }
                while cx > 0, cy > 0 {
                    cx -= 1
                    cy -= 1
                    old.insert(cx)
                    new.insert(cy)
                }
                return (old, new)
            }
        }
        return nil
    }
    private static func alignment(_ a: [String], _ b: [String]) -> (old: Set<Int>, new: Set<Int>) {
        var lengths = [[UInt16]](repeating: [UInt16](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var old = Set<Int>(), new = Set<Int>()
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                old.insert(i)
                new.insert(j)
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return (old, new)
    }

    enum Change: Hashable, Sendable { case kept, removed, added }
    // A change only in capitals or apostrophes ("cant" → "Can't"): shown by its tint alone, never struck.
    static func onlyRecased(_ segments: [Segment], at index: Int) -> Bool {
        guard segments[index].change == .removed, index + 1 < segments.count, segments[index + 1].change == .added
        else { return false }
        func plain(_ text: String) -> String {
            text.lowercased().filter { $0 != "'" && $0 != "’" && !$0.isWhitespace }
        }
        return plain(segments[index].text) == plain(segments[index + 1].text)
    }
    struct Segment: Hashable, Sendable {
        var text: String
        let change: Change
        let run: Int
    }
    // The whole difference in reading order: kept text, and each change as one run, all
    // its removed words just before all the words that replace them. Spaces and
    // punctuation between two changed words belong to the change, as does punctuation
    // touching a changed word ("hallo," → "Guten Tag,"), so nothing small is left on its
    // own. Kept and removed pieces spell the original; kept and added ones the revision.
    // Nil when there is nothing to compare or the texts are too long to compare.
    static func segments(original: String, revised: String) -> [Segment]? {
        let old = tokens(original), new = tokens(revised)
        guard !old.isEmpty, !new.isEmpty, old.count <= tokenLimit, new.count <= tokenLimit else { return nil }
        let a = old.map { String(original[$0]) }, b = new.map { String(revised[$0]) }
        guard let kept = kept(a, b) else { return nil }
        // Each token as it stands on either side: kept tokens on both.
        var steps: [(old: String?, new: String?)] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, !kept.old.contains(i) {
                steps.append((a[i], nil))
                i += 1
            } else if j < b.count, !kept.new.contains(j) {
                steps.append((nil, b[j]))
                j += 1
            } else {
                steps.append((a[i], b[j]))
                i += 1
                j += 1
            }
        }
        func wordy(_ text: String?) -> Bool { text?.contains { $0.isLetter || $0.isNumber } ?? false }
        func blank(_ text: String?) -> Bool { text?.allSatisfy(\.isWhitespace) ?? true }
        // A change worth showing: anything but spacing.
        let core = steps.map { $0.old != $0.new && !(blank($0.old) && blank($0.new)) }
        var inRun = core
        // Punctuation touching a change goes with it, in either direction.
        var grew = true
        while grew {
            grew = false
            for index in steps.indices where !inRun[index] && !wordy(steps[index].new) && !blank(steps[index].new) {
                if (index > 0 && inRun[index - 1]) || (index + 1 < steps.count && inRun[index + 1]) {
                    inRun[index] = true
                    grew = true
                }
            }
        }
        // Anything without words between two changed pieces joins them.
        var last: Int?
        for index in steps.indices {
            guard inRun[index] else {
                if wordy(steps[index].old) || wordy(steps[index].new) { last = nil }
                continue
            }
            if let previous = last { for gap in previous + 1..<index { inRun[gap] = true } }
            last = index
        }
        var result: [Segment] = []
        var run = -1
        func append(_ text: String, _ change: Change) {
            guard !text.isEmpty else { return }
            if let tail = result.last, tail.change == change, tail.run == max(run, 0) || change == .kept {
                result[result.count - 1].text += text
            } else {
                result.append(Segment(text: text, change: change, run: max(run, 0)))
            }
        }
        var index = 0
        while index < steps.count {
            guard inRun[index] else {
                let step = steps[index]
                // Spacing alone that differs sits on its own side, unmarked.
                if step.old == step.new {
                    append(step.new ?? "", .kept)
                } else {
                    append(step.old ?? "", .removed)
                    append(step.new ?? "", .added)
                }
                index += 1
                continue
            }
            run += 1
            var removed = "", added = ""
            while index < steps.count, inRun[index] {
                removed += steps[index].old ?? ""
                added += steps[index].new ?? ""
                index += 1
            }
            append(removed, .removed)
            append(added, .added)
        }
        return result
    }
    static func changed(original: String, revised: String) -> [Range<String.Index>] {
        let old = tokens(original), new = tokens(revised)
        guard !old.isEmpty, !new.isEmpty, old.count <= tokenLimit, new.count <= tokenLimit else { return [] }
        guard let kept = kept(old.map { String(original[$0]) }, new.map { String(revised[$0]) })?.new else {
            return []
        }
        // Neighbouring changed words join into one mark, across the spaces between them.
        var marks: [Range<String.Index>] = []
        for (index, range) in new.enumerated() where !kept.contains(index) {
            guard !revised[range].allSatisfy(\.isWhitespace) else { continue }
            if let last = marks.last, revised[last.upperBound..<range.lowerBound].allSatisfy(\.isWhitespace) {
                marks[marks.count - 1] = last.lowerBound..<range.upperBound
            } else {
                marks.append(range)
            }
        }
        // Punctuation is marked only attached to a changed word ("Hi,"). Set apart by a space
        // (". Thanks!"), it would be a speck of its own wherever a line breaks there.
        return marks.compactMap { range in
            var chunks: [Range<String.Index>] = []
            var index = range.lowerBound
            while index < range.upperBound {
                guard !revised[index].isWhitespace else {
                    index = revised.index(after: index)
                    continue
                }
                var end = index
                while end < range.upperBound, !revised[end].isWhitespace { end = revised.index(after: end) }
                chunks.append(index..<end)
                index = end
            }
            let words = chunks.filter { revised[$0].contains { $0.isLetter || $0.isNumber } }
            guard let first = words.first, let last = words.last else { return nil }
            return first.lowerBound..<last.upperBound
        }
    }

    // Words, runs of whitespace and single punctuation marks. Scripts written
    // without spaces (Chinese, Japanese, Thai and others) are split into their
    // words, so a rewrite marks the words that changed, not the whole sentence.
    static func tokens(_ text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            var end = text.index(after: index)
            if character.isLetter || character.isNumber {
                while end < text.endIndex,
                    text[end].isLetter || text[end].isNumber || text[end] == "’" || text[end] == "'"
                {
                    end = text.index(after: end)
                }
                if text[index..<end].contains(where: unspaced) {
                    result += words(in: text, index..<end)
                    index = end
                    continue
                }
            } else if character.isWhitespace {
                while end < text.endIndex, text[end].isWhitespace { end = text.index(after: end) }
            }
            result.append(index..<end)
            index = end
        }
        return result
    }

    // A run without spaces, in its words; anything the tokenizer leaves out goes
    // by character, so the run is covered whole.
    private static func words(in text: String, _ run: Range<String.Index>) -> [Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var result: [Range<String.Index>] = []
        var index = run.lowerBound
        func characters(to end: String.Index) {
            while index < end {
                let next = text.index(after: index)
                result.append(index..<next)
                index = next
            }
        }
        tokenizer.enumerateTokens(in: run) { range, _ in
            let range = range.clamped(to: run)
            guard range.lowerBound >= index, !range.isEmpty else { return true }
            characters(to: range.lowerBound)
            result.append(range)
            index = range.upperBound
            return true
        }
        characters(to: run.upperBound)
        return result
    }

    private static func unspaced(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0E00...0x0EFF,  // Thai, Lao
                0x0F00...0x0FFF,  // Tibetan
                0x1000...0x109F,  // Myanmar
                0x1780...0x17FF,  // Khmer
                0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F,  // Japanese kana
                0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF:  // Han
                return true
            default: return false
            }
        }
    }
}

extension View {
    // Checks press a button through the action it was drawn with. Nothing in the app.
    @ViewBuilder func renderedAction(
        _ name: String, _ action: @escaping () -> Void, _ state: SelectionVoiceEditReviewState
    ) -> some View {
        #if YULLO_TESTING
            background { Color.clear.onAppear { state.renderedActions[name] = action } }
        #else
            self
        #endif
    }
    // Checks read whether a control was drawn enabled, from inside its own
    // `.disabled` scope, so they see what the person sees. Nothing in the app.
    @ViewBuilder func drawnEnabled(_ name: String, _ state: SelectionVoiceEditReviewState) -> some View {
        #if YULLO_TESTING
            modifier(DrawnEnabled(name: name, state: state))
        #else
            self
        #endif
    }
}

#if YULLO_TESTING
    private struct DrawnEnabled: ViewModifier {
        let name: String
        let state: SelectionVoiceEditReviewState
        @Environment(\.isEnabled) private var enabled
        func body(content: Content) -> some View {
            content.background {
                Color.clear.onAppear { state.drawn[name] = enabled }
                    .onChange(of: enabled) { _, value in state.drawn[name] = value }
            }
        }
    }
#endif

// How a result arrives, in Yullo's motion: it starts as the text it changes, once its window
// is on screen. Removed words fade and narrow to nothing, so the words after them slide in to
// close the gap; new words open their space, pushing their neighbours aside, and their ink
// follows a moment later on its tint. Every word that moves rides one critically damped
// spring, with no bounce, and the window's bottom edge follows the same curve. A word that
// wraps to the next or previous line leaves its old line on the short side and enters its new
// one the same way; one that would cross more lines fades out and in where it is. Then the
// tint fades and the result rests clean. A heavy rewrite fades through instead, from the
// first changed line down. With Show Changes on, it ends in the changes view: removed words
// stay, a line drawn across each as it dims, and the tint stays.
struct MorphTiming: Equatable {
    // An earlier result at rest before it changes: as long as a new one, so either is seen.
    var hold: Double
    // The selection, newly on screen, at rest long enough to be recognised before it changes.
    static let recognise = 0.4
    // Removed words fading out, one change a step after another.
    var fade: Double
    var stagger: Double
    // However many changes, the first to the last starts within this.
    var spread: Double
    // The spring every moving word rides: how long it takes to get there.
    var response: Double
    // New words' ink, a moment after their space starts to open.
    var inkDelay: Double
    var inkFade: Double
    // A heavy rewrite: the old text out, then the new one in.
    var outLength: Double
    var inLength: Double
    // Once the window has faded in, the change settles in about 0.28 s; a quicker one in about 0.22 s.
    static let balanced = MorphTiming(
        hold: 0.4, fade: 0.09, stagger: 0.02, spread: 0.04, response: 0.22, inkDelay: 0.05, inkFade: 0.1,
        outLength: 0.1, inLength: 0.15)
    static let quick = MorphTiming(
        hold: 0.4, fade: 0.09, stagger: 0.02, spread: 0.04, response: 0.17, inkDelay: 0.05, inkFade: 0.09,
        outLength: 0.1, inLength: 0.15)
    static var current = balanced
    // How long the spring takes to settle, within a hundredth.
    static var reflow: Double { current.response * 1.06 }
    static var throughOut: Double { current.outLength }
    static var throughIn: Double { current.inLength }
    static let tintFade = 0.35
    // Past this share of changed words, a rewrite fades through; so does a text this long.
    static let heavyShare = 0.5
    static let largest = 400.0
    // Up to this many words a change glides word by word; past it, the texts cross-fade.
    static let wordMorphLimit = 80
    // Up to this many words the difference is worked out at once; past it, away from the main thread.
    static let quickDiff = 200
    static let crossfadeLength = 0.28
    func crossfade(firstLook: Bool) -> MorphPlan {
        MorphPlan(
            hold: firstLook ? Self.recognise : hold, reflowStart: 0, inkStart: 0, response: response,
            fade: Self.crossfadeLength, inkFade: Self.crossfadeLength, tintStart: .infinity, end: Self.crossfadeLength,
            stagger: 0, fadeThrough: false, showing: false, crossfade: true)
    }
    // Reduce Motion, as macOS has it; checks state it.
    static var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    func stagger(runs: Int) -> Double { runs <= 1 ? 0 : min(stagger, spread / Double(runs - 1)) }
    static func heavy(_ segments: [TextChangeMarks.Segment]) -> Bool {
        func words(_ change: TextChangeMarks.Change) -> Double {
            Double(
                segments.filter { $0.change == change }.flatMap { $0.text.split(whereSeparator: \.isWhitespace) }
                    .filter { $0.contains { $0.isLetter || $0.isNumber } }.count)
        }
        let kept = words(.kept), removed = words(.removed), added = words(.added)
        // Past this many words, every word gliding is more than a frame can draw smoothly.
        if kept + max(removed, added) > largest { return true }
        return removed > heavyShare * max(kept + removed, 1) || added > heavyShare * max(kept + added, 1)
    }
    // Ending in the changes view (`showing`), the tint stays and the arrival ends as it lands.
    func plan(_ segments: [TextChangeMarks.Segment], showing: Bool = false, firstLook: Bool = true) -> MorphPlan {
        let hold = firstLook ? Self.recognise : hold
        func ending(_ landed: Double) -> (tint: Double, end: Double) {
            showing ? (.infinity, landed) : (landed, landed + Self.tintFade)
        }
        if Self.heavy(segments) {
            let landed = ending(outLength + inLength)
            return MorphPlan(
                hold: hold, reflowStart: outLength, inkStart: outLength, response: response, fade: fade,
                inkFade: inLength, tintStart: landed.tint, end: landed.end, stagger: 0, fadeThrough: true,
                showing: showing)
        }
        let runs = (segments.map(\.run).max() ?? 0) + 1
        let removes = segments.contains { $0.change == .removed }
        let step = stagger(runs: runs), spread = Double(runs - 1) * step
        // The gap starts closing while the old words are half gone.
        let reflowStart = removes ? fade * 0.5 : 0
        let inkStart = reflowStart + inkDelay
        // Landed: the spring settled, every new word's ink in, and any word moved across lines.
        let landed = ending(
            max(reflowStart + response * 1.06, inkStart + spread + inkFade, spread + fade, reflowStart + 2 * fade))
        return MorphPlan(
            hold: hold, reflowStart: reflowStart, inkStart: inkStart, response: response, fade: fade,
            inkFade: inkFade, tintStart: landed.tint, end: landed.end, stagger: step, fadeThrough: false,
            showing: showing)
    }
    // An eased 0…1 for something starting at `begin` and lasting `length`.
    static func eased(_ time: Double, from begin: Double, over length: Double, out: Bool = true) -> Double {
        let x = min(max((time - begin) / max(length, 0.001), 0), 1)
        return out ? 1 - (1 - x) * (1 - x) : x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
    }
    static func easedIn(_ time: Double, from begin: Double, over length: Double) -> Double {
        let x = min(max((time - begin) / max(length, 0.001), 0), 1)
        return x * x
    }
    // A critically damped spring from rest: no overshoot, settling within `response`.
    static func spring(_ time: Double, response: Double) -> Double {
        guard time > 0 else { return 0 }
        let omega = 2 * Double.pi / response
        return min(1, 1 - (1 + omega * time) * exp(-omega * time))
    }
    // A fade-through: the earlier text out (ease-in), then the result in (ease-out).
    static func fadingOut(_ time: Double) -> Double { 1 - easedIn(time, from: 0, over: throughOut) }
    static func fadingIn(_ time: Double) -> Double { eased(time, from: throughOut, over: throughIn) }
}

// When each phase of one arrival begins, in seconds from the end of its hold.
struct MorphPlan: Equatable {
    // The whole arrival lasts `hold + end`.
    let hold: Double
    // The spring starts: kept words begin to move.
    let reflowStart: Double
    // New words' ink begins.
    let inkStart: Double
    let response: Double
    let fade: Double
    let inkFade: Double
    let tintStart: Double
    let end: Double
    let stagger: Double
    let fadeThrough: Bool
    // It ends in the changes view: removed words stay, struck through and dimmed; the tint stays.
    let showing: Bool
    // A long text: two still texts, one fading out as the other fades in.
    var crossfade = false
}

extension MorphPlan {
    // How far the moving words have gone, 0…1, on the spring.
    func move(_ time: Double) -> Double { MorphTiming.spring(time - reflowStart, response: response) }
    // How much of a change's old words still shows, and of its new words' ink.
    func leaving(_ run: Int, at time: Double) -> Double {
        fadeThrough
            ? MorphTiming.fadingOut(time)
            : 1 - MorphTiming.eased(time, from: Double(run) * stagger, over: fade, out: false)
    }
    func arriving(_ run: Int, at time: Double) -> Double {
        fadeThrough
            ? MorphTiming.fadingIn(time)
            : MorphTiming.eased(time, from: inkStart + Double(run) * stagger, over: inkFade)
    }
    // Old words leaving a place that fades through: out from the start, quickly.
    func lineOut(_ time: Double) -> Double { 1 - MorphTiming.eased(time, from: 0, over: fade, out: false) }
    // New words coming into it, as the old ones are nearly gone (about 12% left), so the
    // place is never empty for more than a frame and never shows both.
    var lineInStart: Double { fade * 0.755 }
    var lineInLength: Double { 0.1 }
    func lineIn(_ time: Double) -> Double { MorphTiming.eased(time, from: lineInStart, over: lineInLength) }
    // When a leaving word's ink is below a tenth: nothing new is drawn over it before.
    func cleared(_ run: Int) -> Double { Double(run) * stagger + fade * 0.776 }
    var linesCleared: Double { fade * 0.776 }
    // A removed word staying in the changes view: how far its line is drawn, 0…1.
    func struck(_ run: Int, at time: Double) -> Double {
        fadeThrough
            ? MorphTiming.fadingIn(time)
            : MorphTiming.eased(time, from: Double(run) * stagger, over: fade, out: false)
    }
}

// The arrival's frame clock: ticks at the display's pace while an arrival runs, on the main
// run loop in every mode, whether or not Yullo is the app in front.
@MainActor final class MorphTicker: ObservableObject {
    @Published private(set) var now = Date()
    private var timer: Timer?
    private var done: (() -> Bool)?
    func run(until done: @escaping () -> Bool) {
        timer?.invalidate()
        self.done = done
        let timer = Timer(timeInterval: 1.0 / 90, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    private func tick() {
        if done?() ?? true {
            timer?.invalidate()
            timer = nil
            done = nil
        }
        now = Date()
    }
}
// What an arrival draws at each tick.
struct MorphFrames<Content: View>: View {
    @ObservedObject var ticker: MorphTicker
    @ViewBuilder let content: (Date) -> Content
    var body: some View { content(ticker.now) }
}

// Where each kept word was drawn in the text it came from, by its place among the kept
// words; and, once both texts are laid out, where each goes.
final class MorphPositions {
    var rects: [Int: CGRect] = [:]
    // The top of the first line in the earlier text with a word leaving.
    var firstLeaving: CGFloat?
    // When each new word's place is clear of old ink, by where it lands.
    var cleared: [String: Double] = [:]
    // How tall each text is as laid out: the text area grows or shrinks between them.
    var fromHeight: CGFloat?
    var toHeight: CGFloat?
    // Where each leaving word was, and its change: nothing new is drawn there until it has gone.
    var leaving: [(rect: CGRect, run: Int)] = []
    var schedule: MorphSchedule?
}

// The arrival's geometry: each moving word's place before and after, and the words above
// the first change, which never move or fade.
struct MorphSchedule {
    var kept: [Int: (was: CGRect, now: CGRect)] = [:]
    // The text's width: a word wrapping one line travels this far less its own short way.
    var width: CGFloat = 0
    // Lines of the result that fade through on their own: a word on them would otherwise
    // travel far or cross lines, passing over other words. Keyed by their top.
    var throughLines: Set<Int> = []
    static func lineKey(_ rect: CGRect) -> Int { Int((rect.minY / 4).rounded()) }
    func fadesThrough(_ rect: CGRect) -> Bool { throughLines.contains(Self.lineKey(rect)) }
    // A kept word that fades out where it was rather than gliding from it.
    func leavesItsPlace(_ id: Int) -> Bool {
        guard let pair = kept[id] else { return false }
        let still = abs(pair.was.minY - pair.now.minY) < 0.5 && abs(pair.was.minX - pair.now.minX) < 0.5
        return !still && (fadesThrough(pair.now) || !glides(was: pair.was, now: pair.now))
    }
    // A moving word that slides along its line a short way, or only wraps to the next or previous one.
    func glides(was: CGRect, now: CGRect) -> Bool {
        let rise = now.minY - was.minY, line = max(now.height, 1)
        if abs(rise) < line * 0.5 { return abs(now.minX - was.minX) < line * 3 }
        let along = now.minX - was.minX + width * (rise > 0 ? 1 : -1)
        return abs(rise) < line * 1.9 && abs(along) < line * 3
    }
    // A heavy rewrite fades through, from the first changed line down.
    var fadeThrough = false
    var still: Set<Int> = []
    // How strongly a kept word shows at its new place in a fade-through.
    func opacity(ofKept id: Int, at time: Double) -> Double {
        fadeThrough && !still.contains(id) ? MorphTiming.fadingIn(time) : 1
    }
    // A moving word at a moment: where it shows on its old line and on its new one, and how
    // strongly. On the same line, one place sliding on the spring. Wrapping one line, it
    // leaves its old line on the short side and enters its new one from the other. Further,
    // it fades out and in where it is.
    struct Place {
        var old: CGRect
        var oldOpacity: Double
        var new: CGRect
        var newOpacity: Double
    }
    func place(_ id: Int, at time: Double, _ plan: MorphPlan) -> Place? {
        guard let pair = kept[id] else { return nil }
        let was = pair.was, now = pair.now
        let move = plan.move(time)
        let rise = now.minY - was.minY, line = max(now.height, 1)
        let glides = !fadesThrough(now) && glides(was: was, now: now)
        if glides, abs(rise) < line * 0.5 {
            let here = was.offsetBy(dx: (now.minX - was.minX) * move, dy: rise * move)
            return Place(old: here, oldOpacity: 1, new: here, newOpacity: 1)
        }
        if glides {
            let shift = (now.width + line * 0.3) * (rise > 0 ? 1 : -1)
            return Place(
                old: was.offsetBy(dx: shift * move, dy: 0), oldOpacity: 1 - move,
                new: now.offsetBy(dx: -shift * (1 - move), dy: 0), newOpacity: move)
        }
        // Anywhere else, out where it was, then in where it goes, never both at once.
        let out = 1 - plan.lineOut(time)
        let into = plan.lineIn(time)
        if abs(rise) < line * 0.5, abs(now.minX - was.minX) < 0.5 {
            return Place(old: was, oldOpacity: 1, new: now, newOpacity: 1)
        }
        return Place(old: was, oldOpacity: 1 - out, new: now, newOpacity: into)
    }
    // A changed word rides its neighbours: it moves with the moving word before it on its
    // line, and is cut off where the one after it now begins, so its space opens and closes
    // with them and nothing overlaps.
    func riding(
        _ rect: CGRect, after previous: Int?, before next: Int?, oldLine: Bool, at time: Double, _ plan: MorphPlan
    ) -> (dx: CGFloat, limit: CGFloat) {
        if !oldLine, fadesThrough(rect) { return (0, .infinity) }
        func onLine(_ other: CGRect) -> Bool { abs(other.minY - rect.minY) < rect.height * 0.5 }
        var dx: CGFloat = 0, limit = CGFloat.infinity
        if let previous, let pair = kept[previous], let place = place(previous, at: time, plan) {
            let home = oldLine ? pair.was : pair.now, here = oldLine ? place.old : place.new
            if onLine(home) { dx = here.minX - home.minX }
        }
        if let next, let pair = kept[next], let place = place(next, at: time, plan) {
            let home = oldLine ? pair.was : pair.now, here = oldLine ? place.old : place.new
            if onLine(home) { limit = here.minX - (home.minX - rect.maxX) }
        }
        return (dx, limit)
    }
}

// A word in an arrival: kept (with its place among the kept words, the same in both
// texts), leaving or arriving, and which change it belongs to in reading order.
struct MorphToken: TextAttribute {
    let change: TextChangeMarks.Change
    let run: Int
    let id: Int
    // Removed words that stay, in the changes view, are numbered from here.
    static let staying = 1_000_000
}

// A changed word with the moving words on either side of it.
private struct ChangedWord {
    let run: Text.Layout.Run
    let token: MorphToken
    let previous: Int?
    let next: Int?
}
// Each changed word of a layout, in reading order.
private func neighbours(_ layout: Text.Layout) -> [ChangedWord] {
    var words: [(run: Text.Layout.Run, token: MorphToken)] = []
    for line in layout {
        for run in line { if let token = run[MorphToken.self] { words.append((run, token)) } }
    }
    // The moving word after each place, found in one pass from the end.
    var following = [Int?](repeating: nil, count: words.count + 1)
    for index in words.indices.reversed() {
        following[index] = words[index].token.id >= 0 ? words[index].token.id : following[index + 1]
    }
    var result: [ChangedWord] = []
    var previous: Int?
    for (index, word) in words.enumerated() {
        if word.token.id >= 0 {
            previous = word.token.id
            continue
        }
        result.append(
            ChangedWord(run: word.run, token: word.token, previous: previous, next: following[index + 1]))
    }
    return result
}
// Everything on a word's line up to `limit`: what shows of a word whose space is opening or closing.
private func upTo(_ limit: CGFloat, around rect: CGRect) -> Path {
    Path(CGRect(x: -10_000, y: rect.minY - 20, width: 10_000 + min(limit, 100_000), height: rect.height + 40))
}

// The text it came from: records where its moving words were, and draws only its leaving
// words, fading and closing up as their neighbours slide in.
struct LeavingRenderer: TextRenderer {
    let time: Double
    let plan: MorphPlan
    let fade: Double
    let positions: MorphPositions
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // Until both texts are laid out, this one is drawn whole: the very first frame is the
        // text as it was, never a mix of the two.
        let ready = positions.schedule != nil
        if !ready { for line in layout { context.draw(line) } }
        for line in layout {
            for run in line {
                guard let token = run[MorphToken.self] else { continue }
                let rect = run.typographicBounds.rect
                if token.change != .kept {
                    positions.firstLeaving = min(positions.firstLeaving ?? rect.minY, rect.minY)
                }
                // Kept words, and removed words that stay in the changes view, are drawn by the result.
                if token.id >= 0 {
                    positions.rects[token.id] = rect
                } else if positions.schedule == nil {
                    positions.leaving.append((rect, token.run))
                }
            }
            positions.fromHeight = max(positions.fromHeight ?? 0, line.typographicBounds.rect.maxY)
        }
        guard ready else { return }
        let schedule = positions.schedule
        for word in neighbours(layout) {
            let rect = word.run.typographicBounds.rect
            var piece = context
            piece.opacity = plan.leaving(word.token.run, at: time)
            if let schedule, !schedule.fadeThrough {
                let ride = schedule.riding(
                    rect, after: word.previous, before: word.next, oldLine: true, at: time, plan)
                piece.clip(to: upTo(ride.limit, around: rect))
                piece.translateBy(x: ride.dx, y: 0)
            }
            piece.draw(word.run)
        }
    }
}

// The result: moving words riding the spring to their places; each change's new words
// opening their space and fading in on one tint per line, which then fades.
struct ArrivingRenderer: TextRenderer {
    let time: Double
    let plan: MorphPlan
    let fade: Double
    let positions: MorphPositions
    let fill: Color

    // Glyph-height tint around a run of words, 2 pt either side.
    static func band(_ bounds: Text.Layout.TypographicBounds) -> CGRect {
        CGRect(
            x: bounds.rect.minX - 2, y: bounds.rect.minY + bounds.ascent * 0.08,
            width: bounds.rect.width + 4, height: bounds.ascent * 0.92 + bounds.descent + 1)
    }
    // How far a struck word dims, to about the quiet ink the changes view sets it in.
    static let dimmed = 0.45

    private func schedule(_ layout: Text.Layout) -> MorphSchedule {
        var result = MorphSchedule(fadeThrough: plan.fadeThrough)
        var firstArriving: CGFloat?
        for line in layout {
            for run in line {
                guard let token = run[MorphToken.self] else { continue }
                let rect = run.typographicBounds.rect
                if token.id >= 0, let was = positions.rects[token.id] {
                    result.kept[token.id] = (was, rect)
                } else if token.change == .added {
                    firstArriving = min(firstArriving ?? rect.minY, rect.minY)
                }
            }
        }
        result.width = result.kept.values.map { max($0.was.maxX, $0.now.maxX) }.max() ?? 0
        result.throughLines = Set(
            result.kept.values.filter { !result.glides(was: $0.was, now: $0.now) }.map {
                MorphSchedule.lineKey($0.now)
            })
        // Above the first changed line, both texts are the same, word for word and place for place.
        let firstChange = [firstArriving, positions.firstLeaving].compactMap { $0 }.min() ?? .infinity
        result.still = Set(
            result.kept.compactMap { id, pair -> Int? in
                guard id < MorphToken.staying, pair.now.midY < firstChange, abs(pair.was.minX - pair.now.minX) < 0.5,
                    abs(pair.was.minY - pair.now.minY) < 0.5
                else { return nil }
                return id
            })
        return result
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // The earlier text is drawn first and says where the moving words were; on that first
        // frame it is drawn whole, and this one only learns where its words go.
        let ready = positions.schedule != nil
        if positions.schedule == nil, !positions.rects.isEmpty { positions.schedule = schedule(layout) }
        positions.toHeight = layout.map { $0.typographicBounds.rect.maxY }.max() ?? 0
        guard ready else { return }
        let schedule = positions.schedule ?? MorphSchedule(fadeThrough: plan.fadeThrough)
        let through = schedule.fadeThrough
        let tint = 1 - MorphTiming.eased(time, from: plan.tintStart, over: MorphTiming.tintFade, out: false)
        // New words, riding their neighbours and cut off where the next word now is.
        var arriving: [(run: Text.Layout.Run, token: MorphToken, dx: CGFloat, limit: CGFloat)] = []
        for word in neighbours(layout) where word.token.change == .added {
            let ride =
                through
                ? (dx: CGFloat(0), limit: CGFloat.infinity)
                : schedule.riding(
                    word.run.typographicBounds.rect, after: word.previous, before: word.next, oldLine: false,
                    at: time, plan)
            arriving.append((word.run, word.token, ride.dx, ride.limit))
        }
        // When old ink over a place is below a tenth: leaving words, and kept words leaving it.
        // When old ink over a place is below a tenth: leaving words, and kept words leaving it.
        // Worked out once per place, so each frame stays as quick as the text is long.
        func cleared(_ place: CGRect) -> Double {
            let key = "\(Int(place.minX)) \(Int(place.minY))"
            if let known = positions.cleared[key] { return known }
            let area = place.insetBy(dx: 1, dy: 1)
            var at = 0.0
            for gone in positions.leaving where gone.rect.intersects(area) { at = max(at, plan.cleared(gone.run)) }
            for (id, pair) in schedule.kept where schedule.leavesItsPlace(id) && pair.was.intersects(area) {
                at = max(at, plan.linesCleared)
            }
            positions.cleared[key] = at
            return at
        }
        // A new word's ink: with its change, or, on a line fading through, as the old words go;
        // never over old ink still showing, and only faintly until its space has opened.
        func ink(_ word: (run: Text.Layout.Run, token: MorphToken, dx: CGFloat, limit: CGFloat)) -> Double {
            if through { return MorphTiming.fadingIn(time) }
            let full = word.run.typographicBounds.rect, place = full.offsetBy(dx: word.dx, dy: 0)
            let alone = schedule.fadesThrough(full)
            let start = max(
                alone ? plan.lineInStart : plan.inkStart + Double(word.token.run) * plan.stagger, cleared(full))
            let ink = MorphTiming.eased(time, from: start, over: alone ? plan.lineInLength : plan.inkFade)
            let open = word.limit.isInfinite ? 1 : min(max((word.limit - place.minX) / max(full.width, 1), 0), 1)
            return min(ink, open < 0.9 ? 0.3 : 0.3 + 0.7 * (open - 0.9) / 0.1)
        }
        // One tint per change on each line, from its first word to its last, as far as it has opened.
        var bands: [String: (ink: Double, rect: CGRect)] = [:]
        for word in arriving {
            var rect = Self.band(word.run.typographicBounds).offsetBy(dx: word.dx, dy: 0)
            rect.size.width = max(0, min(rect.maxX, word.limit + 2) - rect.minX)
            let key = "\(word.token.run)-\(Int(rect.minY))"
            bands[key] = (ink(word), bands[key].map { $0.rect.union(rect) } ?? rect)
        }
        for band in bands.values {
            context.fill(
                RoundedRectangle(cornerRadius: 3, style: .continuous).path(in: band.rect),
                with: .color(fill.opacity(tint * band.ink)))
        }
        for word in arriving {
            let rect = word.run.typographicBounds.rect
            var piece = context
            piece.opacity = ink(word)
            piece.clip(to: upTo(word.limit, around: rect))
            piece.translateBy(x: word.dx, y: 0)
            piece.draw(word.run)
        }
        for line in layout {
            for run in line {
                guard let token = run[MorphToken.self] else {
                    context.draw(run)
                    continue
                }
                guard token.id >= 0 else { continue }
                let now = run.typographicBounds.rect
                // A removed word staying in the changes view: struck left to right as it dims.
                let struck: Double? = token.change == .removed ? plan.struck(token.run, at: time) : nil
                var copies: [(dx: CGFloat, dy: CGFloat, opacity: Double)] = []
                if through {
                    // Faded through: the earlier text out, then the result in, never both at once;
                    // the lines above the first change stay as they are.
                    if !schedule.still.contains(token.id), let was = schedule.kept[token.id]?.was {
                        copies.append((was.minX - now.minX, was.minY - now.minY, MorphTiming.fadingOut(time)))
                    }
                    copies.append((0, 0, schedule.opacity(ofKept: token.id, at: time)))
                } else if let place = schedule.place(token.id, at: time, plan) {
                    if place.old != place.new {
                        copies.append((place.old.minX - now.minX, place.old.minY - now.minY, place.oldOpacity))
                    }
                    copies.append((place.new.minX - now.minX, place.new.minY - now.minY, place.newOpacity))
                } else {
                    copies.append((0, 0, 1))
                }
                for copy in copies where copy.opacity > 0.001 {
                    var piece = context
                    piece.translateBy(x: copy.dx, y: copy.dy)
                    piece.opacity = copy.opacity
                    guard let struck else {
                        piece.draw(run)
                        continue
                    }
                    // Dimmed to the changes view's quiet ink, its line drawn across as it goes.
                    piece.opacity *= 1 - Self.dimmed * struck
                    piece.draw(run)
                    let bounds = run.typographicBounds
                    piece.fill(
                        Path(
                            CGRect(
                                x: now.minX, y: now.minY + bounds.ascent * 0.68, width: now.width * struck,
                                height: max(1, bounds.ascent * 0.06))),
                        with: .foreground)
                }
            }
        }
    }
}

// A changed piece of the revised text.
struct ChangeMark: TextAttribute {}
// The spaces between changed words: tinted only with a changed word after them on the same line.
struct ChangeGap: TextAttribute {}

// Draws each changed piece on a soft rounded tint the height of its glyphs, so
// lines keep a gap between their marks; then the text over it, in its own ink.
// With Increase Contrast, a 1 pt accent line sits under the tint.
struct ChangeMarkRenderer: TextRenderer {
    let fill: Color
    let underline: Color?
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            var pending: CGRect?
            func flush() {
                guard let rect = pending else { return }
                context.fill(RoundedRectangle(cornerRadius: 3, style: .continuous).path(in: rect), with: .color(fill))
                if let underline {
                    context.fill(
                        Path(CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1)),
                        with: .color(underline))
                }
                pending = nil
            }
            // Spaces wait for the next changed word; a line that ends on them leaves them out.
            var gap: CGRect?
            for run in line {
                let bounds = run.typographicBounds
                // From just above the tallest glyphs to just under the descenders, 2 pt either side.
                let rect = CGRect(
                    x: bounds.rect.minX - 2, y: bounds.rect.minY + bounds.ascent * 0.08,
                    width: bounds.rect.width + 4, height: bounds.ascent * 0.92 + bounds.descent + 1)
                if run[ChangeMark.self] != nil {
                    if let held = gap, let open = pending { pending = open.union(held) }
                    gap = nil
                    pending = pending.map { $0.union(rect) } ?? rect
                } else if run[ChangeGap.self] != nil, pending != nil {
                    gap = gap.map { $0.union(rect) } ?? rect
                } else {
                    gap = nil
                    flush()
                }
            }
            flush()
        }
        for line in layout { context.draw(line) }
    }
}
