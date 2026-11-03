import Foundation
import CryptoKit

public enum SightingKind: String, Codable, Sendable { case geographic, semantic }

public struct Sighting: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var deviceID: String
    public var reportID: String?
    public var kind: SightingKind
    public var latitude: Double?
    public var longitude: Double?
    public var altitude: Double?
    public var accuracy: Double?
    public var providerTimestampMS: Int64?
    public var timestampProvenance: String
    public var ingestedAtMS: Int64
    public var semanticLabel: String?
    public var source: String
    public var effectiveTimeMS: Int64 { providerTimestampMS ?? ingestedAtMS }

    public init(id: String = UUID().uuidString, deviceID: String, reportID: String? = nil,
                kind: SightingKind, latitude: Double? = nil, longitude: Double? = nil,
                altitude: Double? = nil, accuracy: Double? = nil, providerTimestampMS: Int64? = nil,
                timestampProvenance: String = "unavailable", ingestedAtMS: Int64,
                semanticLabel: String? = nil, source: String) {
        self.id = id; self.deviceID = deviceID; self.reportID = reportID; self.kind = kind
        self.latitude = latitude; self.longitude = longitude; self.altitude = altitude
        self.accuracy = accuracy; self.providerTimestampMS = providerTimestampMS
        self.timestampProvenance = timestampProvenance; self.ingestedAtMS = ingestedAtMS
        self.semanticLabel = semanticLabel; self.source = source
    }

    public func validate() throws {
        guard !deviceID.isEmpty, !source.isEmpty, !timestampProvenance.isEmpty else { throw DataError.invalidObservation }
        if let reportID, reportID.isEmpty { throw DataError.invalidObservation }
        if let lat = latitude, let lon = longitude {
            guard lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) else { throw DataError.invalidObservation }
        } else if latitude != nil || longitude != nil || kind == .geographic { throw DataError.invalidObservation }
        if let accuracy, !accuracy.isFinite || accuracy < 0 { throw DataError.invalidObservation }
        if let altitude, !altitude.isFinite { throw DataError.invalidObservation }
        if let providerTimestampMS, providerTimestampMS < 0 { throw DataError.invalidObservation }
        guard ingestedAtMS >= 0 else { throw DataError.invalidObservation }
    }

    public func fingerprint() throws -> String {
        if let reportID, !reportID.isEmpty {
            let data = try JSONEncoder().encode([deviceID, source, reportID])
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        // Sorted-key JSON consistently omits absent values and preserves normalized Doubles.
        struct Content: Encodable {
            let device: String, source: String, kind: SightingKind, provenance: String
            let timestamp: Int64?
            let latitude: Double?, longitude: Double?, altitude: Double?, accuracy: Double?
            let label: String?
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Content(device: deviceID, source: source, kind: kind,
            provenance: timestampProvenance, timestamp: providerTimestampMS,
            latitude: latitude.map { $0 == 0 ? 0 : $0 }, longitude: longitude.map { $0 == 0 ? 0 : $0 },
            altitude: altitude.map { $0 == 0 ? 0 : $0 }, accuracy: accuracy.map { $0 == 0 ? 0 : $0 }, label: semanticLabel))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum DataError: Error { case invalidObservation; case database(String) }

public struct TrackerDevice: Identifiable, Codable, Sendable, Equatable {
    public var id: String, profileID: String, canonicID: String, name: String, network: String
    public var trackingEnabled: Bool
    public var lastAttemptMS: Int64?, lastSuccessMS: Int64?, lastIngestionMS: Int64?
    public init(id: String, profileID: String, canonicID: String, name: String, network: String,
                trackingEnabled: Bool = false, lastAttemptMS: Int64? = nil,
                lastSuccessMS: Int64? = nil, lastIngestionMS: Int64? = nil) {
        self.id = id; self.profileID = profileID; self.canonicID = canonicID
        self.name = name; self.network = network; self.trackingEnabled = trackingEnabled
        self.lastAttemptMS = lastAttemptMS; self.lastSuccessMS = lastSuccessMS; self.lastIngestionMS = lastIngestionMS
    }
}

public struct GeocodeEntry: Sendable {
    public let key: String, locale: String
    public let shortLabel: String?, fullAddress: String?
    public let status: String
    public let attempts: Int
    public let nextRetryMS: Int64?, resolvedMS: Int64?
}

public struct SemanticPlace: Identifiable, Sendable {
    public let id: String, profileID: String
    public let deviceID: String?
    public let label: String
    public let latitude: Double, longitude: Double
}
