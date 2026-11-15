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
    // Chromium builds a whole page's tree after AXEnhancedUserInterface turns on;
    // a long conversation takes longer than Electron's own switch. Paid only
    // when focus is still missing in a Chromium or Electron app.
    static let enhancedSettle: TimeInterval = 1.5

    // Chromium's, Electron's and Firefox's own application classes are the ones that
    // answer the request (Gecko builds its tree on AXEnhancedUserInterface); the Electron or Chromium Embedded framework covers apps that
    // rename their class (Spotify and other CEF apps).
    static func asksBuild(bundleURL: URL?) -> Bool {
        guard let bundleURL else { return false }
        let principal = Bundle(url: bundleURL)?.object(forInfoDictionaryKey: "NSPrincipalClass") as? String
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        return ["BrowserCrApplication", "AtomApplication", "GeckoNSApplication"].contains(principal)
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
            return try poll(until: now() + enhancedSettle, missing: missing, now: now, pause: pause, read: read)
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

    // Some apps never answer which element has focus, even woken: an Electron
    // build without AXManualAccessibility (the ChatGPT app, measured: its
    // composer is a ProseMirror text area in a web area), or a window that only
    // flags its field. Their focused window still shows it: a text field marked
    // focused, else the web area holding the selection and the editor around
    // it. A selection in read-only page text is the web area itself, which
    // capture then reads as read-only. Read-only; walks a bounded number of
    // elements, never into page content.
    struct WindowTree<Element> {
        var window: () -> Element?
        var node: (Element) -> (role: String?, focused: Bool, children: [Element])
        // The element holding the selection's start in a web area, and its editable ancestor.
        var selectionHolder: (Element) -> Element?
        var editableAncestor: (Element) -> Element?
        var parent: (Element) -> Element?
        var role: (Element) -> String?
    }
    // Chrome and Firefox in the background answer their own application as the focused
    // element (measured); a window as "focus" is no field either. Both count as no focus.
    static func standsInForFocus(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success else {
            return false
        }
        return [kAXApplicationRole, kAXWindowRole].contains(role as? String ?? "")
    }
    static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]
    static let windowFocusLimit = 400
    static func windowFocus<Element>(_ tree: WindowTree<Element>, limit: Int = windowFocusLimit) -> Element? {
        guard let window = tree.window() else { return nil }
        var queue = [window], next = 0
        var web: (element: Element, focused: Bool)?
        while next < queue.count, next < limit {
            let element = queue[next]
            next += 1
            let node = tree.node(element)
            if let role = node.role, textRoles.contains(role), node.focused { return element }
            if node.role == "AXWebArea" {
                if web == nil || (node.focused && web?.focused == false) { web = (element, node.focused) }
                continue
            }
            queue.append(contentsOf: node.children)
        }
        guard let area = web?.element else { return nil }
        guard let holder = tree.selectionHolder(area) else { return area }
        if let editor = tree.editableAncestor(holder) { return editor }
        var element: Element? = holder
        for _ in 0..<32 {
            guard let current = element else { break }
            if let role = tree.role(current) {
                if textRoles.contains(role) { return current }
                if role == "AXWebArea" { break }
            }
            element = tree.parent(current)
        }
        return area
    }
    static func windowFocus(in processID: pid_t) -> AXUIElement? {
        guard processID > 0 else { return nil }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.25)
        func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
            return result
        }
        func element(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            let element = unsafeBitCast(value, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(element, 0.25)
            return element
        }
        let tree = WindowTree<AXUIElement>(
            window: { element(value(app, kAXFocusedWindowAttribute)) ?? element(value(app, kAXMainWindowAttribute)) },
            node: { node in
                var values: CFArray?
                let names = [kAXRoleAttribute, kAXFocusedAttribute, kAXChildrenAttribute] as CFArray
                guard AXUIElementCopyMultipleAttributeValues(node, names, [], &values) == .success,
                    let list = values as? [AnyObject], list.count == 3
                else { return (nil, false, []) }
                let children = (list[2] as? [AnyObject] ?? []).compactMap { element($0) }
                return (list[0] as? String, (list[1] as? Bool) == true, children)
            },
            selectionHolder: { area in
                guard let range = value(area, "AXSelectedTextMarkerRange"),
                    CFGetTypeID(range) == AXTextMarkerRangeGetTypeID()
                else { return nil }
                let start = AXTextMarkerRangeCopyStartMarker(unsafeBitCast(range, to: AXTextMarkerRange.self))
                var holder: CFTypeRef?
                guard
                    AXUIElementCopyParameterizedAttributeValue(
                        area, "AXUIElementForTextMarker" as CFString, start, &holder) == .success
                else { return nil }
                return element(holder)
            },
            editableAncestor: { element(value($0, "AXEditableAncestor")) },
            parent: { element(value($0, kAXParentAttribute)) },
            role: { value($0, kAXRoleAttribute) as? String })
        return windowFocus(tree)
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
