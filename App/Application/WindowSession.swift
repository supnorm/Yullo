import Combine
import Foundation

/// Temporary behavior for the current translator window, never a saved preference.
final class WindowSession: ObservableObject {
    enum Surface { case main, selection }
    struct QuickReturnTicket: Equatable {
        let id: UUID
        let surface: Surface
        let deadline: ContinuousClock.Instant
    }

    @Published private(set) var isPinned = false
    var didChange: (() -> Void)?
    private let now: () -> ContinuousClock.Instant
    private var quickReturn: QuickReturnTicket?

    init(now: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now }) {
        self.now = now
    }

    // The window owns only a deadline and identity; text remains with Model.
    @discardableResult
    func armQuickReturn(surface: Surface) -> QuickReturnTicket {
        let ticket = QuickReturnTicket(id: UUID(), surface: surface, deadline: now().advanced(by: .seconds(30)))
        quickReturn = ticket
        return ticket
    }

    var hasPendingQuickReturn: Bool {
        quickReturn.map { now() < $0.deadline } ?? false
    }

    func consumeQuickReturn() -> Surface? {
        guard let ticket = quickReturn else { return nil }
        quickReturn = nil
        return now() < ticket.deadline ? ticket.surface : nil
    }

    func clearQuickReturn() { quickReturn = nil }

    @discardableResult
    func expireQuickReturn(id: UUID) -> Bool {
        guard let ticket = quickReturn, ticket.id == id, now() >= ticket.deadline else { return false }
        quickReturn = nil
        return true
    }

    func togglePin() {
        isPinned.toggle()
        didChange?()
    }

    func resetPin() {
        guard isPinned else { return }
        isPinned = false
        didChange?()
    }
}
