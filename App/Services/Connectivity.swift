import Foundation
import Network

final class Connectivity {
    static let shared = Connectivity()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var offline = false
    var isOffline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return offline
    }
    private init() {
        // Test builds never read this Mac's network, so a result can't change with Wi-Fi.
        #if !YULLO_TESTING
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                self.lock.lock()
                self.offline = path.status != .satisfied
                self.lock.unlock()
            }
            monitor.start(queue: DispatchQueue(label: "yullo.connectivity"))
        #endif
    }
}
