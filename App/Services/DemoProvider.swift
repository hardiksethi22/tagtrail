import Foundation
import TagTrailCore

struct DemoProvider: TrackerProvider {
    let clock: any TagTrailClock
    var displayName: String { "Demo" }

    func authenticate(using browser: BrowserAuthentication?) async throws {}

    func discover() async throws -> [ProviderDevice] {
        [
            ProviderDevice(canonicID: "demo-keyring", name: "Demo Keyring", network: "Google Find Hub"),
            ProviderDevice(canonicID: "demo-backpack", name: "Demo Backpack", network: "Google Find Hub")
        ]
    }

    func poll(device: TrackerDevice) async throws -> ProviderPollResult {
        let locations: [(Double, Double, String, Int)] = device.canonicID == "demo-backpack"
            ? [(37.7749, -122.4194, "Market Street", 90), (37.7761, -122.4172, "Yerba Buena Gardens", 34)]
            : [(37.7694, -122.4862, "Lands End", 360), (37.7699, -122.4828, "Sutro Baths", 43), (37.7712, -122.4781, "Ocean Beach Trail", 11)]
        let now = Int64(clock.now.timeIntervalSince1970 * 1000)
        let rows = locations.enumerated().map { index, location in
            let age = Int64((locations.count - index) * 11 * 60_000)
            let fixtureGeneration = now / 3_600_000
            let fixtureTime = fixtureGeneration * 3_600_000
            return Sighting(
                id: "demo-\(device.canonicID)-\(index)-\(fixtureGeneration)",
                deviceID: device.id,
                reportID: "demo-report-\(device.canonicID)-\(index)-\(fixtureGeneration)",
                kind: .geographic,
                latitude: location.0,
                longitude: location.1,
                accuracy: 18,
                providerTimestampMS: fixtureTime - age,
                timestampProvenance: "synthetic fixture",
                ingestedAtMS: now,
                semanticLabel: location.2,
                source: "demo fixture"
            )
        }
        return ProviderPollResult(sightings: rows, rejectedCount: 0)
    }

    func address(for sighting: Sighting) -> String? { sighting.semanticLabel }
}
