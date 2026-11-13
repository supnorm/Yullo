import AppKit
import Combine

struct VoiceComparisonSnapshot {
    let sessionID: UUID
    let revision: UUID
    let original: String
    let current: String
    let outputTitle: String
    let context: VoiceOverlayResultContext
    let message: String?
    let appearance: String
    let canRestoreOriginal: Bool
    let originalTitle: String?
    let restoreOriginalTitle: String?

    init(
        sessionID: UUID, revision: UUID, original: String, current: String, outputTitle: String,
        context: VoiceOverlayResultContext, message: String?, appearance: String = "system",
        canRestoreOriginal: Bool = false, originalTitle: String? = nil, restoreOriginalTitle: String? = nil
    ) {
        self.sessionID = sessionID
        self.revision = revision
        self.original = original
        self.current = current
        self.outputTitle = outputTitle
        self.context = context
        self.message = message
        self.appearance = appearance
        self.canRestoreOriginal = canRestoreOriginal
        self.originalTitle = originalTitle
        self.restoreOriginalTitle = restoreOriginalTitle
    }
}

@MainActor protocol VoiceComparisonPresenting: AnyObject {
    func present(_ snapshot: VoiceComparisonSnapshot, isCurrent: @escaping () -> Bool)
    func dismiss()
    func setRestoreOriginalAction(_ action: (() -> Void)?)
}
extension VoiceComparisonPresenting {
    func setRestoreOriginalAction(_ action: (() -> Void)?) {}
}

// Native modal and pasteboard effects are injected independently of the reader.
// Generated fixtures never show a window or use the general pasteboard.
@MainActor struct VoiceComparisonBackend {
    var runModal: (NSWindow) -> Void
    var modalWindow: () -> NSWindow?
    var stopModal: () -> Void
    var pasteboard: () -> NSPasteboard
    var write: (String, NSPasteboard) -> Bool

    static var system: VoiceComparisonBackend {
        VoiceComparisonBackend(
            runModal: { window in
                NSApp.activate(ignoringOtherApps: true)
                NSApp.runModal(for: window)
            },
            modalWindow: { NSApp.modalWindow }, stopModal: { NSApp.stopModal() },
            pasteboard: { .general },
            write: { text, pasteboard in
                pasteboard.clearContents()
                return pasteboard.setString(text, forType: .string)
            })
    }
}

@MainActor final class VoiceResultComparisonPresenter: NSObject, VoiceComparisonPresenting, NSWindowDelegate {
    private let backend: VoiceComparisonBackend
    private var window: NSWindow?
    private var reader: VoiceResultComparisonReader?
    private var presentationID: UUID?
    private var restoreOriginalAction: (() -> Void)?

    init(backend: VoiceComparisonBackend? = nil) { self.backend = backend ?? .system }
    func setRestoreOriginalAction(_ action: (() -> Void)?) { restoreOriginalAction = action }

    func present(_ snapshot: VoiceComparisonSnapshot, isCurrent: @escaping () -> Bool) {
        guard window == nil, isCurrent(), backend.modalWindow() == nil else { return }
        let id = UUID()
        presentationID = id
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 460),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.tr("Compare")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        GlassWindowChrome.apply(window)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentMinSize = NSSize(width: 460, height: 420)
        window.appearance = AppTheme.nativeAppearance(snapshot.appearance)
        let reader = VoiceResultComparisonReader(
            snapshot: snapshot, backend: backend,
            isCurrent: { [weak self] in self?.presentationID == id && isCurrent() },
            close: { [weak self] in
                guard self?.presentationID == id else { return }
                self?.dismiss()
            },
            restoreOriginal: { [weak self] in
                guard self?.presentationID == id, isCurrent() else { return }
                self?.restoreOriginalAction?()
            })
        self.window = window
        self.reader = reader
        window.delegate = self
        window.contentView = reader
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            window.setContentSize(
                NSSize(width: min(740, max(460, visible.width - 48)), height: min(460, max(420, visible.height - 80))))
            window.center()
        }
        defer {
            // A dismissed older modal must not clear a later reader.
            if presentationID == id { dismiss() }
        }
        guard isCurrent(), backend.modalWindow() == nil else { return }
        backend.runModal(window)
    }

    func dismiss() { finish(closeWindow: true) }

    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed === window else { return }
        finish(closeWindow: false)
    }

    private func finish(closeWindow: Bool) {
        let ownedWindow = window
        let ownedReader = reader
        presentationID = nil
        window = nil
        reader = nil
        // Invalidate both button and native selection-copy paths before ending
        // the modal loop or allowing another event to observe this surface.
        ownedReader?.invalidate()
        ownedWindow?.makeFirstResponder(nil)
        ownedWindow?.contentView = nil
        ownedWindow?.delegate = nil
        if let ownedWindow, backend.modalWindow() === ownedWindow { backend.stopModal() }
        if closeWindow { ownedWindow?.close() }
    }
}

@MainActor final class VoiceComparisonAction: NSObject {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    @objc func run(_ sender: Any?) { body() }
}

// Every native text-export path checks the same live preview lease. Keeping
// this view read-only also prevents system writing tools from changing a copy.
@MainActor final class VoiceComparisonTextView: NSTextView {
    var mayCopy: () -> Bool = { false }
    var pasteboard: () -> NSPasteboard = { .general }
    var writeText: (String, NSPasteboard) -> Bool = { _, _ in false }

    override func copy(_ sender: Any?) {
        guard mayCopy() else { return }
        _ = writeSelection(to: pasteboard(), types: [.string])
    }
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { mayCopy() ? [.string] : [] }
    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard mayCopy(), type == .string,
            let range = TextMutationRange.validated(selectedRange(), in: string), !range.isEmpty
        else { return false }
        return writeText(String(string[range]), pasteboard)
    }
    override func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard types.contains(.string) else { return false }
        return writeSelection(to: pasteboard, type: .string)
    }
    func copyAll() {
        guard mayCopy(), !string.isEmpty else { return }
        _ = writeText(string, pasteboard())
    }
    func invalidate() {
        mayCopy = { false }
        writeText = { _, _ in false }
        pasteboard = { .general }
        isSelectable = false
        string = ""
    }
}

@MainActor final class VoiceResultComparisonReader: NSView {
    let original = VoiceComparisonTextView(usingTextLayoutManager: true)
    let current = VoiceComparisonTextView(usingTextLayoutManager: true)
    let status = VoiceComparisonTextView(usingTextLayoutManager: true)
    let originalCopy = NSButton(title: L10n.tr("Copy"), target: nil, action: nil)
    let currentCopy = NSButton(title: L10n.tr("Copy"), target: nil, action: nil)
    let done = NSButton(title: L10n.tr("Done"), target: nil, action: nil)
    let restoreOriginal = NSButton(title: L10n.tr("Restore original"), target: nil, action: nil)
    private let panes = NSStackView()
    private var actions: [VoiceComparisonAction] = []
    private var payloadLabels: [NSTextField] = []
    private var statusHeight: NSLayoutConstraint?
    private var measuredStatusWidth: CGFloat = -1
    // The reader sits on the window surface and each text area on a card,
    // in both window styles.
    private let glass = YulloGlassView(role: .window)
    private var textCards: [(card: NSView, scroll: NSScrollView)] = []
    private var styleObserver: AnyCancellable?

    init(
        snapshot: VoiceComparisonSnapshot, backend: VoiceComparisonBackend,
        isCurrent: @escaping () -> Bool, close: @escaping () -> Void,
        restoreOriginal: (() -> Void)? = nil
    ) {
        super.init(frame: .zero)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        styleObserver = WindowStyleState.shared.$solid.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.styleTextAreas() }
        }
        let layout = NSStackView()
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = 16
        layout.translatesAutoresizingMaskIntoConstraints = false
        addSubview(layout)
        NSLayoutConstraint.activate([
            // Below the title bar, which glass windows draw over the content.
            layout.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 24),
            layout.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            layout.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            layout.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20)
        ])
        let headingLabel = NSTextField(labelWithString: L10n.tr("Compare"))
        headingLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        layout.addArrangedSubview(headingLabel)
        var messages: [String] = []
        if let message = snapshot.context.message, !message.isEmpty {
            let detailIncludesContext =
                snapshot.message == message || snapshot.message?.hasPrefix(message + "\n") == true
            if !detailIncludesContext { messages.append(message) }
        }
        if let message = snapshot.message, !message.isEmpty, !messages.contains(message) { messages.append(message) }
        if !messages.isEmpty {
            let scroll = makeTextScroll(
                editor: status, text: messages.joined(separator: "\n\n"), title: L10n.tr("Result status"),
                backend: backend, isCurrent: isCurrent, isStatus: true)
            layout.addArrangedSubview(scroll)
            scroll.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
            let height = scroll.heightAnchor.constraint(equalToConstant: 16)
            height.isActive = true
            statusHeight = height
        }
        panes.spacing = 16
        panes.distribution = .fillEqually
        addPane(
            text: snapshot.original, title: snapshot.originalTitle ?? L10n.tr("Original"), editor: original,
            copy: originalCopy,
            copyLabel: L10n.tr("Copy original"), backend: backend, isCurrent: isCurrent)
        addPane(
            text: snapshot.current,
            title: snapshot.outputTitle.isEmpty ? L10n.tr("Current output") : snapshot.outputTitle,
            editor: current, copy: currentCopy, copyLabel: L10n.tr("Copy result"), backend: backend,
            isCurrent: isCurrent)
        layout.addArrangedSubview(panes)
        panes.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        let footer = NSStackView()
        footer.orientation = .horizontal
        if snapshot.canRestoreOriginal, let restoreOriginal {
            self.restoreOriginal.bezelStyle = .rounded
            self.restoreOriginal.title = snapshot.restoreOriginalTitle ?? L10n.tr("Restore original")
            self.restoreOriginal.setAccessibilityLabel(self.restoreOriginal.title)
            wire(self.restoreOriginal) {
                guard isCurrent() else { return }
                restoreOriginal()
            }
            footer.addArrangedSubview(self.restoreOriginal)
        }
        footer.addArrangedSubview(NSView())
        footer.addArrangedSubview(done)
        done.bezelStyle = .rounded
        done.keyEquivalent = "\u{1b}"
        wire(done, close)
        layout.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("Use init(snapshot:backend:isCurrent:close:)") }

    override func layout() {
        let orientation: NSUserInterfaceLayoutOrientation = bounds.width >= 680 ? .horizontal : .vertical
        if panes.orientation != orientation { panes.orientation = orientation }
        panes.alignment = orientation == .horizontal ? .top : .leading
        if let statusHeight {
            let width = max(1, bounds.width - 64)
            if measuredStatusWidth != width {
                measuredStatusWidth = width
                let size = (status.string as NSString).boundingRect(
                    with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: NSFont.systemFont(ofSize: 12)]
                ).size
                // Long diagnostics remain fully scrollable without crowding
                // out either finalized text or the reader's close control.
                statusHeight.constant = min(88, max(16, ceil(size.height + 2)))
            }
        }
        super.layout()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        styleTextAreas()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        styleTextAreas()
    }
    private func styleTextAreas() {
        let solid = WindowStyleState.shared.solid
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let increased = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let fill = dark ? 0.07 + (increased ? 0.03 : 0) : (solid || increased ? 1 : 0.90)
        let rim = increased ? (dark ? 0.28 : 0.20) : solid ? 0.08 : (dark ? 0.10 : 0.07)
        for (card, scroll) in textCards {
            scroll.borderType = .noBorder
            scroll.drawsBackground = false
            card.layer?.cornerRadius = 12
            card.layer?.cornerCurve = .continuous
            card.layer?.masksToBounds = true
            card.layer?.backgroundColor = NSColor.white.withAlphaComponent(fill).cgColor
            card.layer?.borderWidth = increased ? 1 : 0.5
            card.layer?.borderColor = (dark ? NSColor.white : .black).withAlphaComponent(rim).cgColor
        }
    }
    func invalidate() {
        original.invalidate()
        current.invalidate()
        status.invalidate()
        for label in payloadLabels { label.stringValue = "" }
        originalCopy.isEnabled = false
        currentCopy.isEnabled = false
        restoreOriginal.isEnabled = false
    }

    private func addPane(
        text: String, title: String, editor: VoiceComparisonTextView, copy: NSButton, copyLabel: String,
        backend: VoiceComparisonBackend, isCurrent: @escaping () -> Bool
    ) {
        let pane = NSStackView()
        pane.orientation = .vertical
        pane.alignment = .leading
        pane.spacing = 9
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 12
        let label = NSTextField(labelWithString: title)
        payloadLabels.append(label)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        header.addArrangedSubview(label)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(copy)
        copy.bezelStyle = .rounded
        copy.isEnabled = !text.isEmpty
        copy.controlSize = .small
        copy.font = .systemFont(ofSize: 11)
        copy.setAccessibilityLabel(copyLabel)
        copy.setAccessibilityIdentifier(
            editor === original ? "voice-compare-copy-original" : "voice-compare-copy-result")
        pane.addArrangedSubview(header)
        let scroll = makeTextScroll(
            editor: editor, text: text, title: title, backend: backend, isCurrent: isCurrent)
        wire(copy) { [weak editor] in editor?.copyAll() }
        // The card the text area sits on; the scroll view itself manages its
        // own layer background.
        let card = NSView()
        card.wantsLayer = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: card.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        textCards.append((card, scroll))
        pane.addArrangedSubview(card)
        header.widthAnchor.constraint(equalTo: pane.widthAnchor).isActive = true
        card.widthAnchor.constraint(equalTo: pane.widthAnchor).isActive = true
        styleTextAreas()
        panes.addArrangedSubview(pane)
    }
    private func makeTextScroll(
        editor: VoiceComparisonTextView, text: String, title: String, backend: VoiceComparisonBackend,
        isCurrent: @escaping () -> Bool, isStatus: Bool = false
    ) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = isStatus ? .noBorder : .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.verticalScroller?.controlSize = .small
        scroll.drawsBackground = !isStatus
        scroll.backgroundColor = .textBackgroundColor
        editor.isEditable = false
        editor.isSelectable = true
        editor.isRichText = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.writingToolsBehavior = .none
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: isStatus ? 12 : 14)
        editor.textColor = isStatus ? .secondaryLabelColor : .labelColor
        editor.textContainerInset = isStatus ? .zero : NSSize(width: 10, height: 10)
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.string = text
        editor.mayCopy = isCurrent
        editor.pasteboard = backend.pasteboard
        editor.writeText = backend.write
        editor.setAccessibilityLabel(title)
        editor.setAccessibilityIdentifier(
            isStatus ? "voice-compare-status" : editor === original ? "voice-compare-original" : "voice-compare-result")
        scroll.documentView = editor
        return scroll
    }
    private func wire(_ button: NSButton, _ body: @escaping () -> Void) {
        let action = VoiceComparisonAction(body)
        actions.append(action)
        button.target = action
        button.action = #selector(VoiceComparisonAction.run(_:))
    }
}
