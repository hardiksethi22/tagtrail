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

/// Locates an already-installed Chromium-based browser and a user-supplied
/// ChromeDriver. TagTrail never downloads or installs either.
enum BrowserLocator {
    /// Known Chromium-family app bundles, most Google-compatible first.
    private static let browserCandidates: [(name: String, path: String)] = [
        ("Google Chrome", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
        ("Google Chrome (user)", NSHomeDirectory() + "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
        ("Brave Browser", "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"),
        ("Chromium", "/Applications/Chromium.app/Contents/MacOS/Chromium"),
        ("Microsoft Edge", "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"),
        ("Vivaldi", "/Applications/Vivaldi.app/Contents/MacOS/Vivaldi")
    ]

    private static let driverCandidates = [
        "/opt/homebrew/bin/chromedriver",
        "/usr/local/bin/chromedriver",
        NSHomeDirectory() + "/.local/bin/chromedriver",
        NSHomeDirectory() + "/chromedriver"
    ]

    /// First installed Chromium-family browser executable, if any.
    static func detectBrowser() -> URL? {
        browserCandidates
            .map { URL(fileURLWithPath: $0.path) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func detectedBrowserName() -> String? {
        guard let url = detectBrowser() else { return nil }
        return browserCandidates.first { URL(fileURLWithPath: $0.path) == url }?.name
    }

    /// First executable ChromeDriver found on common paths, if any.
    static func detectDriver() -> URL? {
        driverCandidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Chromium major version, used to explain ChromeDriver mismatches.
    static func browserMajorVersion() -> Int? {
        guard let browser = detectBrowser() else { return nil }
        let info = browser
            .deletingLastPathComponent() // MacOS
            .deletingLastPathComponent() // Contents
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: info),
              let raw = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let plist = raw as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String,
              let major = Int(version.split(separator: ".").first ?? "") else { return nil }
        return major
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
