import Foundation
import TagTrailCore

struct ProviderDevice: Sendable {
    let canonicID: String
    let name: String
    let network: String
}

struct ProviderPollResult: Sendable {
    let sightings: [Sighting]
    let rejectedCount: Int
}

struct BrowserAuthentication: Sendable {
    let accountName: String
    let driverURL: URL
    let chromeURL: URL?

    func workerConfiguration() throws -> Data {
        var object: [String: Any] = [
            "enabled": true,
            "chromedriver_path": driverURL.path,
            "artifact_directory": "browser-artifacts"
        ]
        if let chromeURL { object["chrome_binary"] = chromeURL.path }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

enum ProviderFailure: Error, LocalizedError, Sendable {
    case authenticationRequired
    case credentialsLocked
    case unsupportedDevice
    case rateLimited(until: Date?)
    case networkUnavailable
    case timeout
    case protocolError
    case decryptionError
    case internalError

    var errorDescription: String? {
        switch self {
        case .authenticationRequired: "Authentication is required. Reconnect your Google account."
        case .credentialsLocked: "Credentials are unavailable because Keychain access is locked or denied."
        case .unsupportedDevice: "This tracker is not supported by the current provider."
        case .rateLimited: "The provider is rate limiting requests."
        case .networkUnavailable: "The provider could not be reached."
        case .timeout: "The provider did not respond before the request timed out."
        case .protocolError: "The provider returned an invalid response."
        case .decryptionError: "The provider could not decrypt a location report."
        case .internalError: "The provider operation failed."
        }
    }

    var stateCode: String {
        switch self {
        case .authenticationRequired: "authentication-required"
        case .credentialsLocked: "credentials-locked"
        case .unsupportedDevice: "unsupported-device"
        case .rateLimited: "rate-limited"
        case .networkUnavailable: "network-unavailable"
        case .timeout: "timeout"
        case .protocolError: "protocol-error"
        case .decryptionError: "decryption-error"
        case .internalError: "internal-error"
        }
    }
}

protocol TrackerProvider: Sendable {
    var displayName: String { get }
    func authenticate(using browser: BrowserAuthentication?) async throws
    func discover() async throws -> [ProviderDevice]
    func poll(device: TrackerDevice) async throws -> ProviderPollResult
}
