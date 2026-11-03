import Foundation

public struct ObservationGroup: Identifiable, Sendable {
    public var id: String { representative.id }
    public let representative: Sighting
    public let count: Int
    public let startMS: Int64, endMS: Int64
}

public enum Simplifier {
    public static func distance(_ a: Sighting, _ b: Sighting) -> Double? {
        guard let lat1 = a.latitude, let lon1 = a.longitude, let lat2 = b.latitude, let lon2 = b.longitude else { return nil }
        let p = Double.pi / 180
        let h = pow(sin((lat2-lat1)*p/2),2) + cos(lat1*p)*cos(lat2*p)*pow(sin((lon2-lon1)*p/2),2)
        return 6_371_000 * 2 * atan2(sqrt(min(1, max(0,h))), sqrt(max(0,1-h)))
    }

    public static func groups(_ observations: [Sighting], simplified: Bool) -> [ObservationGroup] {
        let sorted = observations.sorted { ($0.effectiveTimeMS, $0.id) < ($1.effectiveTimeMS, $1.id) }
        var groups: [ObservationGroup] = []
        var previous: Sighting?
        for row in sorted {
            var grouped = false
            if simplified, let prev = previous, prev.kind == .geographic, row.kind == .geographic,
               let a = prev.accuracy, let b = row.accuracy,
               row.effectiveTimeMS-prev.effectiveTimeMS <= 1_800_000,
               let meters = distance(prev,row), meters <= max(10,min(50,max(a,b))), let last = groups.last {
                groups[groups.count-1] = ObservationGroup(representative: row, count: last.count+1, startMS: last.startMS, endMS: row.effectiveTimeMS)
                grouped = true
            }
            if !grouped { groups.append(ObservationGroup(representative: row, count: 1, startMS: row.effectiveTimeMS, endMS: row.effectiveTimeMS)) }
            previous = row
        }
        return groups
    }

    public static func segments(_ observations: [Sighting]) -> [[Sighting]] {
        var result: [[Sighting]] = []; var segment: [Sighting] = []
        for row in observations.sorted(by: { ($0.effectiveTimeMS,$0.id) < ($1.effectiveTimeMS,$1.id) }) {
            if row.kind != .geographic {
                if !segment.isEmpty { result.append(segment); segment = [] }
                continue
            }
            if let last = segment.last, row.effectiveTimeMS-last.effectiveTimeMS > 3_600_000 {
                result.append(segment); segment = []
            }
            segment.append(row)
        }
        if !segment.isEmpty { result.append(segment) }
        return result
    }
}

public enum CSVExporter {
    public static func string(deviceName: String, observations: [Sighting], addresses: [String:String] = [:]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func time(_ ms: Int64?) -> String { ms.map { formatter.string(from: Date(timeIntervalSince1970: Double($0)/1000)) } ?? "" }
        func text(_ value: String) -> String {
            let first = value.drop(while: { $0.isWhitespace }).first
            let safe = first.map { "=+-@".contains($0) } == true ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        func number(_ value: Double?) -> String { value.map(String.init(describing:)) ?? "" }
        var rows = ["device_name,source,provider_timestamp,timestamp_provenance,ingestion_timestamp,latitude,longitude,altitude,accuracy,semantic_label,address"]
        for row in observations.sorted(by: { ($0.effectiveTimeMS,$0.id) < ($1.effectiveTimeMS,$1.id) }) {
            rows.append([text(deviceName),text(row.source),time(row.providerTimestampMS),text(row.timestampProvenance),
                time(row.ingestedAtMS),number(row.latitude),number(row.longitude),number(row.altitude),number(row.accuracy),
                text(row.semanticLabel ?? ""),text(addresses[row.id] ?? "")].joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }
}
