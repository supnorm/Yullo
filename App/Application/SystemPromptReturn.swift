import AppKit

// A macOS prompt that Yullo starts (a Keychain password, microphone access,
// Touch ID) takes focus while it is open. When it closes, macOS often
// activates the previously used app, leaving Yullo's window behind it. This
// owner returns to the Yullo window that was in front, unless the person
// switched apps while the prompt was still on screen.
@MainActor final class SystemPromptReturn {
    nonisolated static let promptAgents: Set<String> = [
        "com.apple.SecurityAgent", "com.apple.UserNotificationCenter", "com.apple.coreautha",
        "com.apple.LocalAuthentication.UIAgent", "com.apple.CoreLocationAgent",
        "com.apple.accessibility.universalAccessAuthWarn"
    ]
    // A prompt's own button can open System Settings; that is the person's choice.
    nonisolated static let destinations: Set<String> = ["com.apple.systempreferences", "com.apple.Settings"]
    // macOS hands focus back just after the prompt window closes.
    nonisolated static let settleDelay: TimeInterval = 0.3

    private weak var lastKeyWindow: NSWindow?
    private weak var returnWindow: NSWindow?
    private var promptOpen = false
    private var check = 0
    private let promptWindowOnScreen: () -> Bool
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private let restore: (NSWindow) -> Void

    init(
        promptWindowOnScreen: @escaping () -> Bool = SystemPromptReturn.agentWindowOnScreen,
        schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(action) }
        },
        restore: @escaping (NSWindow) -> Void
    ) {
        self.promptWindowOnScreen = promptWindowOnScreen
        self.schedule = schedule
        self.restore = restore
    }

    // Called as Yullo resigns active, while its key window is still known.
    func yulloWillResign(keyWindow: NSWindow?) { lastKeyWindow = keyWindow }

    func activated(bundleID: String?, isYullo: Bool) {
        if isYullo {
            promptOpen = false
            returnWindow = nil
        } else if let bundleID, Self.promptAgents.contains(bundleID) {
            if !promptOpen { returnWindow = lastKeyWindow }
            promptOpen = true
        } else if !promptOpen || bundleID.map(Self.destinations.contains) == true {
            promptOpen = false
            returnWindow = nil
            lastKeyWindow = nil
        } else {
            promptOpen = false
            check += 1
            let ticket = check
            schedule(Self.settleDelay) { [weak self] in
                guard let self, self.check == ticket, !self.promptOpen else { return }
                let window = self.returnWindow
                self.returnWindow = nil
                // A prompt still on screen means the person switched apps.
                guard let window, !self.promptWindowOnScreen() else { return }
                self.restore(window)
            }
        }
    }

    nonisolated static func agentWindowOnScreen() -> Bool {
        let agents = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier.map(promptAgents.contains) == true
        }.map(\.processIdentifier)
        guard !agents.isEmpty,
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return false }
        return windows.contains { ($0[kCGWindowOwnerPID as String] as? pid_t).map(agents.contains) == true }
    }
}
