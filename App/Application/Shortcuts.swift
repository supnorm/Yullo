import SwiftUI
import AppKit
import Carbon

struct ShortcutSystemHotkeys {
    enum Check: Equatable { case unassigned, noKnownSystemConflict, conflict, unavailable(OSStatus) }
    let enabled: [Shortcut]
    let status: OSStatus
    func check(_ shortcut: Shortcut) -> Check {
        guard shortcut.isAssigned else { return .unassigned }
        guard status == noErr else { return .unavailable(status) }
        return enabled.contains { $0.isAssigned && $0.conflicts(shortcut) } ? .conflict : .noKnownSystemConflict
    }
    // Apple documents this API as non-thread-safe and unsuitable for frequent
    // calls. Query on explicit shortcut review, never during key dispatch.
    @MainActor static func read() -> ShortcutSystemHotkeys {
        var values: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&values)
        let returned = values?.takeRetainedValue()
        guard status == noErr, let array = returned as? [[String: Any]] else {
            return .init(enabled: [], status: status == noErr ? OSStatus(paramErr) : status)
        }
        let enabled = array.compactMap { value -> Shortcut? in
            guard (value[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true,
                let key = value[kHISymbolicHotKeyCode as String] as? NSNumber,
                let modifiers = value[kHISymbolicHotKeyModifiers as String] as? NSNumber,
                let physicalKey = UInt32(exactly: key.int64Value),
                let mask = UInt32(exactly: modifiers.int64Value)
            else { return nil }
            return .init(key: physicalKey, modifiers: mask, label: "")
        }
        return .init(enabled: enabled, status: noErr)
    }
}

// Stored shortcuts keep their physical identity. Presentation is computed from
// the current layout; a serialized label is never used to reconstruct a key.
struct ShortcutPresentation: Equatable {
    let label: String
    let menuKeyEquivalent: String
    let menuModifierFlags: NSEvent.ModifierFlags

    @MainActor func apply(to item: NSMenuItem) {
        item.keyEquivalent = menuKeyEquivalent
        item.keyEquivalentModifierMask = menuModifierFlags
        // The layout was already resolved for a user-customized physical key.
        item.allowsAutomaticKeyEquivalentLocalization = false
        item.allowsAutomaticKeyEquivalentMirroring = false
    }
}

enum ShortcutKeyboardLayout {
    static let didChange = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
    // Resolve a new profile only at adoption; existing physical bindings never
    // pass through this reverse lookup after a layout change.
    static func keyCode(for character: String, modifiers: UInt32) -> UInt32? {
        keyCode(for: character, modifiers: modifiers, using: self.character)
    }

    static func keyCode(
        for character: String, modifiers: UInt32, using characterForKey: (UInt32, UInt32) -> String?
    ) -> UInt32? {
        guard isPrintableKey(character) else { return nil }
        // Shift has its own mask; Command alone can select another base table.
        let context = modifiers & UInt32(cmdKey)
        return (UInt32(0)...127).first {
            characterForKey($0, context)?.lowercased() == character.lowercased()
        }
    }
    // Key equivalents use the unshifted character and a separate Shift mask.
    // Command can select a different layout table (for example Dvorak-QWERTY).
    static func character(key: UInt32, modifiers: UInt32) -> String? {
        guard let code = UInt16(exactly: key) else { return nil }
        let sources = [
            TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        ]
        for source in sources.compactMap({ $0 }) {
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
            guard let bytes = CFDataGetBytePtr(data) else { continue }
            let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
            var dead: UInt32 = 0
            var count = 0
            var characters = [UniChar](repeating: 0, count: 16)
            let status = UCKeyTranslate(
                layout, code, UInt16(kUCKeyActionDisplay), (modifiers & UInt32(cmdKey)) >> 8,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead,
                characters.count, &count, &characters)
            guard status == noErr, count > 0 else { continue }
            let value = String(utf16CodeUnits: characters, count: count)
            if isPrintableKey(value) { return value }
        }
        return nil
    }

    static func isPrintableKey(_ value: String) -> Bool {
        value.unicodeScalars.count == 1
            && !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.union(.whitespacesAndNewlines).contains($0)
            }
    }
}

extension Shortcut {
    var presentation: ShortcutPresentation { presentation(using: ShortcutKeyboardLayout.character) }
    var displayLabel: String { presentation.label }
    var spokenLabel: String { spokenLabel(using: ShortcutKeyboardLayout.character) }

    // VoiceOver hears modifier names, such as “Control-Shift-Y”, while the
    // visible label keeps the menu glyphs. The key itself is the same text.
    func spokenLabel(using character: (UInt32, UInt32) -> String?) -> String {
        let label = presentation(using: character).label
        guard isAssigned else { return label }
        let held = [controlKey, optionKey, shiftKey, cmdKey].filter { modifiers & UInt32($0) != 0 }
        var spoken = String(label.dropFirst(held.count))
        if modifiers & UInt32(cmdKey) != 0 { spoken = L10n.format("Command-%@", spoken) }
        if modifiers & UInt32(shiftKey) != 0 { spoken = L10n.format("Shift-%@", spoken) }
        if modifiers & UInt32(optionKey) != 0 { spoken = L10n.format("Option-%@", spoken) }
        if modifiers & UInt32(controlKey) != 0 { spoken = L10n.format("Control-%@", spoken) }
        return spoken
    }

    func presentation(using character: (UInt32, UInt32) -> String?) -> ShortcutPresentation {
        guard isAssigned else {
            return ShortcutPresentation(label: L10n.tr("None"), menuKeyEquivalent: "", menuModifierFlags: [])
        }
        var flags: NSEvent.ModifierFlags = []
        var prefix = ""
        for (carbon, flag, symbol): (Int, NSEvent.ModifierFlags, String) in [
            (controlKey, .control, "⌃"), (optionKey, .option, "⌥"), (shiftKey, .shift, "⇧"), (cmdKey, .command, "⌘")
        ] where modifiers & UInt32(carbon) != 0 {
            flags.insert(flag)
            prefix += symbol
        }
        let special: [UInt32: (String, String)] = [
            53: ("Esc", "\u{1b}"), 36: ("↩", "\r"), 76: ("⌅", "\u{3}"),
            49: (L10n.tr("Space"), " "), 48: ("⇥", "\t"), 51: ("⌫", "\u{8}"), 117: ("⌦", "\u{7f}"),
            123: ("←", "\u{F702}"), 124: ("→", "\u{F703}"), 125: ("↓", "\u{F701}"), 126: ("↑", "\u{F700}"),
            115: ("↖", "\u{F729}"), 119: ("↘", "\u{F72B}"),
            116: ("⇞", "\u{F72C}"), 121: ("⇟", "\u{F72D}")
        ]
        if let value = special[key] {
            return ShortcutPresentation(label: prefix + value.0, menuKeyEquivalent: value.1, menuModifierFlags: flags)
        }
        let functionKeys: [UInt32] = [
            122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90
        ]
        if let index = functionKeys.firstIndex(of: key), let scalar = UnicodeScalar(0xF704 + index) {
            return ShortcutPresentation(
                label: prefix + "F\(index + 1)", menuKeyEquivalent: String(scalar), menuModifierFlags: flags)
        }
        if let value = character(key, modifiers & UInt32(cmdKey)), ShortcutKeyboardLayout.isPrintableKey(value) {
            let uppercase = value.uppercased()
            let display = uppercase.count == 1 ? uppercase : value
            return ShortcutPresentation(label: prefix + display, menuKeyEquivalent: value, menuModifierFlags: flags)
        }
        // Unknown keys get an honest label and no guessed menu accelerator.
        return ShortcutPresentation(
            label: prefix + L10n.format("Key %ld", Int(key)), menuKeyEquivalent: "", menuModifierFlags: flags)
    }
}

enum ShortcutInputRouting {
    static func shouldDeferToInputMethod(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags, hasMarkedText: Bool
    ) -> Bool {
        hasMarkedText && modifiers.intersection([.command, .control, .option, .shift]).isEmpty
            && [UInt16(53), 36, 76].contains(keyCode)
    }

    @MainActor static func shouldDeferToInputMethod(_ event: NSEvent, firstResponder: NSResponder?) -> Bool {
        shouldDeferToInputMethod(
            keyCode: event.keyCode, modifiers: event.modifierFlags,
            hasMarkedText: (firstResponder as? NSTextInputClient)?.hasMarkedText() == true)
    }
}

// Carbon hotkeys are actions, not raw key codes. Keep their pressed/released
// edges separate so a held start chord cannot immediately finish a recording.
struct ShortcutEventEdges {
    private var keys: [UInt32: UInt32] = [:]
    private(set) var held: Set<UInt32> = []
    var isEmpty: Bool { held.isEmpty }
    mutating func configure(_ bindings: [(id: UInt32, key: UInt32)], isDown: (UInt32) -> Bool) {
        keys = Dictionary(uniqueKeysWithValues: bindings.map { ($0.id, $0.key) })
        held = Set(bindings.filter { isDown($0.key) }.map(\.id))
    }
    mutating func press(_ id: UInt32) -> Bool {
        guard keys[id] != nil else { return false }
        return held.insert(id).inserted
    }
    mutating func release(_ id: UInt32) { held.remove(id) }
    mutating func reconcile(isDown: (UInt32) -> Bool) { held = held.filter { keys[$0].map(isDown) == true } }
    mutating func clear() {
        keys.removeAll()
        held.removeAll()
    }
}

struct ShortcutRegistrationFailure: Equatable {
    enum Reason: Equatable {
        case handlerUnavailable, duplicateAction(UInt32), systemRejected, missingReference
    }
    let actionID: UInt32?
    let shortcut: Shortcut?
    let reason: Reason
    let status: OSStatus?
}

struct ShortcutRegistrationReport: Equatable {
    let failure: ShortcutRegistrationFailure?
    let restorationFailures: [ShortcutRegistrationFailure]
    let activeActionIDs: Set<UInt32>
    let intendedActionIDs: Set<UInt32>
    let restoredPreviousSet: Bool
    var succeeded: Bool { failure == nil }
    var inactiveIntendedActionIDs: Set<UInt32> { intendedActionIDs.subtracting(activeActionIDs) }
}

final class ShortcutRegistry {
    // Global action IDs: 1 show/hide, 2 selected text, 3 dictation, 4 voice
    // translation, 5 Scenario mode, 6 refine selected text. Titles are
    // localization keys.
    // Rows with their own keys: dictation shortcuts from 100, Refine in place from 200.
    static let dictationRowBase: UInt32 = 100
    static let refineRowBase: UInt32 = 200
    static let actionTitles: [UInt32: String] = [
        1: "Show / hide Yullo", 2: "Translate selected text", 3: "Start dictation", 4: "Start voice translation",
        5: "Temporary format", 6: "Refine selected text", 7: "Edit with voice",
        8: "Edit with text"
    ]
    static let editWithVoiceID: UInt32 = 7
    static let editWithTextID: UInt32 = 8
    // Actions whose key is kept with the row keys, by their saved key's ID. Every one is
    // registered with the row keys; a key listed in Settings and missing here never fires.
    static let keyedActions: [(id: UInt32, key: String)] = [
        (editWithVoiceID, Shortcut.editWithVoiceID), (editWithTextID, Shortcut.editWithTextID)
    ]
    // Where actions whose shortcut isn't available can still be chosen: Yullo's menu
    // in the menu bar, or, while that is hidden, the Yullo menu beside the Apple menu.
    static func unavailableNotice(_ ids: some Collection<UInt32>, menuBarItemVisible: Bool) -> String {
        let actions = ids.sorted().compactMap { actionTitles[$0] }.map(L10n.tr).joined(separator: L10n.listSeparator)
        return L10n.format(
            menuBarItemVisible
                ? "Some shortcuts aren’t available: %@. Click Yullo in the menu bar to use these actions."
                : "Some shortcuts aren’t available: %@. Open Yullo, then click the Yullo menu next to the Apple menu to use these actions.",
            actions)
    }
    private struct Binding {
        let id: UInt32
        let shortcut: Shortcut
    }
    private struct Registration {
        let binding: Binding
        let ref: EventHotKeyRef?
    }
    #if YULLO_TESTING
        struct Testing {
            var register: (UInt32, Shortcut) -> OSStatus
            var unregister: (UInt32) -> Void = { _ in }
            var isDown: (UInt32) -> Bool = { _ in false }
            var handlerStatus: OSStatus = noErr
        }
        private var testing: Testing?
        init(testing: Testing) {
            self.testing = testing
            handlerStatus = testing.handlerStatus
        }
        // A registered key pressed, as the system hands it over: through the same edges and action.
        func testPress(_ id: UInt32) {
            guard registrations.contains(where: { $0.binding.id == id }) else { return }
            receive(id: id, released: false)
        }
    #endif
    private var registrations: [Registration] = []
    var refs: [EventHotKeyRef] { registrations.compactMap(\.ref) }
    var handler: EventHandlerRef?
    var action: ((UInt32) -> Void)?
    private var handlerStatus: OSStatus = noErr
    private var intendedActionIDs = Set<UInt32>()
    private(set) var lastRegistrationReport = ShortcutRegistrationReport(
        failure: nil, restorationFailures: [], activeActionIDs: [], intendedActionIDs: [], restoredPreviousSet: true)
    private var edges = ShortcutEventEdges()
    private var releaseRecovery: Timer?
    deinit {
        clear()
        if let handler { RemoveEventHandler(handler) }
    }
    init() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                guard
                    GetEventParameter(
                        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                        MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                    id.signature == 0x474C5354
                else { return OSStatus(eventNotHandledErr) }
                Unmanaged<ShortcutRegistry>.fromOpaque(context).takeUnretainedValue()
                    .receive(id: id.id, released: GetEventKind(event) == UInt32(kEventHotKeyReleased))
                return noErr
            }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func clear() {
        clearRegistrations()
        intendedActionIDs = []
        lastRegistrationReport = ShortcutRegistrationReport(
            failure: nil, restorationFailures: [], activeActionIDs: [], intendedActionIDs: [], restoredPreviousSet: true
        )
    }
    private func clearRegistrations() {
        releaseRecovery?.invalidate()
        releaseRecovery = nil
        edges.clear()
        for registration in registrations {
            #if YULLO_TESTING
                if let testing {
                    testing.unregister(registration.binding.id)
                    continue
                }
            #endif
            if let ref = registration.ref { UnregisterEventHotKey(ref) }
        }
        registrations.removeAll()
    }
    func register(_ first: Shortcut, _ second: Shortcut, dictation: Shortcut? = nil, voiceTranslation: Shortcut? = nil)
        -> Bool
    {
        replace(first, second, dictation: dictation, voiceTranslation: voiceTranslation).succeeded
    }
    @discardableResult func replace(
        _ first: Shortcut, _ second: Shortcut, dictation: Shortcut? = nil, voiceTranslation: Shortcut? = nil,
        scenario: Shortcut? = nil, refineSelection: Shortcut? = nil, rows: [(id: UInt32, shortcut: Shortcut)] = []
    ) -> ShortcutRegistrationReport {
        let previous = registrations.map(\.binding)
        var bindings = [Binding(id: 1, shortcut: first), Binding(id: 2, shortcut: second)]
        bindings += rows.map { Binding(id: $0.id, shortcut: $0.shortcut) }
        if let dictation { bindings.append(Binding(id: 3, shortcut: dictation)) }
        if let voiceTranslation { bindings.append(Binding(id: 4, shortcut: voiceTranslation)) }
        if let scenario { bindings.append(Binding(id: 5, shortcut: scenario)) }
        if let refineSelection { bindings.append(Binding(id: 6, shortcut: refineSelection)) }
        bindings.removeAll { !$0.shortcut.isAssigned }
        intendedActionIDs = Set(bindings.map(\.id))
        // Detect local duplicates without taking a working set offline.
        for (index, binding) in bindings.enumerated() {
            if let duplicate = bindings.prefix(index).first(where: { $0.shortcut.conflicts(binding.shortcut) }) {
                return report(
                    failure: .init(
                        actionID: binding.id, shortcut: binding.shortcut, reason: .duplicateAction(duplicate.id),
                        status: nil),
                    restorationFailures: [], restoredPreviousSet: true)
            }
        }
        clearRegistrations()
        for binding in bindings {
            if let failure = install(binding) {
                clearRegistrations()
                // Restore each old action independently so a later action is
                // not lost merely because an earlier restoration failed.
                let restoration = previous.compactMap { install($0) }
                configureEdges()
                return report(
                    failure: failure, restorationFailures: restoration,
                    restoredPreviousSet: restoration.isEmpty && registrations.count == previous.count)
            }
        }
        configureEdges()
        return report(failure: nil, restorationFailures: [], restoredPreviousSet: false)
    }
    // Startup has no previous working set to roll back to. Keep each usable
    // action when another saved combination is owned by the system or an app.
    func registerAtStartup(
        _ first: Shortcut, _ second: Shortcut, dictation: Shortcut, voiceTranslation: Shortcut,
        scenario: Shortcut = .unassigned, refineSelection: Shortcut = .unassigned,
        rows: [(id: UInt32, shortcut: Shortcut)] = []
    ) -> ShortcutRegistrationReport {
        guard registrations.isEmpty else {
            return replace(
                first, second, dictation: dictation, voiceTranslation: voiceTranslation, scenario: scenario,
                refineSelection: refineSelection, rows: rows)
        }
        let bindings =
            ([
                Binding(id: 1, shortcut: first), Binding(id: 2, shortcut: second),
                Binding(id: 3, shortcut: dictation), Binding(id: 4, shortcut: voiceTranslation),
                Binding(id: 5, shortcut: scenario), Binding(id: 6, shortcut: refineSelection)
            ] + rows.map { Binding(id: $0.id, shortcut: $0.shortcut) })
            .filter { $0.shortcut.isAssigned }
        intendedActionIDs = Set(bindings.map(\.id))
        var firstFailure: ShortcutRegistrationFailure?
        for binding in bindings {
            let failure: ShortcutRegistrationFailure?
            if let duplicate = registrations.first(where: { $0.binding.shortcut.conflicts(binding.shortcut) }) {
                failure = .init(
                    actionID: binding.id, shortcut: binding.shortcut,
                    reason: .duplicateAction(duplicate.binding.id), status: nil)
            } else {
                failure = install(binding)
            }
            if firstFailure == nil { firstFailure = failure }
        }
        configureEdges()
        return report(failure: firstFailure, restorationFailures: [], restoredPreviousSet: false)
    }
    private func install(_ binding: Binding) -> ShortcutRegistrationFailure? {
        #if YULLO_TESTING
            if let testing {
                guard testing.handlerStatus == noErr else {
                    return .init(
                        actionID: binding.id, shortcut: binding.shortcut, reason: .handlerUnavailable,
                        status: testing.handlerStatus)
                }
                let status = testing.register(binding.id, binding.shortcut)
                guard status == noErr else {
                    return .init(
                        actionID: binding.id, shortcut: binding.shortcut, reason: .systemRejected, status: status)
                }
                registrations.append(Registration(binding: binding, ref: nil))
                return nil
            }
        #endif
        guard handler != nil else {
            return .init(
                actionID: binding.id, shortcut: binding.shortcut, reason: .handlerUnavailable, status: handlerStatus)
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.shortcut.key, binding.shortcut.modifiers,
            EventHotKeyID(signature: 0x474C5354, id: binding.id), GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            return .init(actionID: binding.id, shortcut: binding.shortcut, reason: .systemRejected, status: status)
        }
        guard let ref else {
            return .init(actionID: binding.id, shortcut: binding.shortcut, reason: .missingReference, status: status)
        }
        registrations.append(Registration(binding: binding, ref: ref))
        return nil
    }
    private func report(
        failure: ShortcutRegistrationFailure?, restorationFailures: [ShortcutRegistrationFailure],
        restoredPreviousSet: Bool
    ) -> ShortcutRegistrationReport {
        let value = ShortcutRegistrationReport(
            failure: failure, restorationFailures: restorationFailures,
            activeActionIDs: Set(registrations.map { $0.binding.id }), intendedActionIDs: intendedActionIDs,
            restoredPreviousSet: restoredPreviousSet)
        lastRegistrationReport = value
        return value
    }
    private func configureEdges() {
        edges.configure(registrations.map { (id: $0.binding.id, key: $0.binding.shortcut.key) }, isDown: isDown)
        if !edges.isEmpty { beginReleaseRecovery() }
    }
    private func receive(id: UInt32, released: Bool) {
        if released {
            edges.release(id)
            if edges.isEmpty {
                releaseRecovery?.invalidate()
                releaseRecovery = nil
            }
            return
        }
        guard edges.press(id) else { return }
        beginReleaseRecovery()
        action?(id)
    }
    private func beginReleaseRecovery() {
        guard releaseRecovery == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.edges.reconcile(isDown: self.isDown)
            if self.edges.isEmpty {
                self.releaseRecovery?.invalidate()
                self.releaseRecovery = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseRecovery = timer
    }
    private func isDown(_ key: UInt32) -> Bool {
        #if YULLO_TESTING
            if let testing { return testing.isDown(key) }
        #endif
        guard key <= UInt32(UInt16.max) else { return false }
        return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key))
            || CGEventSource.keyState(.hidSystemState, key: CGKeyCode(key))
    }
}

extension Shortcut {
    func matches(_ event: NSEvent) -> Bool {
        guard isAssigned else { return false }
        var flags: UInt32 = 0
        for (flag, carbon): (NSEvent.ModifierFlags, Int) in [
            (.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)
        ] {
            if event.modifierFlags.contains(flag) { flags |= UInt32(carbon) }
        }
        return key == UInt32(event.keyCode) && modifiers == flags
    }
}
extension Notification.Name {
    static let yulloRecordingShortcut = Notification.Name("yullo.recordingShortcut")
}
enum ShortcutRecorderInput {
    static func clearsBinding(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, allowed: Bool) -> Bool {
        allowed && [UInt16(51), 117].contains(keyCode)
            && modifiers.intersection([.command, .control, .option, .shift]).isEmpty
    }
}
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut
    var allowsEscape = false
    var allowsUnassigned = true
    var actionName = ""
    // An empty box shows this as a quiet placeholder and offers it when clicked.
    var suggestion: Shortcut? = nil
    final class KeyView: NSButton {
        var changed: ((Shortcut) -> Void)?
        var allowsEscape = false
        var allowsUnassigned = true { didSet { if oldValue != allowsUnassigned { refresh() } } }
        var actionName = "" { didSet { refresh() } }
        var current = "" { didSet { refresh() } }
        var shortcutValue: Shortcut? { didSet { current = shortcutValue?.displayLabel ?? current } }
        var suggestion: Shortcut? { didSet { if oldValue != suggestion { refresh() } } }
        private var isEmpty: Bool { shortcutValue?.isAssigned != true }
        private var layoutObserver: NSObjectProtocol?
        private(set) var recording = false
        override var acceptsFirstResponder: Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame)
            bezelStyle = .rounded
            setButtonType(.momentaryPushIn)
            font = .monospacedSystemFont(ofSize: 13, weight: .medium)
            target = self
            action = #selector(beginRecording)
            layoutObserver = DistributedNotificationCenter.default().addObserver(
                forName: ShortcutKeyboardLayout.didChange, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, let shortcut = self.shortcutValue else { return }
                self.current = shortcut.displayLabel
            }
        }
        deinit {
            if let layoutObserver { DistributedNotificationCenter.default().removeObserver(layoutObserver) }
        }
        required init?(coder: NSCoder) { fatalError() }
        @objc func clearShortcut() {
            guard allowsUnassigned else { return }
            changed?(.unassigned)
            shortcutValue = .unassigned
            finish()
        }
        @objc func beginRecording() {
            if recording {
                finish()
                return
            }
            if isEmpty, let suggestion {
                let menu = NSMenu()
                let use = menu.addItem(
                    withTitle: L10n.format("Use %@", suggestion.displayLabel), action: #selector(useSuggestion),
                    keyEquivalent: "")
                use.target = self
                let record = menu.addItem(
                    withTitle: L10n.tr("Record Shortcut…"), action: #selector(startRecording), keyEquivalent: "")
                record.target = self
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
                return
            }
            startRecording()
        }
        @objc func useSuggestion() {
            guard let suggestion else { return }
            changed?(suggestion)
            shortcutValue = suggestion
            refresh()
        }
        @objc func startRecording() {
            window?.makeFirstResponder(self)
            recording = true
            NotificationCenter.default.post(name: .yulloRecordingShortcut, object: true)
            refresh()
        }
        func finish() {
            guard recording else { return }
            recording = false
            NotificationCenter.default.post(name: .yulloRecordingShortcut, object: false)
            refresh()
        }
        func refresh() {
            // Only recording shows a focus ring; an empty box is a quiet dash, and its
            // suggestion is offered when clicked.
            focusRingType = recording ? .default : .none
            if recording {
                // A short prompt fits the box; the full instruction is in the accessibility label.
                title = L10n.tr("Keys…")
            } else if isEmpty {
                let centered = NSMutableParagraphStyle()
                centered.alignment = .center
                attributedTitle = NSAttributedString(
                    string: "—",
                    attributes: [
                        .font: font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                        .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: centered
                    ])
            } else {
                title = current
            }
            let recordingLabel = L10n.tr(
                allowsUnassigned
                    ? (allowsEscape
                        ? "Press a shortcut. Delete clears." : "Press a shortcut. Delete clears; Escape cancels.")
                    : (allowsEscape ? "Press shortcut…" : "Press a shortcut. Escape cancels."))
            let instruction = recording ? recordingLabel : L10n.format("Change shortcut, %@", current)
            setAccessibilityLabel(actionName.isEmpty ? instruction : actionName + ", " + instruction)
            toolTip = recordingLabel
            if allowsUnassigned {
                let menu = NSMenu()
                menu.autoenablesItems = false
                let clear = menu.addItem(
                    withTitle: L10n.tr("None"), action: #selector(clearShortcut), keyEquivalent: "")
                clear.target = self
                clear.isEnabled = shortcutValue?.isAssigned == true
                self.menu = menu
            } else {
                menu = nil
            }
        }
        override func resignFirstResponder() -> Bool {
            finish()
            return super.resignFirstResponder()
        }
        override func keyDown(with event: NSEvent) {
            guard recording else {
                super.keyDown(with: event)
                return
            }
            if ShortcutRecorderInput.clearsBinding(
                keyCode: event.keyCode, modifiers: event.modifierFlags, allowed: allowsUnassigned)
            {
                clearShortcut()
                return
            }
            if event.keyCode == 53 && !allowsEscape {
                finish()
                return
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard
                (allowsEscape && event.keyCode == 53) || flags.contains(.command) || flags.contains(.control)
                    || flags.contains(.option)
            else {
                NSSound.beep()
                return
            }
            var mods: UInt32 = 0
            for (flag, carbon): (NSEvent.ModifierFlags, Int) in [
                (.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)
            ] {
                if flags.contains(flag) { mods |= UInt32(carbon) }
            }
            var value = Shortcut(key: UInt32(event.keyCode), modifiers: mods, label: "")
            value.label = value.displayLabel
            changed?(value)
            finish()
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event)
            return true
        }
    }
    func makeNSView(context: Context) -> KeyView {
        let view = KeyView(frame: .zero)
        view.changed = { shortcut = $0 }
        return view
    }
    func updateNSView(_ view: KeyView, context: Context) {
        view.allowsEscape = allowsEscape
        view.allowsUnassigned = allowsUnassigned
        view.actionName = actionName
        view.shortcutValue = shortcut
        view.suggestion = suggestion
        view.changed = { shortcut = $0 }
    }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.finish() }
}
