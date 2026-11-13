import AppKit
import SwiftUI

// Scenario mode's one small window. Describing proposes a temporary preset with
// the same local parser as Describe a preset; the owner starts, saves or ends it.
struct ScenarioPanelActions {
    var start: (String) -> Bool
    var end: () -> Void
    // Returns a failure message, or nil when the copy was saved.
    var save: () -> String?
    // Opens output settings; receives the description typed so far.
    var openOutput: (String) -> Void
    var close: () -> Void
}

struct ScenarioPanelView: View {
    @ObservedObject var model: Model
    let actions: ScenarioPanelActions
    var shortcutLabel: String?
    // A description kept from before a detour to Settings.
    var initialText = ""
    @State private var text = ""
    @State private var saved = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var proposal: CorePresetProposal? { PresetDescribing.localProposal(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let scenario = model.scenario {
                active(scenario)
            } else {
                describe
            }
        }
        .font(.system(size: 13)).padding(20).frame(width: 420, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background { YulloGlassBackground(role: .panel).ignoresSafeArea() }
    }

    @ViewBuilder private var describe: some View {
        Text(L10n.tr("Temporary format")).font(.system(size: 17, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
        TextField(
            L10n.tr("For example: replying to my landlord in German, polite"),
            text: Binding(
                get: { text },
                set: {
                    text = String($0.prefix(CorePresetDescription.maximumCharacters))
                    error = nil
                }), axis: .vertical
        ).lineLimit(2...4).textFieldStyle(.roundedBorder).focused($focused)
            .accessibilityLabel(L10n.tr("Describe the format"))
            .accessibilityIdentifier("scenario-description")
            .onSubmit(start)
            .onAppear {
                if text.isEmpty { text = String(initialText.prefix(CorePresetDescription.maximumCharacters)) }
                focused = true
            }
        if let proposal {
            Text(summary(proposal.name, proposal.definition)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("scenario-proposal")
        } else {
            Text(L10n.tr("Used until you end it. Not saved."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        outputNotice
        if let error { Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        HStack(spacing: 10) {
            Spacer()
            Button(L10n.tr("Cancel"), action: actions.close).keyboardShortcut(.cancelAction)
            Button(L10n.tr("Start"), action: start).keyboardShortcut(.defaultAction)
                .disabled(proposal == nil).accessibilityIdentifier("scenario-start")
        }
    }

    @ViewBuilder private func active(_ scenario: DictationScenario) -> some View {
        Text(scenario.title).font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
            .fixedSize(horizontal: false, vertical: true)
        Text(summary(nil, scenario.record.definition)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if let shortcutLabel {
            Text(L10n.format("Press %@ again to end it.", shortcutLabel)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        outputNotice
        if saved {
            Text(L10n.tr("Saved to your formats.")).foregroundStyle(.secondary).accessibilityIdentifier(
                "scenario-saved")
        }
        if let error { Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        HStack(spacing: 10) {
            Button(L10n.tr("Save as format")) {
                error = actions.save()
                saved = error == nil
            }.disabled(saved).accessibilityIdentifier("scenario-save")
            Spacer()
            Button(L10n.tr("End"), action: actions.end).accessibilityIdentifier("scenario-end")
            Button(L10n.tr("Done"), action: actions.close).keyboardShortcut(.defaultAction)
        }
    }

    // Translation and refinement stay a separate permission; a scenario never turns them on.
    @ViewBuilder private var outputNotice: some View {
        if !model.preferences.voiceTranslateEnabled {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.tr("Dictation translation and refinement are off."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L10n.tr("Output settings…")) { actions.openOutput(text) }.buttonStyle(.link)
            }.font(.system(size: 12))
        }
    }

    private func summary(_ name: String?, _ definition: CoreDictationPresetDefinition) -> String {
        var parts = [DictationPresetPresentation.summary(definition, localizedLanguageNames: true)]
        if let name, !name.isEmpty { parts.insert(name, at: 0) }
        if let instructions = CorePresetInstructions.normalized(definition.instructions) {
            parts.append("“" + instructions + "”")
        }
        return parts.joined(separator: " · ")
    }

    private func start() {
        guard proposal != nil else { return }
        if !actions.start(text) { error = L10n.tr("Couldn’t make a temporary format from this description.") }
    }
}

@MainActor final class ScenarioPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    var isVisible: Bool { panel?.isVisible == true }

    func present(model: Model, description: String = "", actions: ScenarioPanelActions, shortcutLabel: String?) {
        let window: NSPanel
        if let panel {
            window = panel
        } else {
            window = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 200), styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.hidesOnDeactivate = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.delegate = self
            panel = window
        }
        GlassWindowChrome.apply(window)
        window.title = L10n.tr("Temporary format")
        let host = ThemeHostingView(
            rootView: ScenarioPanelView(
                model: model, actions: actions, shortcutLabel: shortcutLabel, initialText: description),
            theme: model.preferences.appearance, inheritedAppearance: window.effectiveAppearance)
        window.contentView = host
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() { panel?.close() }

    func windowWillClose(_ notification: Notification) {
        panel?.contentView = nil
    }
}
