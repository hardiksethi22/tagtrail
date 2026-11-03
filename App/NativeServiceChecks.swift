import Foundation
import TagTrailCore

enum NativeServiceChecks {
    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TagTrail-SelfTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try await transport(directory: directory)
            try await scheduling(directory: directory)
            try FileManager.default.removeItem(at: directory)
        } catch {
            try FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func require(_ value: Bool, _ code: String) throws {
        guard value else { throw DataError.database(code) }
    }

    private static func transport(directory: URL) async throws {
        func client(_ body: String) -> WorkerProcessClient {
            let prefix = """
            read -r request
            id=$(printf '%s' "$request" | /usr/bin/sed -n 's/.*"request_id":"\\([^"]*\\)".*/\\1/p')
            """
            return WorkerProcessClient(workingDirectory: directory, executableURL: URL(fileURLWithPath: "/bin/sh"),
                                       arguments: ["-c", prefix + "\n" + body])
        }
        let result = #"printf '{"protocol_version":1,"request_id":"%s","event":"result","payload":{}}\n' "$id""#
        let split = #"printf '{"protocol_version":1,"request_id":"%s","event":"res' "$id"; printf 'ult","payload":{"name":"Cl'; printf '\303'; /bin/sleep 0.02; printf '\251s"}}\n'"#
        let events = try await client(split).request(WorkerRequest(command: .doctor, timeoutMS: 1_000), hardTimeout: .seconds(3))
        let payload = try JSONSerialization.jsonObject(with: events[0].payload) as? [String: String]
        try require(payload?["name"] == "Clés", "split-utf8")
        let stderr = #" /usr/bin/awk 'BEGIN { for(i=0;i<20000;i++) print "sanitized fixture stderr" }' >&2; "# + result
        _ = try await client(stderr).request(WorkerRequest(command: .doctor, timeoutMS: 1_000), hardTimeout: .seconds(5))
        let failures: [(String, WorkerTransportError, Duration)] = [
            ("exit 0", .missingTerminal, .seconds(3)),
            (result + "; exit 7", .failedExit, .seconds(3)),
            (#"printf '{"protocol_version":1,"request_id":"%s","event":"result","payload":{}}' "$id""#, .malformedOutput, .seconds(3)),
            (#"printf '{"protocol_version":2,"request_id":"%s","event":"result","payload":{}}\n' "$id""#, .malformedOutput, .seconds(3)),
            (#"/usr/bin/awk 'BEGIN { for(i=0;i<1048577;i++) printf "x"; printf "\n" }'"#, .outputLimit, .seconds(5)),
            (#"/usr/bin/awk 'BEGIN { for(i=0;i<9000000;i++) printf "x" }' >&2; "# + result, .outputLimit, .seconds(10)),
            (#"/usr/bin/awk -v id="$id" 'BEGIN { for(i=0;i<110000;i++) printf "{\"protocol_version\":1,\"request_id\":\"%s\",\"event\":\"progress\",\"payload\":{}}\n", id }'; "# + result, .outputLimit, .seconds(10)),
            ("exec /bin/sleep 30", .timeout, .milliseconds(100))
        ]
        for (body, expected, deadline) in failures {
            do {
                _ = try await client(body).request(WorkerRequest(command: .doctor, timeoutMS: 1_000), hardTimeout: deadline)
                throw DataError.database("transport-expected-failure")
            } catch let error as WorkerTransportError {
                try require(error == expected, "transport-classification")
            }
        }
        let task = Task {
            try await client("exec /bin/sleep 30").request(WorkerRequest(command: .doctor, timeoutMS: 30_000), hardTimeout: .seconds(30))
        }
        try await Task.sleep(for: .milliseconds(100))
        let start = Date()
        task.cancel()
        do {
            _ = try await task.value
            throw DataError.database("transport-cancellation")
        } catch WorkerTransportError.cancelled {
        } catch is CancellationError {}
        try require(Date().timeIntervalSince(start) < 3, "transport-cancel-bound")
        let shared = client("exec /bin/sleep 30")
        let active = Task { try await shared.request(WorkerRequest(command: .doctor, timeoutMS: 30_000), hardTimeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(200))
        let queued = Task { try await shared.request(WorkerRequest(command: .doctor, timeoutMS: 30_000), hardTimeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(200))
        let queuedStart = Date()
        queued.cancel()
        do {
            _ = try await queued.value
            throw DataError.database("queued-cancellation-expected")
        } catch is CancellationError {}
        try require(Date().timeIntervalSince(queuedStart) < 2, "queued-cancel-does-not-wait-for-active-operation")
        active.cancel()
        _ = try? await active.value
        do {
            let update = #"printf '{"protocol_version":1,"request_id":"%s","event":"credential_update","credential_bundle":{"username":"fixture@example.invalid"}}\n' "$id"; "# + result
            _ = try await client(update).request(WorkerRequest(command: .doctor, timeoutMS: 1_000), hardTimeout: .seconds(3)) { _ in
                throw CredentialStoreError.invalidBundle
            }
            throw DataError.database("credential-persistence-must-fail")
        } catch CredentialStoreError.invalidBundle {}
    }

    private static func scheduling(directory: URL) async throws {
        let clock = CheckClock()
        let database = try await DatabaseOpener.open(url: directory.appendingPathComponent("checks.sqlite"))
        try await database.upsertProfile(id: "checks", provider: "fixture", label: "Checks")
        var devices = (0..<7).map {
            TrackerDevice(id: "device-\($0)", profileID: "checks", canonicID: "device-\($0)",
                          name: "Fixture \($0)", network: "fixture", trackingEnabled: true)
        }
        for device in devices { try await database.upsertDevice(device) }
        let normalized: [[String: Any]] = [
            ["device_id": devices[0].canonicID, "kind": "geographic", "latitude": 0, "longitude": 0,
             "timestamp_provenance": "unknown", "source": "fixture"],
            ["device_id": devices[0].canonicID, "kind": "geographic", "latitude": 91, "longitude": 0,
             "timestamp_provenance": "unknown", "source": "fixture"]
        ]
        let mixed = try GoogleTrackerProvider.normalizedPoll(
            payload: JSONSerialization.data(withJSONObject: ["sightings": normalized, "rejected_count": 1]),
            device: devices[0], ingestedAtMS: clock.ms)
        try require(mixed.sightings.count == 1 && mixed.rejectedCount == 2, "mixed-validity-preserves-valid-rows")
        let inserted = try await database.ingest(mixed.sightings)
        try require(inserted == 1, "mixed-validity-ingestion")
        let malformed: [[String: Any]] = [normalized[0], ["device_id": devices[0].canonicID, "latitude": "bad"]]
        let lossy = try GoogleTrackerProvider.normalizedPoll(
            payload: JSONSerialization.data(withJSONObject: ["sightings": malformed, "rejected_count": 0]),
            device: devices[0], ingestedAtMS: clock.ms)
        try require(lossy.sightings.count == 1 && lossy.rejectedCount == 1, "structurally-malformed-sighting-retains-valid-rows")
        let coordinator = PollCoordinator(clock: clock, jitter: { _ in 0 })
        var served = Set<String>()
        for _ in 0..<7 {
            let candidates = SchedulingPolicy.eligibleDevices(devices, nowMS: clock.ms, intervalMinutes: 5)
            guard let device = candidates.first else { throw DataError.database("fairness-candidate") }
            served.insert(device.id)
            _ = try await coordinator.poll(device: device, provider: CheckProvider(), database: database, manual: false)
            devices = try await database.devices(profileID: "checks")
            clock.advance(60)
        }
        try require(served.count == 7, "scheduler-fairness")
        try require(SchedulingPolicy.eligibleDevices(devices, nowMS: clock.ms, intervalMinutes: 0).isEmpty, "scheduler-off")
        guard let last = devices.last, let lastAttempt = last.lastAttemptMS else {
            throw DataError.database("scheduler-last-attempt")
        }
        let minimum = SchedulingPolicy.eligibleDevices([last], nowMS: lastAttempt + 299_999, intervalMinutes: 1)
        try require(minimum.isEmpty, "scheduler-five-minute-minimum")
        let restored = PollCoordinator(clock: clock, jitter: { _ in 0 })
        clock.advance(-60)
        try await restored.restoreCooldown(from: database)
        try require(await restored.remainingCooldownMS() == 60_000, "restart-cooldown")
        clock.advance(60)
        let backoff = PollCoordinator(clock: clock, jitter: { _ in 0 })
        for exponent in 0..<8 {
            do {
                _ = try await backoff.poll(device: devices[0], provider: CheckProvider(failure: .networkUnavailable), database: database, manual: true)
                throw DataError.database("backoff-expected-error")
            } catch ProviderFailure.networkUnavailable {}
            let delay = await backoff.remainingCooldownMS()
            try require(delay == min(3_600_000, 60_000 * (1 << min(exponent, 6))), "backoff-exponential-cap")
            clock.advance(Double(delay) / 1_000)
        }
        let rateLimited = PollCoordinator(clock: clock, jitter: { _ in 0 })
        do {
            _ = try await rateLimited.poll(device: devices[0], provider: CheckProvider(failure: .rateLimited(until: clock.now.addingTimeInterval(600))),
                                          database: database, manual: true)
        } catch ProviderFailure.rateLimited {}
        try require(await rateLimited.remainingCooldownMS() == 600_000, "retry-after")
        let jittered = PollCoordinator(clock: clock, jitter: { $0 })
        do {
            _ = try await jittered.poll(device: devices[0], provider: CheckProvider(failure: .networkUnavailable), database: database, manual: true)
        } catch ProviderFailure.networkUnavailable {}
        try require(await jittered.remainingCooldownMS() == 72_000, "backoff-jitter-range")
        let locked = PollCoordinator(clock: clock)
        do {
            _ = try await locked.poll(device: devices[0], provider: CheckProvider(failure: .credentialsLocked), database: database, manual: true)
        } catch ProviderFailure.credentialsLocked {}
        try require(await locked.isAuthenticationPaused(), "keychain-lock-pauses-account")
        let authentication = PollCoordinator(clock: clock, jitter: { _ in 0 })
        do {
            _ = try await authentication.poll(device: devices[0], provider: CheckProvider(failure: .authenticationRequired), database: database, manual: true)
        } catch ProviderFailure.authenticationRequired {}
        clock.advance(3_600)
        try require(await authentication.isAuthenticationPaused(), "auth-paused")
        do {
            _ = try await authentication.poll(device: devices[0], provider: CheckProvider(), database: database, manual: true)
            throw DataError.database("auth-must-not-retry")
        } catch ProviderFailure.authenticationRequired {}
        await authentication.authenticationRepaired()
        await authentication.setSuspended(true)
        do {
            _ = try await authentication.poll(device: devices[0], provider: CheckProvider(), database: database, manual: false)
            throw DataError.database("sleep-must-not-poll")
        } catch is CancellationError {}
        await authentication.setSuspended(false)
        _ = try await authentication.poll(device: devices[0], provider: CheckProvider(), database: database, manual: false)
        do {
            _ = try await authentication.poll(device: devices[1], provider: CheckProvider(), database: database, manual: false)
            throw DataError.database("wake-must-not-replay-backlog")
        } catch ProviderFailure.rateLimited {}
    }
}

private final class CheckClock: TagTrailClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return instant }
    var ms: Int64 { Int64(now.timeIntervalSince1970 * 1_000) }
    func advance(_ seconds: Double) { lock.lock(); instant.addTimeInterval(seconds); lock.unlock() }
    func sleep(for duration: Duration) async throws { try Task.checkCancellation() }
}

private struct CheckProvider: TrackerProvider {
    var failure: ProviderFailure? = nil
    var displayName: String { "Fixture" }
    func authenticate(using browser: BrowserAuthentication?) async throws {}
    func discover() async throws -> [ProviderDevice] { [] }
    func poll(device: TrackerDevice) async throws -> ProviderPollResult {
        if let failure { throw failure }
        return ProviderPollResult(sightings: [], rejectedCount: 0)
    }
}
