import SwiftUI
import AppKit

struct ThirdPartyNotice: Identifiable {
    let id: String
    let name: String
    let license: String
    let sourceURL: URL
    let text: String?

    static func bundled(in bundle: Bundle = .main) -> [ThirdPartyNotice] {
        func read(_ name: String, directory: String) -> String? {
            guard let url = bundle.url(forResource: name, withExtension: "txt", subdirectory: directory) else {
                return nil
            }
            return try? String(contentsOf: url, encoding: .utf8)
        }
        return [
            .init(
                id: "whisper", name: "whisper.cpp", license: "MIT License",
                sourceURL: URL(string: "https://github.com/ggml-org/whisper.cpp")!,
                text: read("LICENSE-whisper.cpp", directory: "ThirdParty")),
            .init(
                id: "transcribe", name: "transcribe.cpp", license: "MIT License",
                sourceURL: URL(string: "https://github.com/handy-computer/transcribe.cpp")!,
                text: read("LICENSE-transcribe.cpp", directory: "ThirdParty")),
            .init(
                id: "llama", name: "llama.cpp", license: "MIT License",
                sourceURL: URL(string: "https://github.com/ggml-org/llama.cpp")!,
                text: read("LICENSE-llama.cpp", directory: "ThirdParty")),
            .init(
                id: "speech", name: "audio.cpp / eSpeak-ng", license: "GPL-3.0-or-later",
                sourceURL: URL(string: "https://github.com/0xShug0/audio.cpp")!,
                text: read("LICENSE-local-speech", directory: "ThirdParty")),
            .init(
                id: "sparkle", name: "Sparkle", license: "MIT License",
                sourceURL: URL(string: "https://github.com/sparkle-project/Sparkle")!,
                text: read("LICENSE-Sparkle", directory: "ThirdParty")),
            .init(
                id: "plex", name: "IBM Plex Mono", license: "SIL Open Font License 1.1",
                sourceURL: URL(string: "https://github.com/IBM/plex")!,
                text: read("LICENSE-IBMPlexMono", directory: "Fonts"))
        ]
    }
}

// Bundled license files stay byte-for-byte intact. Their Markdown container
// becomes headings and wrapped paragraphs in the reader, rather than raw syntax.
struct LicenseDocument: Equatable {
    struct Block: Equatable {
        let text: String
        let heading: Bool
    }
    let blocks: [Block]
    init(_ source: String) {
        var result: [Block] = [], paragraph: [String] = []
        func flush() {
            guard !paragraph.isEmpty else { return }
            result.append(.init(text: paragraph.joined(separator: " "), heading: false))
            paragraph.removeAll(keepingCapacity: true)
        }
        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("```") || line.hasPrefix("~~~") || ["---", "***", "___"].contains(line) {
                flush()
            } else if line.first == "#" {
                flush()
                result.append(.init(text: String(line.drop(while: { $0 == "#" || $0 == " " })), heading: true))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        blocks = result
    }
    var attributedText: NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for block in blocks {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3
            style.paragraphSpacing = block.heading ? 8 : 12
            style.paragraphSpacingBefore = block.heading && result.length > 0 ? 9 : 0
            style.lineBreakMode = .byWordWrapping
            result.append(
                NSAttributedString(
                    string: block.text + "\n",
                    attributes: [
                        .font: NSFont.systemFont(
                            ofSize: block.heading ? 14 : 12, weight: block.heading ? .semibold : .regular),
                        .foregroundColor: NSColor.labelColor, .paragraphStyle: style
                    ]))
        }
        return result
    }
}

private struct LicenseTextReader: NSViewRepresentable {
    let text: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var text: String? }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        let editor = NSTextView(frame: scroll.bounds)
        editor.isEditable = false
        editor.isSelectable = true
        editor.drawsBackground = false
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel(L10n.tr("License text"))
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.setAccessibilityLabel(L10n.tr("License text"))
        guard context.coordinator.text != text else { return }
        context.coordinator.text = text
        editor.textStorage?.setAttributedString(LicenseDocument(text).attributedText)
        editor.scrollToBeginningOfDocument(nil)
    }
}

struct ThirdPartyNoticesView: View {
    let notices: [ThirdPartyNotice]
    let close: () -> Void
    @State private var selection: String?
    init(bundle: Bundle = .main, selectedNoticeID: String? = nil, close: @escaping () -> Void) {
        notices = ThirdPartyNotice.bundled(in: bundle)
        self.close = close
        _selection = State(initialValue: selectedNoticeID)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                if selection != nil {
                    Button {
                        selection = nil
                    } label: {
                        Image(systemName: "chevron.left").frame(width: 24, height: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(L10n.tr("Back"))
                }
                Text(L10n.tr("Open-source licenses")).font(.system(size: 22, weight: .semibold))
            }
            if let notice = notices.first(where: { $0.id == selection }) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(notice.name).font(.system(size: 15, weight: .semibold))
                        Text(notice.license).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Link(L10n.tr("Project source"), destination: notice.sourceURL).font(.system(size: 12))
                }
                LicenseTextReader(text: notice.text ?? L10n.tr("License text is unavailable."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("third-party-notice-" + notice.id)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(notices) { notice in
                            Button {
                                selection = notice.id
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(notice.name).font(.system(size: 14, weight: .medium))
                                        Text(notice.license).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 12)
                                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }.padding(.horizontal, 12).padding(.vertical, 10).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("license-component-" + notice.id)
                            if notice.id != notices.last?.id { Divider().padding(.horizontal, 12) }
                        }
                    }.settingsCard()
                        .padding(.trailing, 12)
                }.scrollIndicators(.visible).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Spacer()
                Button(L10n.tr("Done"), action: close).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("third-party-notices-done")
            }
        }.padding(24)
            .frame(minWidth: 460, idealWidth: 580, maxWidth: 700, minHeight: 320, idealHeight: 440, maxHeight: 650)
            .environment(\.locale, L10n.locale)
            .accessibilityIdentifier("third-party-notices-sheet")
    }
}

#if YULLO_TESTING
    extension ThirdPartyNoticesView {
        @MainActor static func testReader(text: String) -> (view: NSView, update: @MainActor (String) -> Void) {
            let host = NSHostingView(rootView: LicenseTextReader(text: text))
            host.sizingOptions = []
            return (host, { host.rootView = LicenseTextReader(text: $0) })
        }
    }
#endif
