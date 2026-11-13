import AppKit
import SwiftUI

// "Made to fit you": a format for each kind of app (Chat, Mail, Code…), over the
// apps on this Mac and the websites it covers. Adding a place, or a whole kind,
// adds ordinary rules; after that they are edited or removed as rules. Nothing
// is added by itself.
struct InstalledOutputSuggestion: Identifiable, Equatable {
    let suggestion: CoreOutputSuggestion
    let place: CoreOutputPlace
    let name: String
    var id: String { suggestion.id }
}

struct OutputSuggestionGroup: Identifiable, Equatable {
    let kind: CoreOutputKind
    let items: [InstalledOutputSuggestion]
    var id: String { kind.rawValue }

    var title: String {
        switch kind {
        case .chat: return L10n.tr("Chat")
        case .workChat: return L10n.tr("Work chat")
        case .mail: return L10n.tr("Mail")
        case .notes: return L10n.tr("Notes")
        case .writing: return L10n.tr("Writing")
        case .code: return L10n.tr("Code")
        }
    }
    // The places that are not rules yet.
    func pending(_ outputs: CoreOutputSettings) -> [InstalledOutputSuggestion] {
        items.filter { outputs.rule(for: $0.place) == nil }
    }
    func isOn(_ outputs: CoreOutputSettings) -> Bool { items.allSatisfy { outputs.isOn($0.place) } }
}

extension CoreOutputSettings {
    // On adds a rule for each place (or turns on a paused one); off removes them.
    func setting(_ group: OutputSuggestionGroup, on: Bool) -> Self {
        group.items.reduce(self) { $0.setting($1.suggestion, place: $1.place, name: $1.name, on: on) }
    }
    // Settings' Add: only the places that are not rules yet; existing rows stay as they are.
    func adding(_ group: OutputSuggestionGroup) -> Self {
        group.pending(self).reduce(self) { $0.adding($1) }
    }
    // One place; a place that is already a rule stays as it is.
    func adding(_ item: InstalledOutputSuggestion) -> Self {
        rule(for: item.place) == nil ? setting(item.suggestion, place: item.place, name: item.name, on: true) : self
    }
}

@MainActor enum OutputSuggestionCatalog {
    // Generated checks inject their own apps and never look at this Mac's.
    #if YULLO_TESTING
        static var applicationURL: (String) -> URL? = { _ in nil }
    #else
        static var applicationURL: (String) -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
    #endif

    // Installed apps only; websites are always offered with their kind.
    static func installed() -> [OutputSuggestionGroup] {
        let items = CoreOutputSuggestion.all.compactMap { suggestion -> InstalledOutputSuggestion? in
            switch suggestion.place {
            case .website(let domain):
                return .init(suggestion: suggestion, place: .website(domain), name: domain)
            case .app(let name, let ids):
                for id in ids {
                    guard let url = applicationURL(id) else { continue }
                    var shown = FileManager.default.displayName(atPath: url.path)
                    if shown.hasSuffix(".app") { shown.removeLast(4) }
                    return .init(
                        suggestion: suggestion, place: .app(id.lowercased()), name: shown.isEmpty ? name : shown)
                }
                return nil
            }
        }
        return CoreOutputKind.allCases.compactMap { kind in
            let members = items.filter { $0.suggestion.kind == kind }
            return members.isEmpty ? nil : .init(kind: kind, items: members)
        }
    }
}

// Settings' "Suggestions…" sheet: each kind with its format, then its apps and
// websites one per row. Add makes one rule; Add all makes the kind's missing ones.
// A place that is already a rule shows Added, or its own format when that
// differs, so nothing is added twice.
struct OutputSuggestionsSheet: View {
    let groups: [OutputSuggestionGroup]
    @Binding var outputs: CoreOutputSettings
    let presets: CoreDictationPresetsConfiguration
    // Off only for a full-length render of the list.
    var fixedHeight = true
    let close: () -> Void
    // The list's own height: the sheet hugs it, and scrolls only past most of the screen.
    @State private var listHeight: CGFloat = 0
    private var listLimit: CGFloat { max(240, (NSScreen.main?.visibleFrame.height ?? 900) * 0.8 - 160) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("Made to fit you")).font(.system(size: 17, weight: .semibold))
                Text(L10n.tr("A format for each kind of app. Each one you add becomes your own row."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding([.horizontal, .top], 20).padding(.bottom, 16)
            if fixedHeight {
                ScrollView {
                    list.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { listHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(max(listHeight, 1), listLimit))
            } else {
                list
            }
            HStack {
                Spacer()
                Button(L10n.tr("Done"), action: close).keyboardShortcut(.defaultAction)
            }.padding(20)
        }.frame(width: 460, alignment: .top)
    }
    private var list: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(groups) { group in kind(group) }
        }.padding(.horizontal, 20).font(.system(size: 13))
    }
    private func kind(_ group: OutputSuggestionGroup) -> some View {
        let format = OutputPresentation.formatTitle(group.kind.format, presets: presets)
        let pending = group.pending(outputs)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(group.title).font(.system(size: 13, weight: .semibold))
                Text(format).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                if pending.count > 1 {
                    Button(L10n.tr("Add all")) { outputs = outputs.adding(group) }
                        .controlSize(.small)
                        .accessibilityLabel("\(group.title): \(format): \(L10n.tr("Add all"))")
                        .accessibilityIdentifier("output-suggestion-\(group.id)")
                }
            }.padding(.horizontal, 4)
            GroupBox {
                SettingsRows {
                    ForEach(group.items) { item in row(item, format: format) }
                }
            }
        }
    }
    private func row(_ item: InstalledOutputSuggestion, format: String) -> some View {
        let existing = outputs.rule(for: item.place)
        let icon: NSImage =
            switch item.place {
            case .app(let id): OutputAppChooser.icon(id)
            case .website: OutputAppChooser.websiteIcon
            }
        return SettingsTaskRow(title: item.name, icon: icon) {
            if let existing, existing.output.format == item.suggestion.format {
                Label(L10n.tr("Added"), systemImage: "checkmark").foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            } else if let existing {
                // Already the person's own choice: its format, never a second row.
                Text(OutputPresentation.formatTitle(existing.output.format, presets: presets))
                    .foregroundStyle(.secondary).lineLimit(1)
            } else {
                Button(L10n.tr("Add")) { outputs = outputs.adding(item) }
                    .accessibilityLabel("\(item.name): \(format): \(L10n.tr("Add"))")
            }
        }.accessibilityIdentifier("output-suggestion-\(item.id)")
    }
}

// "Add website…": a domain such as mail.google.com; it also covers its subdomains.
struct AddWebsiteButton: View {
    let add: (String) -> Void
    @State private var asking = false
    @State private var text = ""
    var body: some View {
        Button(L10n.tr("Add website…")) {
            text = ""
            asking = true
        }
        .accessibilityIdentifier("output-add-website")
        .alert(L10n.tr("Add website…"), isPresented: $asking) {
            TextField("mail.google.com", text: $text)
            Button(L10n.tr("Add")) { if let domain = CoreWebsite.domain(text) { add(domain) } }
                .disabled(CoreWebsite.domain(text) == nil)
            Button(L10n.tr("Cancel"), role: .cancel) {}
        }
    }
}
