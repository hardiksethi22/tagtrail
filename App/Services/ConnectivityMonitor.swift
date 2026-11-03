import Foundation
import Network

final class ConnectivityMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.tagtrail.connectivity")
    private let lock = NSLock()
    private var update: (@MainActor @Sendable (Bool) -> Void)?

    func start(update: @escaping @MainActor @Sendable (Bool) -> Void) {
        lock.lock()
        self.update = update
        lock.unlock()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            guard let self else { return }
            self.lock.lock()
            let callback = self.update
            self.lock.unlock()
            Task { @MainActor in callback?(available) }
        }
        monitor.start(queue: queue)
    }

    func stop() { monitor.cancel() }
}
