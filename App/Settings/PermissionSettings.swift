import AppKit
import AVFoundation
import ApplicationServices
import Combine

enum MicrophonePermission: Equatable {
    case notDetermined, authorized, denied, restricted
    var needsSettings: Bool { self == .denied || self == .restricted }
}

struct VoicePermissionStatus: Equatable {
    let microphone: MicrophonePermission
    let accessibility: Bool
}

@MainActor
struct PermissionSettingsBackend {
    var status: () -> VoicePermissionStatus
    var requestMicrophone: () async -> Void
    var requestAccessibility: () -> Void
    var openMicrophoneSettings: () -> Void
    var openAccessibilitySettings: () -> Void = {}
    // Brings Yullo back in front of System Settings once a grant made there arrives.
    var returnToApp: () -> Void = {}
    var grantPollInterval: Duration = .seconds(1)

    static let system = PermissionSettingsBackend(
        status: {
            let microphone: MicrophonePermission
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined: microphone = .notDetermined
            case .authorized: microphone = .authorized
            case .denied: microphone = .denied
            case .restricted: microphone = .restricted
            @unknown default: microphone = .restricted
            }
            return .init(microphone: microphone, accessibility: AXIsProcessTrusted())
        },
        requestMicrophone: {
            await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { _ in continuation.resume() }
            }
        },
        requestAccessibility: {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        },
        openMicrophoneSettings: {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        },
        openAccessibilitySettings: {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        },
        returnToApp: { NSApp.activate(ignoringOtherApps: true) })
}

@MainActor
final class PermissionSettingsController: ObservableObject {
    @Published private(set) var status: VoicePermissionStatus?
    @Published private(set) var isRequestingMicrophone = false
    private let backend: PermissionSettingsBackend
    private var request: Task<Void, Never>?
    private var revision = UUID()
    private var isPresented = false
    private enum Grant { case microphone, accessibility }
    private var awaitedGrants: Set<Grant> = []
    private var grantWatch: Task<Void, Never>?

    init(backend: PermissionSettingsBackend? = nil) { self.backend = backend ?? .system }

    func appear() {
        isPresented = true
        refresh()
    }
    func refresh() {
        guard isPresented else { return }
        status = backend.status()
    }
    func disappear() {
        isPresented = false
        revision = UUID()
        request?.cancel()
        request = nil
        isRequestingMicrophone = false
        awaitedGrants = []
        grantWatch?.cancel()
        grantWatch = nil
    }
    func microphoneAction() {
        guard isPresented, !isRequestingMicrophone else { return }
        let current = backend.status()
        status = current
        guard current.microphone == .notDetermined else {
            backend.openMicrophoneSettings()
            if current.microphone != .authorized { watchForGrant(.microphone) }
            return
        }
        isRequestingMicrophone = true
        let expected = UUID()
        revision = expected
        let backend = backend
        request = Task { @MainActor [weak self] in
            await backend.requestMicrophone()
            guard !Task.isCancelled, let self, self.isPresented, self.revision == expected else { return }
            self.status = backend.status()
            self.isRequestingMicrophone = false
            self.request = nil
        }
    }
    func accessibilityAction() {
        guard isPresented, !isRequestingMicrophone else { return }
        let current = backend.status()
        status = current
        if !current.accessibility { backend.requestAccessibility() }
        backend.openAccessibilitySettings()
        refresh()
        if status?.accessibility == false { watchForGrant(.accessibility) }
    }
    // System Settings changes arrive while Yullo is in the background, where no
    // activation refresh runs. Only a permission sent there is watched, for at
    // most ten minutes, independently of a later microphone request.
    private func watchForGrant(_ grant: Grant) {
        awaitedGrants.insert(grant)
        guard grantWatch == nil else { return }
        let backend = backend
        grantWatch = Task { @MainActor [weak self] in
            for _ in 0..<600 {
                try? await Task.sleep(for: backend.grantPollInterval)
                guard !Task.isCancelled, let self, self.isPresented else { return }
                let current = backend.status()
                if !self.isRequestingMicrophone, current != self.status { self.status = current }
                let granted = self.awaitedGrants.filter {
                    $0 == .microphone ? current.microphone == .authorized : current.accessibility
                }
                if !granted.isEmpty {
                    self.awaitedGrants.subtract(granted)
                    backend.returnToApp()
                }
                if self.awaitedGrants.isEmpty { break }
            }
            self?.awaitedGrants = []
            self?.grantWatch = nil
        }
    }
}
