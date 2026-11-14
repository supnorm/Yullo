import AppKit
import ApplicationServices

// Electron apps (Slack, VS Code, Discord, Notion, Obsidian…) and Chromium
// browsers publish no focused element until an assistive app asks them to build
// their accessibility tree, as VoiceOver does. Other tools on a Mac often asked
// already, so a fresh Mac is where Chrome or Obsidian report no focus
// (stage=focus issue=focusUnavailable) and Replace can't find the selection.
//
// AXManualAccessibility, Electron's switch, is asked once per process and kept:
// it changes nothing else. Chrome answers AXEnhancedUserInterface instead, which
// also changes how its windows animate, so that one is turned on only when focus
// is still missing, and only if nothing else had it on, and `release()` puts it
// back when the Yullo operation ends. Every Accessibility read of the focused
// element goes through `focusedElement`, so capture, Replace, dictation and
// read aloud share one rule.
enum AccessibilityTreeWake {
    struct Switches {
        var manual: (pid_t) -> Void
        var enhanced: (pid_t) -> Bool?
        var setEnhanced: (pid_t, Bool) -> Void
        var asksBuild: (pid_t) -> Bool
        static let live = Switches(
            manual: { pid in
                AXUIElementSetAttributeValue(application(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
            },
            enhanced: { pid in
                var value: CFTypeRef?
                guard
                    AXUIElementCopyAttributeValue(application(pid), "AXEnhancedUserInterface" as CFString, &value)
                        == .success
                else { return nil }
                return (value as? NSNumber)?.boolValue
            },
            setEnhanced: { pid, on in
                AXUIElementSetAttributeValue(
                    application(pid), "AXEnhancedUserInterface" as CFString, on ? kCFBooleanTrue : kCFBooleanFalse)
            },
            asksBuild: { pid in
                pid != ProcessInfo.processInfo.processIdentifier
                    && AccessibilityTreeWake.asksBuild(
                        bundleURL: NSRunningApplication(processIdentifier: pid)?.bundleURL)
            })
        private static func application(_ pid: pid_t) -> AXUIElement {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            return app
        }
    }
    nonisolated(unsafe) static var switches = Switches.live
    private static let lock = NSLock()
    nonisolated(unsafe) private static var asked: Set<pid_t> = []
    nonisolated(unsafe) private static var enhanced: Set<pid_t> = []
    // How long a just-woken app gets to publish its focused element.
    static let settle: TimeInterval = 0.6

    // Chromium's and Electron's own application classes are the ones that answer
    // the request; the Electron or Chromium Embedded framework covers apps that
    // rename their class (Spotify and other CEF apps).
    static func asksBuild(bundleURL: URL?) -> Bool {
        guard let bundleURL else { return false }
        let principal = Bundle(url: bundleURL)?.object(forInfoDictionaryKey: "NSPrincipalClass") as? String
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        return ["BrowserCrApplication", "AtomApplication"].contains(principal)
            || ["Electron Framework.framework", "Chromium Embedded Framework.framework"].contains {
                FileManager.default.fileExists(atPath: frameworks.appendingPathComponent($0).path)
            }
    }

    // True the first time a process is asked; the tree then takes a moment to build.
    @discardableResult static func prepare(_ processID: pid_t) -> Bool {
        guard processID > 0, !lock.withLock({ asked.contains(processID) }) else { return false }
        let needed = switches.asksBuild(processID)
        guard lock.withLock({ asked.insert(processID).inserted }), needed else { return false }
        switches.manual(processID)
        return true
    }
    @discardableResult static func prepareFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication.map { prepare($0.processIdentifier) } ?? false
    }

    // The focused element, read through `read`. A Chromium or Electron app that
    // has none is woken, and read again until it settles; only a change Yullo
    // just made is waited for, so an app with nothing focused costs no time.
    static func focusedElement<Element>(
        in processID: pid_t?, missing: (Error) -> Bool,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },  // AX workers only.
        read: () throws -> Element
    ) throws -> Element {
        let pid = processID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        let woke = pid.map(prepare) ?? false
        do {
            if woke { return try poll(until: now() + settle, missing: missing, now: now, pause: pause, read: read) }
            return try read()
        } catch let error where missing(error) {
            guard let pid, enhance(pid) else { throw error }
            return try poll(until: now() + settle, missing: missing, now: now, pause: pause, read: read)
        }
    }

    // Puts back AXEnhancedUserInterface wherever Yullo turned it on.
    static func release() {
        let pids = lock.withLock {
            defer { enhanced.removeAll() }
            return enhanced
        }
        for pid in pids { switches.setEnhanced(pid, false) }
    }

    private static func enhance(_ pid: pid_t) -> Bool {
        guard pid > 0, switches.asksBuild(pid), !lock.withLock({ enhanced.contains(pid) }),
            switches.enhanced(pid) != true
        else { return false }
        switches.setEnhanced(pid, true)
        lock.withLock { _ = enhanced.insert(pid) }
        return true
    }

    private static func poll<Element>(
        until deadline: TimeInterval, missing: (Error) -> Bool, now: () -> TimeInterval, pause: (TimeInterval) -> Void,
        read: () throws -> Element
    ) throws -> Element {
        while true {
            do { return try read() } catch  where missing(error) && now() < deadline {
                pause(min(0.025, max(0, deadline - now())))
            }
        }
    }
}
