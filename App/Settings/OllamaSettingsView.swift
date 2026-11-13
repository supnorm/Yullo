import AppKit
import SwiftUI

// Ollama on Services: one status line with at most one action, the model that
// writes and translates, and the address under Details. Adding a model never
// switches the one in use; it only fills an empty choice.
enum OllamaSuggestion {
    struct Model: Equatable {
        let name: String
        let size: String
    }
    static func model(memoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Model {
        let gigabytes = Double(memoryBytes) / 1_073_741_824
        if gigabytes >= 31 { return .init(name: "gemma3:12b", size: "8.1 GB") }
        if gigabytes >= 15 { return .init(name: "qwen3:8b", size: "5.2 GB") }
        return .init(name: "qwen3:4b", size: "2.5 GB")
    }
    static let website = URL(string: "https://ollama.com")!
    // Launches Ollama, then reports back as soon as it answers, or after 10 seconds.
    @MainActor static func openApp(host: String, then: @escaping @MainActor () -> Void) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: OllamaClient.bundleID) else {
            return then()
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in
            Task { @MainActor in
                for _ in 0..<20 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if case .running = await OllamaClient.shared.status(host: host) { break }
                }
                then()
            }
        }
    }
    static let library = URL(string: "https://ollama.com/search")!
}

struct OllamaSettingsView: View {
    @Binding var host: String
    @Binding var model: String
    @State private var status: OllamaClient.Status?
    @State private var adding: String?
    @State private var progress: Double?
    @State private var issue: String?
    @State private var addTask: Task<Void, Never>?
    @State private var editing = false
    // Opened from a task page's Set up…: the editor is already open.
    var startsEditing = false
    @State private var refreshCount = 0
    private let suggestion = OllamaSuggestion.model()

    private var installedNames: [String] {
        if case .running(let models) = status { return models.map(\.name) }
        return []
    }
    // Like every connection row: name, state, one button that opens its editor in place.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsTaskRow(title: "Ollama", caption: statusText) {
                Button(L10n.tr(editing ? "Done" : model.isEmpty ? "Set up…" : "Edit…")) { editing.toggle() }
                    .accessibilityIdentifier("connection-ollama")
            }
            if editing {
                statusStep
                if let adding {
                    OllamaAddProgress(name: adding, progress: progress) {
                        addTask?.cancel()
                        addTask = nil
                        self.adding = nil
                    }
                }
                if let issue {
                    Text(issue).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(
                        horizontal: false, vertical: true)
                }
                if !installedNames.isEmpty || !model.isEmpty {
                    SettingsTaskRow(title: L10n.tr("Model")) {
                        Picker(L10n.tr("Model"), selection: $model) {
                            if model.isEmpty { Text(L10n.tr("Choose a model")).tag("") }
                            if !model.isEmpty, !installedNames.contains(model) { Text(model).tag(model) }
                            ForEach(installedNames, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().pickerStyle(.menu).settingsControlWidth()
                            .accessibilityLabel(L10n.tr("Model")).accessibilityIdentifier("ollama-model")
                    }
                }
                SettingsTaskRow(title: L10n.tr("Address")) {
                    TextField(CoreOllama.defaultHost, text: $host).textFieldStyle(.roundedBorder)
                        .settingsControlWidth()
                        .autocorrectionDisabled().accessibilityLabel(L10n.tr("Address"))
                }.padding(.bottom, 6)
            }
        }.font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { if startsEditing { editing = true } }
            // Back from installing or starting Ollama: the status follows without a click.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshCount += 1
            }
            .task(id: host + "|\(refreshCount)") {
                let current = host
                let value = await OllamaClient.shared.status(host: current)
                guard !Task.isCancelled, current == host else { return }
                status = value
            }
            .onDisappear {
                addTask?.cancel()
                addTask = nil
                adding = nil
            }
    }
    private var statusText: String {
        switch status {
        case nil: return L10n.tr("Checking…")
        case .notInstalled: return L10n.tr("Not installed")
        case .notRunning: return L10n.tr("Not running")
        case .running(let models):
            return models.isEmpty
                ? L10n.tr("No models")
                : L10n.format(models.count == 1 ? "Running · %ld model" : "Running · %ld models", models.count)
        }
    }
    // The one step the current state needs, inside the editor.
    @ViewBuilder private var statusStep: some View {
        switch status {
        case .notInstalled:
            SettingsTaskRow(title: L10n.tr("Not installed")) {
                Button(L10n.tr("Get Ollama…")) { NSWorkspace.shared.open(OllamaSuggestion.website) }
            }
        case .notRunning:
            SettingsTaskRow(title: L10n.tr("Not running")) {
                Button(L10n.tr("Open Ollama"), action: openOllama)
            }
        case .running(let models) where models.isEmpty:
            SettingsTaskRow(title: L10n.format("Suggested for this Mac: %@ · %@", suggestion.name, suggestion.size)) {
                Button(L10n.tr("Other models…")) { NSWorkspace.shared.open(OllamaSuggestion.library) }
                    .buttonStyle(.link)
                Button(L10n.tr("Add")) { add(suggestion.name) }.disabled(adding != nil)
            }
        default:
            EmptyView()
        }
    }
    private func openOllama() { OllamaSuggestion.openApp(host: host) { refreshCount += 1 } }
    private func add(_ name: String) {
        guard adding == nil else { return }
        adding = name
        progress = nil
        issue = nil
        let current = host
        addTask = Task { @MainActor in
            do {
                try await OllamaClient.shared.pull(model: name, host: current) { value in
                    Task { @MainActor in if adding == name { progress = value } }
                }
                guard !Task.isCancelled, adding == name else { return }
                if model.isEmpty { model = name }
                adding = nil
                refreshCount += 1
            } catch {
                guard !Task.isCancelled, adding == name else { return }
                adding = nil
                issue = error.localizedDescription
            }
        }
    }
}

// Adding a model: progress and Cancel stay in the row that started it.
struct OllamaAddProgress: View {
    let name: String
    let progress: Double?
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let progress {
                ProgressView(value: min(1, max(0, progress))).controlSize(.small)
            } else {
                ProgressView().progressViewStyle(.linear).controlSize(.small)
            }
            HStack {
                Text(L10n.format("Adding %@…", name)).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("Cancel"), action: cancel).buttonStyle(.link).font(.system(size: 12))
            }
        }
    }
}
