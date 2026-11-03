import CoreLocation
import Foundation
import TagTrailCore

struct GeocodedAddress: Sendable {
    let shortLabel: String?
    let fullAddress: String?
}

protocol ReverseGeocoder: Sendable {
    func resolve(latitude: Double, longitude: Double, locale: Locale) async throws -> GeocodedAddress?
}

struct AppleReverseGeocoder: ReverseGeocoder {
    func resolve(latitude: Double, longitude: Double, locale: Locale) async throws -> GeocodedAddress? {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let placemark = try await geocoder.reverseGeocodeLocation(location, preferredLocale: locale).first else {
            return nil
        }
        let address = [placemark.name, placemark.locality, placemark.administrativeArea, placemark.country]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { parts, value in
                if parts.last != value { parts.append(value) }
            }
        return GeocodedAddress(shortLabel: placemark.name ?? placemark.locality, fullAddress: address.joined(separator: ", "))
    }
}

actor GeocodingService {
    private let database: Database
    private let geocoder: any ReverseGeocoder
    private let clock: any TagTrailClock
    private var nextRequestMS: Int64 = 0
    private var active = false

    init(database: Database, geocoder: any ReverseGeocoder = AppleReverseGeocoder(), clock: any TagTrailClock = SystemTagTrailClock()) {
        self.database = database
        self.geocoder = geocoder
        self.clock = clock
    }

    func address(for sighting: Sighting, enabled: Bool, demo: Bool) async throws -> String? {
        if let label = sighting.semanticLabel, !label.isEmpty { return label }
        guard enabled, !demo, sighting.kind == .geographic,
              let latitude = sighting.latitude, let longitude = sighting.longitude else { return nil }
        let locale = Locale.current
        let key = Self.cacheKey(latitude: latitude, longitude: longitude)
        let nowMS = Int64(clock.now.timeIntervalSince1970 * 1000)
        let cachedEntry = try await database.geocode(key: key, locale: locale.identifier)
        if let entry = cachedEntry {
            if entry.status == "resolved" { return entry.shortLabel ?? entry.fullAddress }
            if entry.status == "no-result", (entry.nextRetryMS ?? Int64.max) > nowMS { return nil }
            if let retry = entry.nextRetryMS, retry > nowMS { return nil }
        }
        guard !active, nowMS >= nextRequestMS else { return nil }
        active = true
        let attempts = (cachedEntry?.attempts ?? 0) + 1
        nextRequestMS = nowMS + 60_000
        defer { active = false }
        let result: GeocodedAddress?
        do {
            result = try await geocoder.resolve(latitude: latitude, longitude: longitude, locale: locale)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failedMS = Int64(clock.now.timeIntervalSince1970 * 1000)
            try await database.saveGeocode(
                key: key, locale: locale.identifier, shortLabel: nil, fullAddress: nil,
                status: "failed", attempts: attempts, nextRetryMS: failedMS + 3_600_000, resolvedMS: nil
            )
            throw error
        }
        let resolvedMS = Int64(clock.now.timeIntervalSince1970 * 1000)
        if let result {
            try await database.saveGeocode(
                key: key, locale: locale.identifier, shortLabel: result.shortLabel,
                fullAddress: result.fullAddress, status: "resolved", attempts: attempts,
                nextRetryMS: nil, resolvedMS: resolvedMS
            )
            return result.shortLabel ?? result.fullAddress
        }
        try await database.saveGeocode(
            key: key, locale: locale.identifier, shortLabel: nil, fullAddress: nil,
            status: "no-result", attempts: attempts, nextRetryMS: resolvedMS + 86_400_000, resolvedMS: nil
        )
        return nil
    }

    static func cacheKey(latitude: Double, longitude: Double) -> String {
        String(format: "%.3f,%.3f", latitude, longitude)
    }
}
