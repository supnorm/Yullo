import AppKit
import SwiftUI

// The viewport owns layout; its document never asks SwiftUI to measure the
// entire translation. Export authority remains with the current Model state.
@MainActor struct TranslationOutputViewport: NSViewRepresentable {
    @ObservedObject var model: Model
    let size: Double
    var color: Color = .primary
    var topInset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> TranslationOutputScrollView { TranslationOutputScrollView() }

    func updateNSView(_ view: TranslationOutputScrollView, context: Context) {
        let body = model.displayedTranslation
        let source = model.source, from = model.sourceLanguage, target = model.targetLanguage
        let selection = model.selectionContext, revision = model.selectionRevision
        let stale = model.outputIsStale && model.processingTranslationDraft.isEmpty
        let pending = model.isTranslationPending || model.refiningTranslation
        let status =
            model.refiningTranslation
            ? L10n.tr("Refining")
            : pending ? L10n.tr("Updating translation") : stale ? L10n.tr("Previous translation") : ""
        view.reader.mayExport = { [weak model, weak reader = view.reader] in
            guard let model, let reader, model.canUseOutput,
                model.selectionContext == selection, model.selectionRevision == revision,
                model.sourceLanguage == from, model.targetLanguage == target,
                TextMutationRange.identical(model.source, source),
                TextMutationRange.identical(model.output, body), TextMutationRange.identical(reader.string, body)
            else { return false }
            return true
        }
        view.configure(
            text: body, size: size, bold: model.preferences.textBold, color: color.opacity(stale ? 0.62 : 1),
            topInset: topInset,
            pending: pending, selectable: model.canUseOutput, status: status, reduceMotion: reduceMotion,
            colorScheme: colorScheme, accessibilityTitle: L10n.tr(model.outputTitleKey))
    }

    static func dismantleNSView(_ view: TranslationOutputScrollView, coordinator: ()) { view.invalidate() }
}

@MainActor final class TranslationOutputTextView: NSTextView {
    private var active = true
    var mayExport: () -> Bool = { false }
    var semanticText = ""
    override func accessibilityValue() -> String? { semanticText }
    override func accessibilityNumberOfCharacters() -> Int { semanticText.utf16.count }
    override func accessibilityString(for range: NSRange) -> String? {
        guard let value = TextMutationRange.validated(range, in: semanticText) else { return nil }
        return String(semanticText[value])
    }
    var pasteboard: () -> NSPasteboard = { .general }
    var writeText: (String, NSPasteboard) -> Bool = { text, board in
        board.clearContents()
        return board.setString(text, forType: .string)
    }
    #if YULLO_TESTING
        var testShareAction: (() -> Void)?
    #endif

    var canExport: Bool { active && mayExport() }
    override func copy(_ sender: Any?) {
        guard canExport else { return }
        _ = writeSelection(to: pasteboard(), types: [.string])
    }
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { canExport ? [.string] : [] }
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [] }
    override func writeSelection(to board: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard canExport, type == .string, let range = TextMutationRange.validated(selectedRange(), in: string),
            !range.isEmpty
        else { return false }
        return writeText(String(string[range]), board)
    }
    override func writeSelection(to board: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard types.contains(.string) else { return false }
        return writeSelection(to: board, type: .string)
    }
    override func readSelection(from board: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool { false }
    override func readSelection(from board: NSPasteboard) -> Bool { false }
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        canExport && sendType == .string && returnType == nil ? self : nil
    }
    override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool) -> Bool {
        guard canExport else { return false }
        return super.dragSelection(with: event, offset: mouseOffset, slideBack: slideBack)
    }
    override func orderFrontSharingServicePicker(_ sender: Any?) {
        guard canExport else { return }
        #if YULLO_TESTING
            if let action = testShareAction {
                action()
                return
            }
        #endif
        super.orderFrontSharingServicePicker(sender)
    }
    // Read aloud stays with Yullo's selected voice/service and cancellation
    // owner. Native Speech would introduce an independent playback task.
    override func startSpeaking(_ sender: Any?) {}
    override func stopSpeaking(_ sender: Any?) {}
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSTextView.startSpeaking(_:))
            || item.action == #selector(NSTextView.stopSpeaking(_:))
        {
            return false
        }
        if item.action == #selector(NSTextView.orderFrontSharingServicePicker(_:)) { return canExport }
        if item.action == #selector(NSText.copy(_:)) { return canExport && selectedRange().length > 0 }
        return super.validateUserInterfaceItem(item)
    }
    func invalidate() {
        active = false
        mayExport = { false }
        isSelectable = false
        writeText = { _, _ in false }
        pasteboard = { .general }
        #if YULLO_TESTING
            testShareAction = nil
        #endif
        semanticText = ""
        string = ""
    }
}

// A window that may grow so a finished translation shows without scrolling.
@MainActor protocol TextRevealingWindow: AnyObject {
    var growsToFitText: Bool { get }
    func reveal(overflow: CGFloat)
}

@MainActor final class TranslationOutputScrollView: NSScrollView {
    let reader = TranslationOutputTextView(usingTextLayoutManager: false)
    private var dotAnimation: Task<Void, Never>?
    private var dotRange: NSRange?
    private var dotColor = NSColor.secondaryLabelColor
    private var dotPhase = 0
    private var dotsReduceMotion = false
    private struct Configuration {
        let text: String
        let size: Double
        let bold: Bool
        let color: Color
        let topInset: CGFloat
        let pending: Bool
        let selectable: Bool
        let status: String
        let reduceMotion: Bool
        let colorScheme: ColorScheme
        let accessibilityTitle: String?
    }
    private var configuration: Configuration?
    private var renderedText = ""
    private var renderedDisplayText = ""
    private var renderedSize: Double?
    private var renderedBold = false
    private var renderedColor: Color?
    private var renderedColorScheme: ColorScheme?
    private var applying = false
    private var active = true

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        contentView.drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        reader.drawsBackground = false
        reader.isEditable = false
        reader.isSelectable = false
        reader.isRichText = false
        reader.importsGraphics = false
        reader.allowsUndo = false
        reader.writingToolsBehavior = .none
        reader.isHorizontallyResizable = false
        reader.isVerticallyResizable = true
        reader.autoresizingMask = [.width]
        reader.minSize = .zero
        reader.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        reader.textContainerInset = .zero
        reader.textContainer?.lineFragmentPadding = 0
        reader.textContainer?.widthTracksTextView = true
        reader.textContainer?.heightTracksTextView = false
        reader.layoutManager?.allowsNonContiguousLayout = true
        documentView = reader
        setAccessibilityIdentifier("translation-output-viewport")
        reader.setAccessibilityIdentifier("translation-output-text")
    }
    required init?(coder: NSCoder) { fatalError("Use init()") }

    func configure(
        text: String, size: Double, bold: Bool = false, color: Color, topInset: CGFloat, pending: Bool,
        selectable: Bool,
        status: String, reduceMotion: Bool, colorScheme: ColorScheme, accessibilityTitle: String? = nil
    ) {
        guard active else { return }
        configuration = Configuration(
            text: text, size: size, bold: bold, color: color, topInset: topInset, pending: pending,
            selectable: selectable,
            status: status, reduceMotion: reduceMotion, colorScheme: colorScheme, accessibilityTitle: accessibilityTitle
        )
        reader.isSelectable = selectable && !pending && TextMutationRange.identical(renderedText, text)
        // A newly attached NSView can still have zero width. Do not lay out a
        // long paragraph at that temporary width before the viewport is sized.
        if text.isEmpty || contentView.bounds.width > 1 { applyConfiguration() } else { needsLayout = true }
    }

    // A result that shows its top keeps showing it when the viewport resizes: when a
    // notice row takes room, AppKit would keep the text's bottom and hide its first line.
    override func tile() {
        let atTop = contentView.bounds.minY <= 0.5
        super.tile()
        guard atTop, contentView.bounds.minY > 0.5 else { return }
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
    }

    override func layout() {
        super.layout()
        if let bar = verticalScroller, bar.controlSize != .small {
            bar.controlSize = .small
            tile()
        }
        if contentView.bounds.width > 1 { applyConfiguration() }
        pinDocumentTop()
        revealFinishedText()
    }

    // The reader always starts at the clip's top. Width-only autoresizing keeps
    // its bottom margin when the viewport shrinks, which would push the first
    // line above the visible area; pin it back and keep the scroll in range.
    private func pinDocumentTop() {
        guard reader.frame.origin != .zero else { return }
        reader.setFrameOrigin(.zero)
        contentView.scroll(to: contentView.constrainBoundsRect(contentView.bounds).origin)
        reflectScrolledClipView(contentView)
    }

    // Measures the finished text only; streaming text never resizes the window.
    private func revealFinishedText() {
        guard let target = window as? TextRevealingWindow, target.growsToFitText, configuration == nil,
            !renderedText.isEmpty, dotRange == nil, contentView.bounds.width > 1,
            let manager = reader.layoutManager, let container = reader.textContainer
        else { return }
        manager.ensureLayout(for: container)
        let needed = manager.usedRect(for: container).height + reader.textContainerInset.height * 2
        target.reveal(overflow: needed - contentView.bounds.height)
    }

    private func applyConfiguration() {
        guard active, !applying, let value = configuration, let storage = reader.textStorage else { return }
        configuration = nil
        applying = true
        defer { applying = false }
        let name: NSAppearance.Name = value.colorScheme == .dark ? .darkAqua : .aqua
        if appearance?.name != name { appearance = NSAppearance(named: name) }
        if contentView.bounds.width > 1, reader.frame.width != contentView.bounds.width {
            reader.setFrameSize(
                NSSize(width: contentView.bounds.width, height: max(reader.frame.height, contentView.bounds.height)))
        }
        let font = NSFont.systemFont(ofSize: value.size, weight: value.bold ? .semibold : .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        paragraph.lineBreakMode = .byWordWrapping
        var nativeColor = NSColor(value.color)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            nativeColor = nativeColor.usingColorSpace(.deviceRGB) ?? nativeColor
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: nativeColor, .paragraphStyle: paragraph
        ]
        let metricsChanged = renderedSize != value.size || renderedBold != value.bold
        let colorChanged = renderedColor != value.color || renderedColorScheme != value.colorScheme
        // A new result starts at its top; text that only grows (streaming) keeps
        // the reader where it is.
        let origin = value.text.hasPrefix(renderedText) && !renderedText.isEmpty ? contentView.bounds.origin : .zero
        reader.textContainerInset = NSSize(width: 0, height: value.topInset)
        // Loading marks belong only to this display buffer, never to Model output.
        let separator = value.text.isEmpty || value.text.last?.isWhitespace == true ? "" : " "
        let displayText = value.text + (value.pending ? separator + "..." : "")
        let prefix = Self.sharedPrefix(renderedDisplayText, displayText)
        let previousLength = renderedDisplayText.utf16.count
        let nextLength = displayText.utf16.count
        let reset = storage.length != previousLength
        storage.beginEditing()
        // Restore former display marks in the same transaction as the new text.
        if let oldDots = dotRange, NSMaxRange(oldDots) <= storage.length {
            storage.addAttribute(.foregroundColor, value: nativeColor, range: oldDots)
        }
        if reset || prefix != previousLength || prefix != nextLength {
            if reset {
                storage.setAttributedString(NSAttributedString(string: displayText, attributes: attributes))
            } else {
                let suffix = (displayText as NSString).substring(from: prefix)
                storage.replaceCharacters(
                    in: NSRange(location: prefix, length: previousLength - prefix),
                    with: NSAttributedString(string: suffix, attributes: attributes))
            }
            if !reset, prefix > 0 {
                if metricsChanged {
                    storage.addAttributes(attributes, range: NSRange(location: 0, length: storage.length))
                } else if colorChanged {
                    storage.addAttribute(
                        .foregroundColor, value: nativeColor, range: NSRange(location: 0, length: storage.length))
                }
            }
        } else if storage.length > 0, metricsChanged || colorChanged {
            let range = NSRange(location: 0, length: storage.length)
            if metricsChanged {
                storage.addAttributes(attributes, range: range)
            } else {
                storage.addAttribute(.foregroundColor, value: nativeColor, range: range)
            }
        }
        dotRange = value.pending ? NSRange(location: nextLength - 3, length: 3) : nil
        dotColor = nativeColor
        dotsReduceMotion = value.reduceMotion
        drawLoadingDots()
        reader.semanticText = value.text
        storage.endEditing()
        renderedText = value.text
        renderedDisplayText = displayText
        renderedSize = value.size
        renderedBold = value.bold
        renderedColor = value.color
        renderedColorScheme = value.colorScheme
        reader.isSelectable = value.selectable && !value.pending
        reader.setAccessibilityLabel(
            value.status.isEmpty ? value.accessibilityTitle ?? L10n.tr("Translation") : value.status)
        reader.setAccessibilityHelp(value.status)
        if reader.frame.origin != .zero { reader.setFrameOrigin(.zero) }
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
        revealFinishedText()
        if dotRange == nil || dotsReduceMotion {
            dotAnimation?.cancel()
            dotAnimation = nil
        } else if dotAnimation == nil {
            dotAnimation = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
                    guard let view = self, view.active, view.dotRange != nil else { return }
                    if view.window?.isVisible == true && !view.isHiddenOrHasHiddenAncestor {
                        view.dotPhase = (view.dotPhase + 1) % 3
                        view.drawLoadingDots()
                    }
                }
            }
        }
    }
    private func drawLoadingDots() {
        guard let range = dotRange, let storage = reader.textStorage,
            range.location >= 0, NSMaxRange(range) <= storage.length
        else { return }
        storage.beginEditing()
        for index in 0..<3 {
            let opacity = dotsReduceMotion || index == dotPhase ? 0.85 : 0.3
            storage.addAttribute(
                .foregroundColor,
                value: dotColor.withAlphaComponent(dotColor.alphaComponent * opacity),
                range: NSRange(location: range.location + index, length: 1))
        }
        storage.endEditing()
    }
    #if YULLO_TESTING
        var testLoadingDotRange: NSRange? { dotRange }
        var testLoadingDotsAnimated: Bool { dotAnimation != nil }
        func testAdvanceLoadingDots() {
            dotPhase = (dotPhase + 1) % 3
            drawLoadingDots()
        }
    #endif

    // UTF-16 identity preserves NFC/NFD changes. The cut must also be a scalar
    // edge in both strings when different emoji share their high surrogate.
    static func sharedPrefix(_ previous: String, _ next: String) -> Int {
        let old = Array(previous.utf16), new = Array(next.utf16)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        while prefix > 0,
            TextMutationRange.validated(NSRange(location: prefix, length: old.count - prefix), in: previous) == nil
                || TextMutationRange.validated(NSRange(location: prefix, length: new.count - prefix), in: next) == nil
        { prefix -= 1 }
        return prefix
    }

    func invalidate() {
        active = false
        configuration = nil
        dotAnimation?.cancel()
        dotAnimation = nil
        dotRange = nil
        reader.invalidate()
        renderedText = ""
        renderedDisplayText = ""
    }
}
