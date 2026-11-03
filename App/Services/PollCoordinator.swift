import Foundation
import TagTrailCore

actor PollCoordinator {
    private let clock: any TagTrailClock
    private var nextAccountRequestMS: Int64 = 0
    private var running = false
    private var pausedForAuthentication = false
    private var pausedDevices = Set<String>()
    private var retryCount: [String: Int] = [:]
    private var suspended = false
    private let jitter: @Sendable (Int64) -> Int64

    init(clock: any TagTrailClock = SystemTagTrailClock(), jitter: @escaping @Sendable (Int64) -> Int64 = { Int64.random(in: 0...$0) }) {
        self.clock = clock
        self.jitter = jitter
    }

    func poll(
        device: TrackerDevice,
        provider: any TrackerProvider,
        database: Database,
        manual: Bool
    ) async throws -> PollOutcome {
        guard !running else { throw ProviderFailure.rateLimited(until: Date(timeIntervalSince1970: Double(nextAccountRequestMS) / 1000)) }
        guard !suspended else { throw CancellationError() }
        guard !pausedForAuthentication else { throw ProviderFailure.authenticationRequired }
        guard !pausedDevices.contains(device.id) else { throw ProviderFailure.unsupportedDevice }
        let nowMS = Int64(clock.now.timeIntervalSince1970 * 1000)
        if nowMS < nextAccountRequestMS {
            throw ProviderFailure.rateLimited(until: Date(timeIntervalSince1970: Double(nextAccountRequestMS) / 1000))
        }
        running = true
        defer { running = false }
        let attemptMS = nowMS
        nextAccountRequestMS = attemptMS + 60_000
        try await database.setSetting(key: "account.not_before_ms", value: String(nextAccountRequestMS))
        try Task.checkCancellation()
        let report: ProviderPollResult
        do {
            report = try await provider.poll(device: device)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let completedMS = Int64(clock.now.timeIntervalSince1970 * 1000)
            let failure = error as? ProviderFailure ?? .internalError
            if case .authenticationRequired = failure { pausedForAuthentication = true }
            if case .credentialsLocked = failure { pausedForAuthentication = true }
            if case .unsupportedDevice = failure { pausedDevices.insert(device.id) }
            if case .rateLimited(let until) = failure, let until {
                nextAccountRequestMS = max(completedMS + 60_000, Int64(until.timeIntervalSince1970 * 1000))
            } else {
                let count = min((retryCount[device.id] ?? 0) + 1, 10)
                retryCount[device.id] = count
                let base = min(Int64(3_600_000), 60_000 * (1 << min(count - 1, 6)))
                let maximumJitter = max(0, min(base / 5, 3_600_000 - base))
                nextAccountRequestMS = completedMS + base + max(0, min(maximumJitter, jitter(maximumJitter)))
            }
            try await database.recordPoll(
                deviceID: device.id, attemptMS: attemptMS, completedMS: completedMS,
                classification: "error", insertedCount: 0, errorCode: failure.stateCode
            )
            try await database.setSetting(key: "account.not_before_ms", value: String(nextAccountRequestMS))
            throw failure
        }
        let inserted = try await database.ingest(report.sightings)
        let completedMS = Int64(clock.now.timeIntervalSince1970 * 1000)
        nextAccountRequestMS = completedMS + 60_000
        retryCount[device.id] = 0
        try await database.recordPoll(
            deviceID: device.id, attemptMS: attemptMS, completedMS: completedMS,
            classification: report.rejectedCount > 0 ? "partial-validity" : (inserted == 0 ? "no-new-data" : "success"),
            insertedCount: inserted, errorCode: nil
        )
        try await database.setSetting(key: "account.not_before_ms", value: String(nextAccountRequestMS))
        return PollOutcome(insertedCount: inserted, rejectedCount: report.rejectedCount)
    }

    struct PollOutcome: Sendable {
        let insertedCount: Int
        let rejectedCount: Int
    }

    func restoreCooldown(from database: Database) async throws {
        if let saved = try await database.setting(key: "account.not_before_ms"),
           let timestamp = Int64(saved) {
            nextAccountRequestMS = timestamp
        }
    }

    func remainingCooldownMS() -> Int64 {
        max(0, nextAccountRequestMS - Int64(clock.now.timeIntervalSince1970 * 1000))
    }

    func authenticationRepaired() { pausedForAuthentication = false }
    func setSuspended(_ suspended: Bool) { self.suspended = suspended }

    func isDevicePaused(_ deviceID: String) -> Bool { pausedDevices.contains(deviceID) }

    func isAuthenticationPaused() -> Bool { pausedForAuthentication }

    func resumeDevice(_ deviceID: String) { pausedDevices.remove(deviceID) }
}
