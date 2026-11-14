import SwiftUI
import AppKit

@MainActor
struct PermissionSettingsView: View {
    @StateObject private var permissions: PermissionSettingsController
    init(backend: PermissionSettingsBackend? = nil) {
        _permissions = StateObject(wrappedValue: PermissionSettingsController(backend: backend))
    }

    var body: some View {
        SettingsSection(L10n.tr("Permissions")) {
            SettingsRows {
                permissionRow(
                    title: "Microphone", purpose: nil,
                    status: microphoneStatus,
                    allowed: permissions.isRequestingMicrophone
                        ? nil : permissions.status.map { $0.microphone == .authorized },
                    action: permissions.status?.microphone == .authorized ? nil : microphoneActionTitle,
                    perform: permissions.microphoneAction)
                permissionRow(
                    title: "Accessibility",
                    purpose: AccessibilityRowText.purpose(permissions.status, asked: permissions.askedAccessibility),
                    status: accessibilityStatus, allowed: permissions.status?.accessibility,
                    action: AccessibilityRowText.action(permissions.status),
                    perform: permissions.accessibilityAction)
            }
        }
        .onAppear { permissions.appear() }
        .onDisappear { permissions.disappear() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    private func permissionRow(
        title: String, purpose: String?, status: String, allowed: Bool?, action: String?,
        perform: @escaping () -> Void
    ) -> some View {
        // Name and purpose on the left; one item on the right: Allowed, or the step to allow it.
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr(title))
                if let purpose {
                    Text(L10n.tr(purpose)).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                Button(L10n.tr(action), action: perform).fixedSize()
                    .disabled(permissions.status == nil || permissions.isRequestingMicrophone)
                    .help(L10n.tr(status))
                    .accessibilityLabel(L10n.tr(title) + ": " + L10n.tr(action))
                    .accessibilityValue(L10n.tr(status))
                    .accessibilityIdentifier(
                        title == "Microphone" ? "permission-microphone" : "permission-accessibility"
                    )
                    .background {
                        #if YULLO_TESTING
                            PermissionActionBoundsProbe(
                                actionEnabled: permissions.status != nil && !permissions.isRequestingMicrophone
                            ).allowsHitTesting(false)
                        #endif
                    }
            } else if allowed == true {
                Label(L10n.tr(status), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(Color.green)
            } else {
                Text(L10n.tr(status)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.font(.system(size: 13)).accessibilityElement(children: .contain)
    }
    private var microphoneStatus: String {
        if permissions.isRequestingMicrophone { return "Requesting access…" }
        guard let status = permissions.status?.microphone else { return "Checking…" }
        switch status {
        case .authorized: return "Allowed"
        case .notDetermined: return "Not requested"
        case .denied: return "Not allowed"
        case .restricted: return "Restricted"
        }
    }
    private var microphoneActionTitle: String {
        guard let status = permissions.status?.microphone else { return "Enable…" }
        if status.needsSettings { return "Open Microphone Settings" }
        return status == .authorized ? "Open Microphone Settings" : "Enable…"
    }
    private var accessibilityStatus: String {
        guard let status = permissions.status else { return "Checking…" }
        return status.accessibility ? "Allowed" : "Not allowed"
    }
}

// The Accessibility row's words, the same in Settings and the guide: its purpose, or,
// once Enable… was pressed and it still isn't working, AccessibilityGrant's reason
// with its fix; and the one action.
enum AccessibilityRowText {
    static func purpose(_ status: VoicePermissionStatus?, asked: Bool) -> String {
        guard let status else { return L10n.tr(purposeKey) }
        switch status.accessibilityState {
        case .notApplied: return status.accessibilityState.message ?? L10n.tr(purposeKey)
        case .missing where asked: return status.accessibilityState.message ?? L10n.tr(purposeKey)
        default: return L10n.tr(purposeKey)
        }
    }
    static func action(_ status: VoicePermissionStatus?) -> String? {
        switch status?.accessibilityState {
        case .granted: return nil
        case .notApplied: return "Open Settings…"
        default: return "Enable…"
        }
    }
    private static let purposeKey = "Lets dictation type into other apps, and the keys work on text you select."
}

#if YULLO_TESTING
    struct PermissionActionBoundsProbe: NSViewRepresentable {
        let actionEnabled: Bool
        func makeNSView(context: Context) -> PermissionActionBoundsView { PermissionActionBoundsView() }
        func updateNSView(_ view: PermissionActionBoundsView, context: Context) { view.actionEnabled = actionEnabled }
    }
    final class PermissionActionBoundsView: NSView {
        var actionEnabled = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
#endif
