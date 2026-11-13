import Foundation
import Darwin

// Dispatch receives SIGTERM safely and schedules the app's normal quit action
// on the main run loop. No AppKit or asynchronous cleanup runs in a POSIX handler.
// The app retains this bridge for its lifetime; cancelling a quit leaves it live.
final class TerminationSignal {
    private let source: DispatchSourceSignal
    // SIG_DFL is represented by a nil function pointer in Darwin's Swift API.
    private let previousHandler: sig_t?

    init(onSignal: @escaping () -> Void) {
        source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        previousHandler = Darwin.signal(SIGTERM, SIG_IGN)
        source.setEventHandler {
            // AppKit's .terminateLater runs a nested loop. Entering it from the
            // main dispatch queue prevents MainActor cleanup tasks from running.
            RunLoop.main.perform(inModes: [.common], block: onSignal)
        }
        source.resume()
    }
    deinit {
        source.cancel()
        Darwin.signal(SIGTERM, previousHandler)
    }
}
