import AppKit
import ApplicationServices

// The front browser page's host, read through Accessibility when dictation
// starts. Only the host leaves this owner; the address is never kept or sent.
// No AppleScript and no new permission: without Accessibility, or when the
// page has no readable address, the browser's own rule applies.
// It runs only when a website rule could apply, and is bounded: every element
// it asks gets a short messaging timeout, and the whole read stops at a
// deadline, so a busy or hung browser never holds up the recording.
@MainActor enum BrowserAddress {
    static let budget: TimeInterval = 0.15

    static func host(pid: pid_t, bundleID: String?) -> String? {
        guard let bundleID, CoreWebsite.isBrowser(bundleID), AXIsProcessTrusted() else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(budget))
        AccessibilityTreeWake.prepare(pid)
        guard let url = webAreaURL(in: app, deadline: deadline) else { return nil }
        return host(of: url)
    }

    static func host(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host
        else { return nil }
        return CoreWebsite.domain(host)
    }

    // The web area around the focused element, or else the first one in the focused window.
    private static func webAreaURL(in app: AXUIElement, deadline: TimeInterval) -> URL? {
        // Each element asked gets what is left of the budget, never the system's seconds.
        func remaining() -> Float? {
            let left = deadline - ProcessInfo.processInfo.systemUptime
            return left > 0.005 ? Float(left) : nil
        }
        func asElement(_ object: AnyObject) -> AXUIElement? {
            guard CFGetTypeID(object) == AXUIElementGetTypeID(), let left = remaining() else { return nil }
            let element = unsafeBitCast(object, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(element, left)
            return element
        }
        var element = value(app, kAXFocusedUIElementAttribute).flatMap(asElement)
        for _ in 0..<40 {
            guard let current = element, remaining() != nil else { break }
            if role(current) == "AXWebArea", let url = url(current) { return url }
            element = value(current, kAXParentAttribute).flatMap(asElement)
        }
        guard let window = value(app, kAXFocusedWindowAttribute).flatMap(asElement) else { return nil }
        // A bounded breadth-first walk: browsers keep the page a few levels below the window.
        var queue = [window], visited = 0
        while !queue.isEmpty, visited < 300, remaining() != nil {
            let current = queue.removeFirst()
            visited += 1
            if role(current) == "AXWebArea" { return url(current) }
            let children = value(current, kAXChildrenAttribute) as? [AnyObject] ?? []
            queue += children.compactMap(asElement)
        }
        return nil
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
    private static func role(_ element: AXUIElement) -> String? { value(element, kAXRoleAttribute) as? String }
    private static func url(_ element: AXUIElement) -> URL? {
        guard let object = value(element, kAXURLAttribute) else { return nil }
        if let url = object as? URL { return url }
        return (object as? String).flatMap(URL.init(string:))
    }
}
