import Foundation
import TagTrailCore

enum ObservationHistory {
    /// Upper bound on in-memory sightings held for UI rendering.
    static let displayLimit = 1_000

    /// Absolute cap on rows accumulated during a single export pass so a
    /// large history cannot exhaust memory during CSV export.
    static let exportRowCap = 100_000

    static func exportRows(database: Database, deviceID: String, sinceMS: Int64?) async throws -> [Sighting] {
        var rows: [Sighting] = []
        var offset = 0
        let pageSize = 5_000
        while rows.count < exportRowCap {
            try Task.checkCancellation()
            let page = try await database.observations(deviceID: deviceID, sinceMS: sinceMS, limit: pageSize, offset: offset)
            rows.append(contentsOf: page)
            if page.count < pageSize || rows.count >= exportRowCap { return rows }
            offset += page.count
        }
        return rows
    }
}
