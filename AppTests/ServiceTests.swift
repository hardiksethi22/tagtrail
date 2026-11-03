import Foundation
#if canImport(XCTest)
import XCTest
#endif
import TagTrailCore
@testable import TagTrail
final class ServiceTests: XCTestCase {
    private var directory: URL!
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TagTrail-AppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testDemoIsClockAnchoredAndSeparateFromLive() async throws {
        let clock = TestClock(now: epoch)
        let provider = DemoProvider(clock: clock)
        let database = try Database(url: directory.appendingPathComponent("demo.sqlite"))
        let live = try Database(url: directory.appendingPathComponent("live.sqlite"))
        try await database.upsertProfile(id: "demo", provider: "demo", label: "Demo")
        let discovered = try await provider.discover()
        XCTAssertEqual(discovered.count, 2)
        for discovery in discovered {
            let device = TrackerDevice(id: discovery.canonicID, profileID: "demo", canonicID: discovery.canonicID,
                                       name: discovery.name, network: discovery.network, trackingEnabled: true)
            try await database.upsertDevice(device)
            let batch = try await provider.poll(device: device)
            XCTAssertEqual(batch.rejectedCount, 0)
            XCTAssertFalse(batch.sightings.isEmpty)
            let nowMS = Int64(epoch.timeIntervalSince1970 * 1000)
            XCTAssertTrue(batch.sightings.allSatisfy {
                $0.effectiveTimeMS <= nowMS && $0.effectiveTimeMS > nowMS - 86_400_000
                    && $0.deviceID == device.id && $0.source == "demo fixture"
            })
            let inserted = try await database.ingest(batch.sightings)
            let repeated = try await database.ingest(batch.sightings)
            XCTAssertEqual(inserted, batch.sightings.count)
            XCTAssertEqual(repeated, 0)
            let observations = try await database.observations(deviceID: device.id, sinceMS: nowMS - 86_400_000)
            XCTAssertEqual(observations.count, batch.sightings.count)
        }
        let liveDevices = try await live.devices(profileID: "demo")
        XCTAssertTrue(liveDevices.isEmpty)
    }

    func testCooldownIncludesManualPollsAndSurvivesCoordinatorRestart() async throws {
        let clock = TestClock(now: epoch)
        let (database, device) = try await makeDevice()
        let provider = RecordingProvider()
        let coordinator = PollCoordinator(clock: clock)
        let first = try await coordinator.poll(device: device, provider: provider, database: database, manual: true)
        XCTAssertEqual(first.insertedCount, 0)
        let cooldown = await coordinator.remainingCooldownMS()
        XCTAssertEqual(cooldown, 60_000)
        do {
            _ = try await coordinator.poll(device: device, provider: provider, database: database, manual: true)
            XCTFail("A second account locate must be rejected during cooldown.")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.stateCode, "rate-limited")
        }
        let restored = PollCoordinator(clock: clock)
        try await restored.restoreCooldown(from: database)
        let restoredCooldown = await restored.remainingCooldownMS()
        XCTAssertEqual(restoredCooldown, 60_000)
        clock.advance(seconds: 60)
        _ = try await restored.poll(device: device, provider: provider, database: database, manual: false)
        let calls = await provider.pollCount
        XCTAssertEqual(calls, 2)
    }

    func testCredentialLockPausesAccountUntilExplicitRepair() async throws {
        let clock = TestClock(now: epoch)
        let (database, device) = try await makeDevice()
        let provider = RecordingProvider(failure: .credentialsLocked)
        let coordinator = PollCoordinator(clock: clock)
        do {
            _ = try await coordinator.poll(device: device, provider: provider, database: database, manual: false)
            XCTFail("Expected locked credentials.")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.stateCode, "credentials-locked")
        }
        clock.advance(seconds: 3_600)
        do {
            _ = try await coordinator.poll(device: device, provider: provider, database: database, manual: true)
            XCTFail("A paused account must not retry its provider.")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.stateCode, "authentication-required")
        }
        let calls = await provider.pollCount
        XCTAssertEqual(calls, 1)
        await coordinator.authenticationRepaired()
        let paused = await coordinator.isAuthenticationPaused()
        XCTAssertFalse(paused)
    }

    func testUnsupportedDeviceDoesNotPauseOtherDevices() async throws {
        let clock = TestClock(now: epoch)
        let (database, device) = try await makeDevice()
        let coordinator = PollCoordinator(clock: clock)
        do {
            _ = try await coordinator.poll(device: device, provider: RecordingProvider(failure: .unsupportedDevice),
                                           database: database, manual: false)
            XCTFail("Expected unsupported device.")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.stateCode, "unsupported-device")
        }
        let pausedDevice = await coordinator.isDevicePaused(device.id)
        let pausedAccount = await coordinator.isAuthenticationPaused()
        XCTAssertTrue(pausedDevice)
        XCTAssertFalse(pausedAccount)
        clock.advance(seconds: 3_600)
        let other = TrackerDevice(id: "other", profileID: "test", canonicID: "other", name: "Other", network: "fixture", trackingEnabled: true)
        try await database.upsertDevice(other)
        _ = try await coordinator.poll(device: other, provider: RecordingProvider(), database: database, manual: false)
    }

    func testGeocoderUsesLabelsWithoutNetworkAndCachesByCoordinateAndLocale() async throws {
        let (database, device) = try await makeDevice()
        let geocoder = RecordingGeocoder(result: GeocodedAddress(shortLabel: "Fixture address", fullAddress: "Fixture full address"))
        let service = GeocodingService(database: database, geocoder: geocoder, clock: TestClock(now: epoch))
        let geographic = observation(deviceID: device.id)
        let disabled = try await service.address(for: geographic, enabled: false, demo: false)
        let demo = try await service.address(for: geographic, enabled: true, demo: true)
        XCTAssertNil(disabled)
        XCTAssertNil(demo)
        let semantic = Sighting(id: "semantic", deviceID: device.id, kind: .semantic,
                                timestampProvenance: "unknown", ingestedAtMS: 1,
                                semanticLabel: "Home", source: "fixture")
        let label = try await service.address(for: semantic, enabled: true, demo: false)
        XCTAssertEqual(label, "Home")
        let resolved = try await service.address(for: geographic, enabled: true, demo: false)
        let cached = try await service.address(for: geographic, enabled: true, demo: false)
        XCTAssertEqual(resolved, "Fixture address")
        XCTAssertEqual(cached, "Fixture address")
        let calls = await geocoder.calls
        XCTAssertEqual(calls, 1)
        let entry = try await database.geocode(key: GeocodingService.cacheKey(latitude: 0, longitude: 0), locale: Locale.current.identifier)
        XCTAssertEqual(entry?.status, "resolved")
        XCTAssertEqual(entry?.fullAddress, "Fixture full address")
    }

    func testNoGeocodeResultIsNegativelyCached() async throws {
        let (database, device) = try await makeDevice()
        let clock = TestClock(now: epoch)
        let geocoder = RecordingGeocoder(result: nil)
        let service = GeocodingService(database: database, geocoder: geocoder, clock: clock)
        let first = try await service.address(for: observation(deviceID: device.id), enabled: true, demo: false)
        clock.advance(seconds: 120)
        let repeated = try await service.address(for: observation(deviceID: device.id), enabled: true, demo: false)
        XCTAssertNil(first)
        XCTAssertNil(repeated)
        let calls = await geocoder.calls
        XCTAssertEqual(calls, 1)
    }

    func testImportRejectsPartialOversizeAndMalformedCredentials() throws {
        for data in [Data("{}".utf8), Data("not-json".utf8), Data(repeating: 32, count: 512 * 1024 + 1),
                     try JSONSerialization.data(withJSONObject: ["username": "fixture@example.invalid", "aas_token": "fixture"])] {
            XCTAssertThrowsError(try KeychainCredentialStore.validate(data))
        }
        let partial = try JSONSerialization.data(withJSONObject: ["username": "fixture@example.invalid"])
        XCTAssertNoThrow(try KeychainCredentialStore.validateWorkerUpdate(partial))
        for object: [String: Any] in [["username": 42], ["aas_token": ""], ["owner_key": "bad"], ["unrecognized": "fixture"]] {
            XCTAssertThrowsError(try KeychainCredentialStore.validateWorkerUpdate(JSONSerialization.data(withJSONObject: object)))
        }
    }

    func testWorkerRequestKeepsCredentialsInNDJSONAndUsesContractKeys() throws {
        let credentials = try JSONSerialization.data(withJSONObject: ["username": "fixture@example.invalid"])
        let request = WorkerRequest(command: .poll, timeoutMS: 45_000, credentialBundle: credentials, deviceID: "fixture-device")
        let line = try request.encodedLine()
        XCTAssertEqual(line.last, 10)
        XCTAssertEqual(line.filter { $0 == 10 }.count, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["protocol_version", "request_id", "command", "timeout_ms", "credential_bundle", "device_id"])
        XCTAssertEqual(object["protocol_version"] as? Int, 1)
        XCTAssertEqual(object["request_id"] as? String, request.requestID)
        XCTAssertEqual(object["command"] as? String, "poll")
        XCTAssertEqual(object["timeout_ms"] as? Int, 45_000)
        XCTAssertEqual(object["device_id"] as? String, "fixture-device")
        XCTAssertThrowsError(try WorkerRequest(command: .authenticate, timeoutMS: 300_000, credentialBundle: Data("[]".utf8)).encodedLine())
    }

    func testWorkerParserAcceptsUnicodeAndBothCredentialEnvelopeShapes() throws {
        for update in [
            ["payload": ["credential_bundle": ["username": "fixture@example.invalid"]]],
            ["credential_bundle": ["username": "fixture@example.invalid"]]
        ] {
            let stream = try event("ready", payload: [:]) + event("credential_update", fields: update)
                + event("result", payload: ["devices": [["id": "fixture", "name": "Clés", "network": "fixture"]]])
            let parsed = try WorkerProcessClient.parse(stream, requestID: "fixture", maxLineBytes: 1_048_576)
            XCTAssertEqual(parsed.map(\.name), ["ready", "result"])
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: parsed[1].payload) as? [String: Any])
            let devices = try XCTUnwrap(result["devices"] as? [[String: String]])
            XCTAssertEqual(devices.first?["name"], "Clés")
        }
    }

    func testWorkerParserRejectsBadVersionIdentityEOFAndPostTerminalEvents() throws {
        let result = try event("result", payload: [:])
        let ready = try event("ready", payload: [:])
        let progress = try event("progress", payload: [:])
        let update = try event("credential_update", fields: ["credential_bundle": ["username": "fixture"]])
        let invalidStreams = [
            Data(), ready, Data(result.dropLast()), result + result, result + progress, result + update,
            Data("\n".utf8) + result, Data("{invalid}\n".utf8),
            try event("result", fields: ["payload": [:], "protocol_version": 2]),
            try event("result", fields: ["payload": [:], "protocol_version": true]),
            try event("result", fields: ["payload": [:], "request_id": "another-request"]),
            try event("unknown", payload: [:]),
            try event("auth_challenge", payload: [:]),
            try event("result", fields: [:])
        ]
        for data in invalidStreams {
            XCTAssertThrowsError(try WorkerProcessClient.parse(data, requestID: "fixture", maxLineBytes: 1_048_576))
        }
        XCTAssertThrowsError(try WorkerProcessClient.parse(result, requestID: "fixture", maxLineBytes: 8))
    }

    func testWorkerParserPreservesMachineReadableFailureClassification() throws {
        for code in ["authentication-required", "credentials-locked", "unsupported-device", "network-unavailable",
                     "timeout", "decryption-error", "protocol-error", "internal-error", "rate-limited"] {
            let data = try event("error", fields: ["code": code, "retry_after_ms": 120_000])
            do {
                _ = try WorkerProcessClient.parse(data, requestID: "fixture", maxLineBytes: 1_048_576)
                XCTFail("A terminal provider error must throw.")
            } catch let failure as ProviderFailure {
                XCTAssertEqual(failure.stateCode, code)
                if case .rateLimited(let until) = failure {
                    let date = try XCTUnwrap(until)
                    XCTAssertTrue(date.timeIntervalSinceNow > 115)
                }
            }
        }
    }

    func testLatestDisplayAndExportPaginationPreserveNewestAndAllRawRows() async throws {
        let (database, device) = try await makeDevice()
        let rows = (0..<10_005).map { index in
            Sighting(id: "page-\(index)", deviceID: device.id, reportID: "page-report-\(index)",
                     kind: .geographic, latitude: 0, longitude: 0, providerTimestampMS: Int64(index + 1),
                     timestampProvenance: "fixture", ingestedAtMS: 20_000, source: "fixture")
        }
        let inserted = try await database.ingest(rows)
        XCTAssertEqual(inserted, rows.count)
        let display = try await database.latestObservations(deviceID: device.id, limit: ObservationHistory.displayLimit)
        XCTAssertEqual(display.count, 1_000)
        XCTAssertEqual(display.first?.providerTimestampMS, 9_006)
        XCTAssertEqual(display.last?.providerTimestampMS, 10_005)
        let latest = try await database.latestObservations(deviceID: device.id, limit: 1)
        XCTAssertEqual(latest.first?.id, rows.last?.id)
        let exported = try await ObservationHistory.exportRows(database: database, deviceID: device.id, sinceMS: nil)
        XCTAssertEqual(exported.map(\.id), rows.map(\.id))
        let filtered = try await ObservationHistory.exportRows(database: database, deviceID: device.id, sinceMS: 10_000)
        XCTAssertEqual(filtered.count, 6)
        XCTAssertEqual(filtered.first?.providerTimestampMS, 10_000)
    }

    func testSemanticMappingUsesCorePersistenceWithoutChangingRawEvidence() async throws {
        let (database, device) = try await makeDevice()
        let semantic = Sighting(id: "semantic-raw", deviceID: device.id, kind: .semantic,
                                timestampProvenance: "unknown", ingestedAtMS: 1, semanticLabel: "Home", source: "fixture")
        _ = try await database.ingest([semantic])
        try await database.saveSemanticPlace(id: "place", profileID: device.profileID, deviceID: device.id,
                                             label: "Home", latitude: 0, longitude: 0)
        let places = try await database.semanticPlaces(profileID: device.profileID, deviceID: device.id)
        XCTAssertEqual(places.count, 1)
        XCTAssertEqual(places.first?.label, "Home")
        XCTAssertEqual(places.first?.latitude, 0)
        let raw = try await database.latestObservations(deviceID: device.id, limit: 1)
        XCTAssertNil(raw.first?.latitude)
        XCTAssertNil(raw.first?.longitude)
        try await database.deleteSemanticPlace(id: "place")
        let remaining = try await database.semanticPlaces(profileID: device.profileID, deviceID: device.id)
        XCTAssertTrue(remaining.isEmpty)
        let preserved = try await database.observations(deviceID: device.id)
        XCTAssertEqual(preserved.count, 1)
    }

    func testActualWorkerPipesBoundEOFNonzeroOverflowTimeoutAndCancellation() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("worker-fixture.sh")
        func client(_ mode: String) -> WorkerProcessClient {
            WorkerProcessClient(workingDirectory: directory, executableURL: URL(fileURLWithPath: "/bin/sh"),
                                arguments: [fixture.path, mode])
        }
        let success = try await client("success").request(WorkerRequest(command: .doctor, timeoutMS: 1_000), hardTimeout: .seconds(2))
        XCTAssertEqual(success.map(\.name), ["ready", "result"])
        for (mode, expected): (String, WorkerTransportError) in [
            ("eof", .malformedOutput), ("nonzero", .failedExit), ("overflow", .outputLimit), ("stall", .timeout)
        ] {
            do {
                _ = try await client(mode).request(WorkerRequest(command: .doctor, timeoutMS: 1_000),
                                                   hardTimeout: mode == "stall" ? .milliseconds(250) : .seconds(5))
                XCTFail("Expected \(mode) failure.")
            } catch let failure as WorkerTransportError {
                if failure != expected {
                    XCTFail("Worker fixture \(mode): expected \(expected), received \(failure).")
                }
            }
        }
        do {
            _ = try await client("credentials").request(WorkerRequest(command: .doctor, timeoutMS: 1_000), hardTimeout: .seconds(2)) { _ in
                throw CredentialStoreError.invalidBundle
            }
            XCTFail("Credential persistence failure must propagate.")
        } catch CredentialStoreError.invalidBundle {}
        let stalled = client("stall")
        let task = Task {
            try await stalled.request(WorkerRequest(command: .doctor, timeoutMS: 30_000), hardTimeout: .seconds(30))
        }
        try await Task.sleep(for: .milliseconds(100))
        let cancellationStart = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled worker must not succeed.")
        } catch WorkerTransportError.cancelled {
        } catch is CancellationError {}
        XCTAssertTrue(Date().timeIntervalSince(cancellationStart) < 3)
    }

    private func event(_ name: String, payload: [String: Any]) throws -> Data {
        try event(name, fields: ["payload": payload])
    }

    func testSharedWorkerProtocolFixture() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("worker/fixtures/protocol-v1.json")
        try ProtocolFixtureChecks.run(url: url)
    }

    private func event(_ name: String, fields: [String: Any]) throws -> Data {
        var object: [String: Any] = ["protocol_version": 1, "request_id": "fixture", "event": name]
        object.merge(fields) { _, incoming in incoming }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        return data
    }

    private func makeDevice() async throws -> (Database, TrackerDevice) {
        let database = try Database(url: directory.appendingPathComponent("test.sqlite"))
        try await database.upsertProfile(id: "test", provider: "fixture", label: "Fixture")
        let device = TrackerDevice(id: "fixture", profileID: "test", canonicID: "fixture", name: "Fixture", network: "fixture", trackingEnabled: true)
        try await database.upsertDevice(device)
        return (database, device)
    }

    private func observation(deviceID: String) -> Sighting {
        Sighting(id: "observation", deviceID: deviceID, kind: .geographic, latitude: 0, longitude: 0,
                 timestampProvenance: "unknown", ingestedAtMS: 1, source: "fixture")
    }
}

private final class TestClock: TagTrailClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date
    init(now: Date) { instant = now }
    var now: Date { lock.lock(); defer { lock.unlock() }; return instant }
    func advance(seconds: TimeInterval) { lock.lock(); instant.addTimeInterval(seconds); lock.unlock() }
    func sleep(for duration: Duration) async throws { try Task.checkCancellation() }
}

private actor RecordingProvider: TrackerProvider {
    nonisolated var displayName: String { "Fixture" }
    private let failure: ProviderFailure?
    private(set) var pollCount = 0
    init(failure: ProviderFailure? = nil) { self.failure = failure }
    func authenticate(using browser: BrowserAuthentication?) async throws {}
    func discover() async throws -> [ProviderDevice] { [] }
    func poll(device: TrackerDevice) async throws -> ProviderPollResult {
        pollCount += 1
        if let failure { throw failure }
        return ProviderPollResult(sightings: [], rejectedCount: 0)
    }
}

private actor RecordingGeocoder: ReverseGeocoder {
    private let result: GeocodedAddress?
    private(set) var calls = 0
    init(result: GeocodedAddress?) { self.result = result }
    func resolve(latitude: Double, longitude: Double, locale: Locale) async throws -> GeocodedAddress? {
        calls += 1
        return result
    }
}
