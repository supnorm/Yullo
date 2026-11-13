import SwiftUI
import AppKit

// Canonical account builders are shared with the actual translation and speech
// adapters. Defaults describe service namespaces, not proof of an account/key.
enum CredentialAccessTargets {
    static func make(_ preferences: Preferences) -> [CredentialAccessTarget] {
        func target(
            _ service: CredentialAccessService, input: String, account: () throws -> String
        ) -> CredentialAccessTarget {
            guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .init(service: service, account: nil)
            }
            do { return .init(service: service, account: try account()) } catch {
                return .init(service: service, account: nil, invalidConfiguration: true)
            }
        }
        return [
            target(.textAPI, input: preferences.endpoint) {
                try APIClient.endpoint(preferences.endpoint.trimmingCharacters(in: .whitespacesAndNewlines))
                    .absoluteString
            },
            target(.azure, input: preferences.azureRegion) {
                try SpeechService.keyAccount(provider: .azure, configuration: .init(), region: preferences.azureRegion)
            },
            target(.google, input: preferences.googleSpeech.endpoint) {
                try SpeechService.keyAccount(provider: .google, configuration: preferences.googleSpeech)
            },
            target(.elevenLabs, input: preferences.elevenLabsSpeech.endpoint) {
                try SpeechService.keyAccount(provider: .elevenlabs, configuration: preferences.elevenLabsSpeech)
            },
            target(.speechAPI, input: preferences.speechAPI.endpoint) {
                try SpeechService.keyAccount(provider: .speechAPI, configuration: preferences.speechAPI)
            }
        ]
    }
}

enum CredentialAccessGroup: String, CaseIterable, Identifiable {
    case text, speech
    var id: String { rawValue }
    var titleKey: String { self == .text ? "Translate & Refine" : "Read aloud" }
    var services: [CredentialAccessService] {
        self == .text ? [.textAPI] : [.azure, .google, .elevenLabs, .speechAPI]
    }
}

@MainActor
struct CredentialAccessView: View {
    let preferences: Preferences
    let openService: (CredentialAccessService) -> Void
    // Called once when an explicit Allow access request ends with access.
    var accessAllowed: (() -> Void)?
    @StateObject private var access: CredentialAccessController

    init(
        preferences: Preferences, controller: CredentialAccessController? = nil,
        openService: @escaping (CredentialAccessService) -> Void, accessAllowed: (() -> Void)? = nil
    ) {
        self.preferences = preferences
        self.openService = openService
        self.accessAllowed = accessAllowed
        _access = StateObject(wrappedValue: controller ?? CredentialAccessController())
    }
    @State private var otherServicesExpanded = false
    // Services asked during Allow access to saved keys; nil when no walk runs.
    @State private var allowingAll: Set<CredentialAccessService>?
    // Every service with a saved setup is listed; only ones never set up fold under Other services.
    private var primaryRows: [CredentialAccessController.Row] {
        access.rows.filter { isSelected($0.service) || configured.contains($0.service) }
    }
    private var configured: Set<CredentialAccessService> {
        // The API is the shared translator and writer, so a saved one is always listed.
        Set(
            CredentialAccessTargets.make(preferences).filter { $0.isConfigured && $0.service == .textAPI }.map(
                \.service))
    }
    private var otherRows: [CredentialAccessController.Row] {
        access.rows.filter { row in !primaryRows.contains(where: { $0.service == row.service }) }
    }
    private var inspectionServices: Set<CredentialAccessService> {
        // Listed keys are read silently on open, so each shows Allowed or Allow access
        // without a Check step. Other keys are read only once Other services opens.
        Set(
            CredentialAccessService.allCases.filter {
                otherServicesExpanded || isSelected($0) || configured.contains($0)
            })
    }
    var body: some View {
        // Same grammar as Services: each key is a row with its name, a grey state and one button.
        SettingsSection(L10n.tr("Saved keys")) {
            SettingsRows {
                ForEach(CredentialAccessGroup.allCases) { group in
                    let rows = primaryRows.filter { group.services.contains($0.service) }
                    if !rows.isEmpty {
                        Text(L10n.tr(group.titleKey)).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("credential-access-group-" + group.rawValue).settingsGroupLabel()
                        ForEach(rows) { credentialRow($0) }
                    }
                }
                accessStep
                if !otherRows.isEmpty {
                    Group {
                        if otherServicesMustStayOpen {
                            Text(L10n.tr("Other services"))
                        } else {
                            SettingsDisclosureRow(
                                title: L10n.tr("Other services"), summary: "\(otherRows.count)",
                                isExpanded: otherServicesDisclosure)
                        }
                    }
                    .accessibilityIdentifier("credential-access-other-services")
                    .credentialAccessProbe(
                        "other-services",
                        action: otherServicesMustStayOpen
                            ? nil : { otherServicesDisclosure.wrappedValue.toggle() }
                    )
                    .credentialAccessProbe(
                        "other-services-open", action: { otherServicesDisclosure.wrappedValue = true }
                    )
                    .credentialAccessProbe(
                        "other-services-close", action: { otherServicesDisclosure.wrappedValue = false })
                    if otherServicesDisclosure.wrappedValue {
                        ForEach(otherRows) { credentialRow($0) }
                    }
                }
            }
        }
        .id("keychain")
        .onChange(of: access.rows) { previous, current in
            if let asked = allowingAll, !access.isWorking {
                // Continue only after the last key was allowed.
                let refused = current.contains { asked.contains($0.service) && $0.state != .available }
                if refused { allowingAll = nil } else { allowNext() }
            }
            let granted = current.contains { row in
                row.state == .available
                    && previous.first(where: { $0.service == row.service })?.state == .requestingAccess
            }
            if granted {
                NotificationCenter.default.post(name: CredentialAccessInteraction.allowed, object: nil)
                // Settings stays while another key in use still needs access,
                // so the person can allow it here too.
                let pending = primaryRows.contains {
                    $0.state.needsAccess || $0.state.isWorking || $0.state == .notChecked
                }
                if !pending { accessAllowed?() }
            }
        }
        .onAppear {
            access.appear(targets: CredentialAccessTargets.make(preferences), inspecting: inspectionServices)
        }
        .onChange(of: preferences) { _, new in
            access.configure(CredentialAccessTargets.make(new), inspecting: inspectionServices)
        }
        .onChange(of: otherServicesMustStayOpen, initial: true) { _, pinned in
            if pinned { otherServicesExpanded = true }
        }
        .onChange(of: access.rows) { old, rows in
            // A fast read can finish before SwiftUI observes its working state.
            // Compare all rows before filtering current optional services: moving
            // an old readable primary row here is not a newly completed check.
            let optional = otherRows.map(\.service)
            if rows.contains(where: { row in
                optional.contains(row.service)
                    && (row.state == .available || row.state == .noSavedKey
                        || (needsAttention(row.state) && row.state != .invalidConfiguration))
                    && old.first(where: { $0.service == row.service })?.state != row.state
            }) {
                otherServicesExpanded = true
            }
        }
        .onDisappear { access.disappear() }
    }
    // Keys waiting for access: one step allows each in turn, and one line
    // says what to choose when macOS asks.
    private var waitingRows: [CredentialAccessController.Row] {
        access.rows.filter { row in
            (row.state.needsAccess || row.state == .requestingAccess)
                && (primaryRows.contains { $0.service == row.service } || otherServicesDisclosure.wrappedValue)
        }
    }
    @ViewBuilder private var accessStep: some View {
        let waiting = waitingRows
        if !waiting.isEmpty {
            HStack(spacing: 12) {
                Text(L10n.tr("When macOS asks, choose Always Allow."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        ForEach(waiting) { row in
                            Color.clear.credentialAccessProbe("access-help-" + row.service.rawValue)
                        }
                    }
                Spacer(minLength: 8)
                if waiting.filter(\.state.needsAccess).count > 1 {
                    Button(L10n.tr("Allow access to saved keys…")) {
                        allowingAll = []
                        allowNext()
                    }.disabled(access.isWorking).accessibilityIdentifier("credential-access-allow-all")
                }
            }.accessibilityIdentifier("credential-access-step")
        }
    }
    // The next waiting key, each asked once; a refusal ends the walk.
    private func allowNext() {
        guard let done = allowingAll, !access.isWorking,
            let next = waitingRows.first(where: { $0.state.needsAccess && !done.contains($0.service) })
        else {
            allowingAll = nil
            return
        }
        allowingAll?.insert(next.service)
        access.allowAccess(for: next.service)
    }
    private var otherServicesMustStayOpen: Bool {
        otherRows.contains { $0.state.isWorking }
    }
    private var otherServicesDisclosure: Binding<Bool> {
        Binding(
            get: { otherServicesExpanded || otherServicesMustStayOpen },
            set: { expanded in
                if expanded || !otherServicesMustStayOpen {
                    otherServicesExpanded = expanded
                    access.inspectVisibleServices(inspectionServices)
                }
            })
    }
    private func credentialRow(_ row: CredentialAccessController.Row) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr(row.service.titleKey))
                    .fixedSize(horizontal: false, vertical: true)
                if row.state != .available { status(row) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 6) {
                if row.state == .available {
                    Label(L10n.tr("Allowed"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel(L10n.tr("Saved keys") + ": " + L10n.tr("Allowed"))
                        .help(L10n.tr("Key available"))
                        .credentialAccessProbe("state-" + row.service.rawValue)
                } else if row.state.isWorking {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Button(L10n.tr("Cancel")) { access.cancel() }
                    }.accessibilityIdentifier("credential-access-cancel-" + row.service.rawValue)
                } else if row.state.needsAccess {
                    Button(L10n.tr("Allow access…")) { access.allowAccess(for: row.service) }
                        .disabled(access.isWorking)
                        .accessibilityIdentifier("credential-access-allow-" + row.service.rawValue)
                        .credentialAccessProbe("allow-" + row.service.rawValue)
                } else if row.state == .notChecked || row.state == .unavailable || row.state == .unreadable {
                    Button(L10n.tr("Check")) { access.check(row.service) }
                        .disabled(!access.canCheck(row.service))
                        .help(
                            L10n.tr("Checks this saved key without contacting the service or showing password prompts.")
                        )
                        .accessibilityLabel(L10n.format("Check %@", L10n.tr(row.service.titleKey)))
                        .accessibilityIdentifier("credential-access-check-" + row.service.rawValue)
                        .credentialAccessProbe("check-" + row.service.rawValue)
                }
                if row.state == .notConfigured || row.state == .invalidConfiguration || row.state == .noSavedKey
                    || row.state == .unreadable
                {
                    Button(L10n.tr("Set up…")) {
                        if access.canManage { openService(row.service) }
                    }.disabled(!access.canManage)
                        .accessibilityLabel(L10n.format("Manage %@", L10n.tr(row.service.titleKey)))
                        .accessibilityIdentifier("credential-access-manage-" + row.service.rawValue)
                        .credentialAccessProbe("manage-" + row.service.rawValue)
                }
            }.fixedSize()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("credential-access-" + row.service.rawValue)
        .credentialAccessProbe("row-" + row.service.rawValue)
    }
    @ViewBuilder private func status(_ row: CredentialAccessController.Row) -> some View {
        // A quiet state line; the row's one button is the next step.
        Text(L10n.tr(row.state.titleKey)).fixedSize(horizontal: false, vertical: true)
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .credentialAccessProbe("state-" + row.service.rawValue)
    }
    private func needsAttention(_ state: CredentialAccessState) -> Bool {
        state.needsAccess || state == .unavailable || state == .unreadable || state == .invalidConfiguration
    }
    // In use for its task wherever Yullo works, so a key paused on this Mac
    // only stays listed under that task rather than among Other services.
    private func isSelected(_ service: CredentialAccessService) -> Bool {
        switch service {
        case .textAPI:
            return preferences.engine == "api"
                || (preferences.voiceRefinementEngine == "api"
                    && !preferences.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .azure: return preferences.speechEngine == SpeechProvider.azure.rawValue
        case .google: return preferences.speechEngine == SpeechProvider.google.rawValue
        case .elevenLabs: return preferences.speechEngine == SpeechProvider.elevenlabs.rawValue
        case .speechAPI: return preferences.speechEngine == SpeechProvider.speechAPI.rawValue
        }
    }
}

extension View {
    @ViewBuilder fileprivate func credentialAccessProbe(_ id: String, action: (() -> Void)? = nil) -> some View {
        #if YULLO_TESTING
            self.background(CredentialAccessBoundsProbe(id: id, action: action))
        #else
            self
        #endif
    }
}
#if YULLO_TESTING
    struct CredentialAccessBoundsProbe: NSViewRepresentable {
        let id: String
        var action: (() -> Void)? = nil
        @Environment(\.isEnabled) private var isEnabled
        final class Probe: NSView {
            var probeID = ""
            var action: (() -> Void)?
            var isEnabledInView = false
            override var isFlipped: Bool { true }
        }
        func makeNSView(context: Context) -> Probe {
            let view = Probe()
            view.probeID = id
            view.action = action
            view.isEnabledInView = isEnabled
            return view
        }
        func updateNSView(_ nsView: Probe, context: Context) {
            nsView.probeID = id
            nsView.action = action
            nsView.isEnabledInView = isEnabled
        }
    }
#endif
