import SwiftUI
import AppKit

enum CLISetupCommand: String, CaseIterable, Identifiable {
    case codex, claude
    var id: String { rawValue }
    var title: String { self == .codex ? "Codex CLI" : "Claude Code" }
    // Fixed public commands only; never interpolate paths, source text, keys
    // or configuration into a shell command, clipboard action or app launch.
    // Codex signs in to a file, the only sign-in Yullo's private Codex home can
    // use; the same literal as CLIProvider.signInCommand.
    var command: String { self == .codex ? "codex login -c cli_auth_credentials_store=file" : "claude auth login" }
    // Each maker's own one-line install, as its install page gives it.
    var install: String {
        self == .codex ? "npm install -g @openai/codex" : "curl -fsSL https://claude.ai/install.sh | bash"
    }
    var guide: URL {
        URL(
            string: self == .codex
                ? "https://developers.openai.com/codex/cli/" : "https://code.claude.com/docs/en/quickstart")!
    }
}

@MainActor struct CLISetupGuideEffects {
    var copy: (String) -> Bool
    var openTerminal: () -> Bool
    static let live = CLISetupGuideEffects(
        copy: {
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString($0, forType: .string)
        },
        openTerminal: {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                return false
            }
            return NSWorkspace.shared.open(url)
        })
}

@MainActor final class CLISetupGuideActions: ObservableObject {
    enum Feedback: Equatable { case copied(CLISetupCommand), copyFailed, terminalOpened, terminalUnavailable }
    @Published private(set) var feedback: Feedback?
    private let effects: CLISetupGuideEffects
    init(effects: CLISetupGuideEffects? = nil) { self.effects = effects ?? .live }
    func copy(_ value: CLISetupCommand) {
        feedback = effects.copy(value.command) ? .copied(value) : .copyFailed
    }
    func openTerminal() {
        feedback = effects.openTerminal() ? .terminalOpened : .terminalUnavailable
    }
}

@MainActor struct CLISetupGuideView: View {
    let close: () -> Void
    @StateObject private var actions: CLISetupGuideActions
    init(close: @escaping () -> Void, actions: CLISetupGuideActions? = nil) {
        self.close = close
        _actions = StateObject(wrappedValue: actions ?? CLISetupGuideActions())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("CLI setup")).font(.system(size: 20, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(
                        L10n.tr(
                            "Install the CLI, sign in with its Terminal command, then choose its executable here.")
                    )
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    ForEach(CLISetupCommand.allCases) { value in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(value.title).font(.system(size: 14, weight: .semibold))
                            Text(L10n.tr("Sign-in command")).font(.system(size: 11)).foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                Text(value.command).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                                Spacer(minLength: 0)
                                Button(L10n.tr("Copy command")) { actions.copy(value) }
                                    .accessibilityLabel(L10n.format("Copy %@ sign-in command", value.title))
                                    .accessibilityIdentifier("cli-copy-" + value.id)
                                    .aboutCLILeafBounds("cli-copy-" + value.id)
                            }
                            Link(L10n.tr("Installation guide"), destination: value.guide).font(.system(size: 12))
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 12)
            }.frame(maxHeight: .infinity)
            if let message = feedbackMessage {
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cli-guide-feedback")
                    .aboutCLILeafBounds("cli-guide-feedback")
            }
            HStack {
                Button(L10n.tr("Open Terminal"), action: actions.openTerminal)
                    .accessibilityIdentifier("cli-open-terminal")
                    .aboutCLILeafBounds("cli-open-terminal")
                Spacer()
                Button(L10n.tr("Close"), action: close).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cli-guide-close")
                    .aboutCLILeafBounds("cli-guide-close")
            }
        }.padding(24).frame(width: 480, height: 460)
    }
    private var feedbackMessage: String? {
        switch actions.feedback {
        case .copied(let value): return L10n.format("Copied %@ sign-in command.", value.title)
        case .copyFailed: return L10n.tr("Couldn’t copy the command. Select and copy it above.")
        case .terminalOpened: return L10n.tr("Paste and run the command in Terminal to sign in.")
        case .terminalUnavailable: return L10n.tr("Couldn’t open Terminal. Open it from Applications → Utilities.")
        case nil: return nil
        }
    }
}
