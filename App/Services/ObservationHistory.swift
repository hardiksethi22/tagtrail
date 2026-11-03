import Foundation
import TagTrailCore

enum ObservationHistory {
    static let displayLimit = 1_000

    static func exportRows(database: Database, deviceID: String, sinceMS: Int64?) async throws -> [Sighting] {
        var rows: [Sighting] = []
        var offset = 0
        let pageSize = 10_000
        while true {
            try Task.checkCancellation()
            let page = try await database.observations(deviceID: deviceID, sinceMS: sinceMS, limit: pageSize, offset: offset)
            rows.append(contentsOf: page)
            if page.count < pageSize { return rows }
            offset += page.count
        }
    }
}
