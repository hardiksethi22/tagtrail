import Foundation

protocol TagTrailClock: Sendable {
    var now: Date { get }
    func sleep(for duration: Duration) async throws
}

struct SystemTagTrailClock: TagTrailClock {
    var now: Date { Date() }
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}
