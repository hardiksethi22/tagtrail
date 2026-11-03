import Foundation
import TagTrailCore

enum AppSmokeRunner {
    static func run(directory: URL) async throws {
        let support = directory.appendingPathComponent("TagTrail-Smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try await verify(support: support)
        } catch {
            try FileManager.default.removeItem(at: support)
            throw error
        }
        try FileManager.default.removeItem(at: support)
    }

    private static func verify(support: URL) async throws {
        let demoDatabase = try await DatabaseOpener.open(url: support.appendingPathComponent("demo.sqlite"))
        let liveDatabase = try await DatabaseOpener.open(url: support.appendingPathComponent("live.sqlite"))
        let worker = WorkerProcessClient(workingDirectory: support)
        let workerEvents = try await worker.request(
            WorkerRequest(command: .doctor, timeoutMS: 45_000),
            hardTimeout: .seconds(60)
        )
        guard let doctor = workerEvents.last(where: { $0.name == "result" }),
              let workerInfo = try JSONSerialization.jsonObject(with: doctor.payload) as? [String: Any],
              workerInfo["status"] as? String == "ok" else {
            throw DataError.database("The bundled worker doctor check failed.")
        }
        try validateSyntheticCredentialContract()
        try ProtocolFixtureChecks.run()
        let clock = SmokeClock(now: Date())
        let provider = DemoProvider(clock: clock)
        try await demoDatabase.upsertProfile(id: "demo-profile", provider: "demo", label: "Demo data")
        let discovered = try await provider.discover()
        guard let fixtureDevice = discovered.first else { throw DataError.database("Demo fixtures did not provide a tracker.") }
        let device = TrackerDevice(
            id: "demo-\(fixtureDevice.canonicID)", profileID: "demo-profile",
            canonicID: fixtureDevice.canonicID, name: fixtureDevice.name,
            network: fixtureDevice.network, trackingEnabled: true
        )
        try await demoDatabase.upsertDevice(device)
        for other in discovered.dropFirst() {
            try await demoDatabase.upsertDevice(TrackerDevice(id: "demo-\(other.canonicID)", profileID: device.profileID,
                                                              canonicID: other.canonicID, name: other.name,
                                                              network: other.network, trackingEnabled: false))
        }
        let initialDevices = try await demoDatabase.devices(profileID: device.profileID)
        guard initialDevices.filter(\.trackingEnabled).map(\.id) == [device.id] else {
            throw DataError.database("Only the initially chosen tracker should be enabled.")
        }
        let batch = try await provider.poll(device: device)
        guard batch.rejectedCount == 0, batch.sightings.count >= 2 else {
            throw DataError.database("Demo fixtures did not provide valid location reports.")
        }
        let inserted = try await demoDatabase.ingest(batch.sightings)
        let repeated = try await demoDatabase.ingest(batch.sightings)
        guard inserted == batch.sightings.count, repeated == 0 else {
            throw DataError.database("Demo fixture ingestion was not idempotent.")
        }
        let since = Int64(clock.now.timeIntervalSince1970 * 1000) - 86_400_000
        let recent = try await demoDatabase.observations(deviceID: device.id, sinceMS: since, limit: 100)
        guard recent.count >= 2, recent.allSatisfy({ $0.kind == .geographic }) else {
            throw DataError.database("Demo observations were not queryable in the default time window.")
        }
        guard try await liveDatabase.devices(profileID: "demo-profile").isEmpty else {
            throw DataError.database("Demo devices leaked into live history.")
        }
        try await verifyServices(database: demoDatabase, device: device, provider: provider, clock: clock, support: support)
    }

    private static func verifyServices(database: Database, device: TrackerDevice, provider: DemoProvider,
                                       clock: SmokeClock, support: URL) async throws {
        let nowMS = Int64(clock.now.timeIntervalSince1970 * 1000)
        let beforePoll = try await database.devices(profileID: device.profileID).first { $0.id == device.id }
        let cutoff = HistoryWindow.day.cutoff(nowMS: nowMS)
        let display = try await database.latestObservations(deviceID: device.id, sinceMS: cutoff, limit: ObservationHistory.displayLimit)
        let latest = try await database.latestObservations(deviceID: device.id, limit: 1).last
        let groups = Simplifier.groups(display, simplified: true)
        guard groups.reduce(0, { $0 + $1.count }) == display.count,
              groups.last?.representative.id == latest?.id,
              Simplifier.groups(display, simplified: false).count == display.count,
              Simplifier.segments(display).flatMap({ $0 }).count == display.count else {
            throw DataError.database("History feed and map data did not preserve fixture observations.")
        }
        let coordinator = PollCoordinator(clock: clock)
        let repeatedPoll = try await coordinator.poll(device: device, provider: provider, database: database, manual: true)
        let afterPoll = try await database.devices(profileID: device.profileID).first { $0.id == device.id }
        let afterLatest = try await database.latestObservations(deviceID: device.id, limit: 1).last
        guard repeatedPoll.insertedCount == 0,
              afterPoll?.lastIngestionMS == beforePoll?.lastIngestionMS,
              afterLatest?.providerTimestampMS == latest?.providerTimestampMS,
              afterPoll?.lastSuccessMS == nowMS else {
            throw DataError.database("A no-new-data poll changed sighting freshness.")
        }
        let restored = PollCoordinator(clock: clock)
        try await restored.restoreCooldown(from: database)
        guard await restored.remainingCooldownMS() == 60_000 else {
            throw DataError.database("Account cooldown did not persist.")
        }
        do {
            _ = try await restored.poll(device: device, provider: provider, database: database, manual: true)
            throw DataError.database("Manual polling bypassed account cooldown.")
        } catch ProviderFailure.rateLimited {}
        let cancellationDB = try await DatabaseOpener.open(url: support.appendingPathComponent("cancel.sqlite"))
        try await cancellationDB.upsertProfile(id: device.profileID, provider: "demo", label: "Demo")
        try await cancellationDB.upsertDevice(device)
        let cancellationCoordinator = PollCoordinator(clock: clock)
        do {
            _ = try await cancellationCoordinator.poll(device: device, provider: CancelledSmokeProvider(),
                                                       database: cancellationDB, manual: true)
            throw DataError.database("Cancelled provider unexpectedly completed.")
        } catch is CancellationError {}
        let cancellationRestored = PollCoordinator(clock: clock)
        try await cancellationRestored.restoreCooldown(from: cancellationDB)
        guard await cancellationRestored.remainingCooldownMS() == 60_000 else {
            throw DataError.database("Cancellation bypassed persisted account cooldown.")
        }
        let partial = try await PollCoordinator(clock: clock).poll(device: device, provider: PartialSmokeProvider(),
                                                                  database: cancellationDB, manual: true)
        guard partial.rejectedCount == 1 else {
            throw DataError.database("Partial-validity status was not preserved.")
        }
        try await database.setTracking(deviceID: device.id, enabled: false)
        let devices = try await database.devices(profileID: device.profileID)
        guard devices.first(where: { $0.id == device.id })?.trackingEnabled == false else {
            throw DataError.database("Tracking settings did not round-trip.")
        }
        let semantic = Sighting(id: "smoke-semantic", deviceID: device.id, kind: .semantic,
                                timestampProvenance: "unknown", ingestedAtMS: nowMS,
                                semanticLabel: "Smoke place", source: "demo fixture")
        _ = try await database.ingest([semantic])
        try await database.saveSemanticPlace(id: "smoke-place", profileID: device.profileID, deviceID: device.id,
                                             label: "Smoke place", latitude: 0, longitude: 0)
        let mappings = try await database.semanticPlaces(profileID: device.profileID, deviceID: device.id)
        let semanticRows = try await database.latestObservations(deviceID: device.id, limit: 1)
        guard mappings.first?.label == semantic.semanticLabel,
              semanticRows.first?.latitude == nil, semanticRows.first?.longitude == nil else {
            throw DataError.database("A user place mapping changed raw semantic evidence.")
        }
        let geocoding = GeocodingService(database: database, geocoder: SmokeGeocoder(), clock: clock)
        guard let latest else { throw DataError.database("Latest fixture was unavailable.") }
        let address = try await geocoding.address(for: latest, enabled: false, demo: true)
        guard address == latest.semanticLabel else {
            throw DataError.database("Demo address labels were unavailable without network access.")
        }
        let raw = try await ObservationHistory.exportRows(database: database, deviceID: device.id, sinceMS: cutoff)
        let labels = Dictionary(uniqueKeysWithValues: raw.compactMap { row in row.semanticLabel.map { (row.id, $0) } })
        let csv = CSVExporter.string(deviceName: device.name, observations: raw, addresses: labels)
        let export = support.appendingPathComponent("fixture.csv")
        try Data(csv.utf8).write(to: export, options: .atomic)
        let reopenedCSV = try String(contentsOf: export, encoding: .utf8)
        guard reopenedCSV == csv, csv.components(separatedBy: "\r\n").count == raw.count + 2,
              csv.contains("Smoke place"), raw.count == display.count + 1 else {
            throw DataError.database("Raw CSV export did not round-trip feed observations.")
        }
        try await database.deleteSemanticPlace(id: "smoke-place")
        try await database.deleteHistory(deviceID: device.id)
        guard try await database.observations(deviceID: device.id).isEmpty,
              try await database.semanticPlaces(profileID: device.profileID, deviceID: device.id).isEmpty else {
            throw DataError.database("History and mapping deletion did not persist.")
        }
    }

    private struct SmokeGeocoder: ReverseGeocoder {
        func resolve(latitude: Double, longitude: Double, locale: Locale) async throws -> GeocodedAddress? {
            throw DataError.database("Offline demo unexpectedly requested reverse geocoding.")
        }
    }

    private struct CancelledSmokeProvider: TrackerProvider {
        var displayName: String { "Cancelled fixture" }
        func authenticate(using browser: BrowserAuthentication?) async throws {}
        func discover() async throws -> [ProviderDevice] { [] }
        func poll(device: TrackerDevice) async throws -> ProviderPollResult { throw CancellationError() }
    }

    private struct PartialSmokeProvider: TrackerProvider {
        var displayName: String { "Partial fixture" }
        func authenticate(using browser: BrowserAuthentication?) async throws {}
        func discover() async throws -> [ProviderDevice] { [] }
        func poll(device: TrackerDevice) async throws -> ProviderPollResult {
            ProviderPollResult(sightings: [], rejectedCount: 1)
        }
    }

    private struct SmokeClock: TagTrailClock {
        let now: Date
        func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
    }

    private static func validateSyntheticCredentialContract() throws {
        let credentials: [String: Any] = [
            "username": "fixture@example.invalid",
            "aas_token": "synthetic-token",
            "owner_key": String(repeating: "0", count: 64),
            "fcm_credentials": [
                "gcm": ["android_id": "123456", "security_token": "987654", "app_id": "fixture", "token": "fixture"],
                "keys": ["private": "fixture", "public": "fixture", "secret": "fixture"],
                "fcm": ["registration": ["token": "fixture"], "installation": ["token": "fixture", "refresh_token": "fixture"]]
            ]
        ]
        try KeychainCredentialStore.validate(JSONSerialization.data(withJSONObject: credentials))
        let partial = try JSONSerialization.data(withJSONObject: [
            "username": "fixture@example.invalid",
            "fcm_credentials": ["gcm": ["android_id": "123456"]]
        ])
        try KeychainCredentialStore.validateWorkerUpdate(partial)
    }
}
