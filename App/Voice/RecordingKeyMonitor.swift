import AppKit
import Carbon

struct RecordingKeyEdges {
    private(set) var held: Set<UInt32> = []
    var isEmpty: Bool { held.isEmpty }
    mutating func press(_ key: UInt32) -> Bool { held.insert(key).inserted }
    mutating func release(_ key: UInt32) { held.remove(key) }
    mutating func reconcile(isDown: (UInt32) -> Bool) { held = held.filter(isDown) }
}

// Temporary Carbon hotkeys consume Return in the original editor. A global
// NSEvent observer cannot do that. Keep a pressed key registered until release,
// so a held Return cannot become a repeat/newline after recording finishes.
final class RecordingKeyMonitor {
    private enum Registration {
        case native(EventHotKeyRef)
        #if YULLO_TESTING
            case fixture
        #endif
    }
    private static let signature: OSType = 0x59564B59
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCopy: (() -> Void)?
    private var copyRegistration: Registration?
    private var copyBinding: (key: UInt32, modifiers: UInt32)?
    private var copyHeld = false
    private static let copyIDBase: UInt32 = 0x10000
    private var copyID: UInt32 = 0xFFFF
    private var handler: EventHandlerRef?
    private var refs: [UInt32: Registration] = [:]
    private var edges = RecordingKeyEdges()
    private var desiredKeys = Set<UInt32>()
    // Return finishes only while recording; otherwise a press is swallowed.
    private var returnFinishes = false
    private var releaseRecovery: Timer?
    #if YULLO_TESTING
        private var fixtureRegister: ((UInt32) -> Bool)?
        private var fixtureUnregister: ((UInt32) -> Void)?
        private var fixtureIsDown: ((UInt32) -> Bool)?
        init(
            register: @escaping (UInt32) -> Bool, unregister: @escaping (UInt32) -> Void,
            isDown: @escaping (UInt32) -> Bool
        ) {
            fixtureRegister = register
            fixtureUnregister = unregister
            fixtureIsDown = isDown
        }
        func testReceive(_ key: UInt32, released: Bool = false) { receive(id: key, released: released) }
        var testCopyEventID: UInt32 { copyID }
        func testRecoverReleasedKeys() { recoverReleasedKeys() }
    #endif
    init() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard id.signature == RecordingKeyMonitor.signature else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<RecordingKeyMonitor>.fromOpaque(context).takeUnretainedValue()
                owner.receive(id: id.id, released: GetEventKind(event) == UInt32(kEventHotKeyReleased))
                return noErr
            }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    deinit {
        watchOtherInput(nil)
        clear()
        if let handler { RemoveEventHandler(handler) }
    }
    func start(finishOnReturn: Bool) -> Bool {
        clearCopy()
        returnFinishes = finishOnReturn
        return configure(finishOnReturn ? [36, 76, 53] : [53])
    }
    func retainCancellation() -> Bool {
        returnFinishes = false
        return configure([53])
    }
    // Before recording and while its result is made, a Return meant to end
    // the recording must never reach the app (in a chat it would send the
    // message), so it is held and does nothing.
    func swallowReturn() -> Bool {
        returnFinishes = false
        return configure([36, 76, 53])
    }
    private func configure(_ keys: Set<UInt32>) -> Bool {
        recoverReleasedKeys()
        for key in keys.sorted() where refs[key] == nil {
            guard let registration = register(key) else {
                clear()
                return false
            }
            refs[key] = registration
            // A key used to choose or dismiss a menu may still be physically
            // down. Only its next fresh press belongs to this interaction.
            if isDown(key) { _ = edges.press(key) }
        }
        desiredKeys = keys
        releaseUnusedKeys()
        if !edges.isEmpty { beginReleaseRecovery() }
        return true
    }
    func suspendForMenu() { clear() }
    // Keys and clicks that reach other apps; Yullo's own registered keys never
    // arrive here, and Return, Enter and Escape are ignored in any case.
    private var otherInputMonitor: Any?
    func watchOtherInput(_ handler: (() -> Void)?) {
        if let otherInputMonitor { NSEvent.removeMonitor(otherInputMonitor) }
        otherInputMonitor = nil
        guard let handler else { return }
        otherInputMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            guard event.type != .keyDown || !Self.heldKeys.contains(UInt32(event.keyCode)) else { return }
            handler()
        }
    }
    private static let heldKeys: Set<UInt32> = [36, 76, 53]
    func stop() {
        clearCopy()
        desiredKeys.removeAll()
        releaseUnusedKeys()
        if !edges.isEmpty { beginReleaseRecovery() }
    }
    @discardableResult func configureCopy(key: UInt32?, modifiers: UInt32 = 0) -> Bool {
        guard let key, key <= 127, modifiers != 0,
            !(key == 8 && modifiers == UInt32(cmdKey)), key != 53
        else {
            clearCopy()
            return false
        }
        if let copyBinding, copyBinding.key == key, copyBinding.modifiers == modifiers { return true }
        clearCopy()
        copyID = copyID == UInt32.max ? Self.copyIDBase : copyID + 1
        let registration: Registration
        #if YULLO_TESTING
            if let fixtureRegister {
                guard fixtureRegister(Self.copyIDBase) else { return false }
                registration = .fixture
            } else {
                guard let value = registerCopy(key: key, modifiers: modifiers) else { return false }
                registration = value
            }
        #else
            guard let value = registerCopy(key: key, modifiers: modifiers) else { return false }
            registration = value
        #endif
        copyBinding = (key, modifiers)
        copyRegistration = registration
        copyHeld = isDown(key)
        if copyHeld { beginReleaseRecovery() }
        return true
    }
    private func registerCopy(key: UInt32, modifiers: UInt32) -> Registration? {
        guard handler != nil else { return nil }
        var ref: EventHotKeyRef?
        guard
            RegisterEventHotKey(
                key, modifiers, EventHotKeyID(signature: Self.signature, id: copyID),
                GetApplicationEventTarget(), 0, &ref) == noErr, let ref
        else { return nil }
        return .native(ref)
    }
    private func clearCopy() {
        if let copyRegistration { unregister(Self.copyIDBase, copyRegistration) }
        copyRegistration = nil
        copyBinding = nil
        copyHeld = false
    }
    private func register(_ key: UInt32) -> Registration? {
        #if YULLO_TESTING
            if let fixtureRegister { return fixtureRegister(key) ? .fixture : nil }
        #endif
        guard handler != nil else { return nil }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            key, 0, EventHotKeyID(signature: Self.signature, id: key),
            GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        return .native(ref)
    }
    private func unregister(_ key: UInt32, _ registration: Registration) {
        switch registration {
        case .native(let ref): UnregisterEventHotKey(ref)
        #if YULLO_TESTING
            case .fixture: fixtureUnregister?(key)
        #endif
        }
    }
    private func releaseUnusedKeys() {
        for (key, registration) in refs where !desiredKeys.contains(key) && !edges.held.contains(key) {
            unregister(key, registration)
            refs[key] = nil
        }
        if edges.isEmpty && !copyHeld {
            releaseRecovery?.invalidate()
            releaseRecovery = nil
        }
    }
    private func beginReleaseRecovery() {
        if releaseRecovery == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.recoverReleasedKeys() }
            RunLoop.main.add(timer, forMode: .common)
            releaseRecovery = timer
        }
    }
    private func recoverReleasedKeys() {
        // Recover a lost key-up after lock/sleep only once the actual key is up.
        if copyHeld, let copyBinding, !isDown(copyBinding.key) { copyHeld = false }
        edges.reconcile(isDown: isDown)
        releaseUnusedKeys()
    }
    private func isDown(_ key: UInt32) -> Bool {
        #if YULLO_TESTING
            if let fixtureIsDown { return fixtureIsDown(key) }
        #endif
        return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key))
            || CGEventSource.keyState(.hidSystemState, key: CGKeyCode(key))
    }
    private func clear() {
        clearCopy()
        desiredKeys.removeAll()
        releaseRecovery?.invalidate()
        releaseRecovery = nil
        for (key, registration) in refs { unregister(key, registration) }
        refs.removeAll()
        edges = RecordingKeyEdges()
    }
    private func receive(id: UInt32, released: Bool) {
        if id >= Self.copyIDBase {
            guard id == copyID else { return }
            if released {
                copyHeld = false
                return
            }
            guard copyRegistration != nil, !copyHeld else { return }
            copyHeld = true
            beginReleaseRecovery()
            onCopy?()
            return
        }
        if released {
            edges.release(id)
            releaseUnusedKeys()
            return
        }
        let first = edges.press(id)
        guard desiredKeys.contains(id), first else { return }
        beginReleaseRecovery()
        if id == 53 { onCancel?() } else if returnFinishes { onFinish?() }
    }
}
