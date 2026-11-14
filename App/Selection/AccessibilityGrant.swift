import AppKit
import ApplicationServices
import os

private let accessibilityGrantLogger = Logger(subsystem: "me.yullo.app", category: "accessibility")

// Whether macOS lets this copy of Yullo use Accessibility, read live on every
// call. The row in System Settings can show Yullo turned on while macOS still
// refuses it: the entry was made for a copy signed differently, or the grant
// arrived while Yullo was running and the process hasn't been given it yet.
// Each state's message names the step that fixes it.
enum AccessibilityGrant: Equatable {
    case granted
    // Not trusted. Also the state when the row shows on but its stored code
    // requirement doesn't match this copy.
    case missing
    // Trusted, yet every Accessibility read is refused.
    case notApplied

    #if YULLO_TESTING
        nonisolated(unsafe) static var stated: AccessibilityGrant?
    #endif
    static func current(trusted: Bool? = nil, probe: () -> AXError = systemProbe) -> AccessibilityGrant {
        #if YULLO_TESTING
            if trusted == nil, let stated { return stated }
        #endif
        guard trusted ?? AXIsProcessTrusted() else { return .missing }
        return probe() == .apiDisabled ? .notApplied : .granted
    }

    // One read of the system's focused element. Only a refusal matters here;
    // no value, or an app that's slow to answer, is the app's state, not Yullo's.
    static func systemProbe() -> AXError {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value)
    }

    var message: String? {
        switch self {
        case .granted: nil
        case .missing:
            L10n.tr(
                "Turn on Yullo in Accessibility settings. If it’s already on, remove Yullo with the – button, then add it again with +."
            )
        case .notApplied:
            L10n.tr(
                "Accessibility is on for Yullo, but macOS hasn’t applied it yet. Quit and reopen Yullo. If that doesn’t help, remove Yullo with the – button, then add it again with +."
            )
        }
    }

    // The prompt adds Yullo to the list if it isn't there yet; the pane opens either way.
    @MainActor static func openSettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // The state, read now and logged when it isn't granted (no text or app details).
    static func checked(_ action: String) -> AccessibilityGrant {
        let grant = current()
        if grant != .granted {
            accessibilityGrantLogger.error(
                "Accessibility not usable action=\(action, privacy: .public) state=\(String(describing: grant), privacy: .public)"
            )
        }
        return grant
    }
}

// What a person can send when Yullo can't edit text on their Mac: this copy's
// path and signature, its Accessibility state, and the front app's focused
// element by role only. No text, titles or values are read.
enum AccessibilityDiagnostics {
    static func report(front application: NSRunningApplication?) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let path = homeRelative(Bundle.main.bundleURL.path)
        let trusted = AXIsProcessTrusted()
        let probe = AccessibilityGrant.systemProbe()
        var lines = [
            "Yullo \(version) (\(build))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "App: \(path)\(path.contains("/AppTranslocation/") ? " (translocated)" : "")",
            "Signature: \(signature())",
            "Accessibility: trusted=\(trusted) probe=\(probe.rawValue) state=\(AccessibilityGrant.current(trusted: trusted, probe: { probe }))"
        ]
        if let application {
            lines.append(
                "Front app: \(application.bundleIdentifier ?? "?") \(homeRelative(application.bundleURL?.path ?? "?"))")
            lines.append("Focused: \(focused(in: application.processIdentifier))")
        }
        return lines.joined(separator: "\n")
    }

    // The home folder as "~", so a pasted report never carries the account name.
    static func homeRelative(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // The designated requirement and whether this copy's signature is intact.
    static func signature() -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return "unavailable" }
        let valid = SecCodeCheckValidity(code, [], nil) == errSecSuccess
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
            SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
            SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text
        else { return "valid=\(valid) requirement=unavailable" }
        return "valid=\(valid) \(text as String)"
    }

    private static func focused(in processID: pid_t) -> String {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return "error=\(error.rawValue)"
        }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        func string(_ name: String) -> String {
            var result: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &result)
            return error == .success ? (result as? String ?? "?") : "error=\(error.rawValue)"
        }
        func readable(_ name: String) -> AXError {
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &result)
        }
        var settable = DarwinBoolean(false)
        let settableError = AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable)
        return [
            "role=\(string(kAXRoleAttribute))", "subrole=\(string(kAXSubroleAttribute))",
            "selectedText=\(readable(kAXSelectedTextAttribute).rawValue)",
            "selectedRange=\(readable(kAXSelectedTextRangeAttribute).rawValue)",
            "selectedTextSettable=\(settableError == .success ? "\(settable.boolValue)" : "error=\(settableError.rawValue)")",
            "markerRange=\(readable("AXSelectedTextMarkerRange").rawValue)"
        ].joined(separator: " ")
    }
}
