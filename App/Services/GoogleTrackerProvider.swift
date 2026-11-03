import Foundation
import Security
import TagTrailCore

private struct WorkerDeviceResult: Decodable {
    let id: String
    let name: String
    let network: String
}

private struct WorkerSighting: Decodable {
    let deviceID: String
    let reportID: String?
    let kind: SightingKind
    let latitude: Double?
    let longitude: Double?
    let altitude: Double?
    let accuracy: Double?
    let providerTimestampMS: Int64?
    let timestampProvenance: String
    let semanticLabel: String?
    let source: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case reportID = "report_id"
        case kind, latitude, longitude, altitude, accuracy
        case providerTimestampMS = "provider_timestamp_ms"
        case timestampProvenance = "timestamp_provenance"
        case semanticLabel = "semantic_label"
        case source
    }

    func sighting(localDeviceID: String, ingestedAtMS: Int64) throws -> Sighting {
        let row = Sighting(
            deviceID: localDeviceID,
            reportID: reportID,
            kind: kind,
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            accuracy: accuracy,
            providerTimestampMS: providerTimestampMS,
            timestampProvenance: timestampProvenance,
            ingestedAtMS: ingestedAtMS,
            semanticLabel: semanticLabel,
            source: source
        )
        try row.validate()
        return row
    }
}

private struct LossyElement: Decodable {
    let value: WorkerSighting?
    init(from decoder: Decoder) throws { value = try? WorkerSighting(from: decoder) }
}

private struct WorkerResult: Decodable {
    let devices: [WorkerDeviceResult]?
    let sightings: [WorkerSighting]?
    let rejectedCount: Int?
    let undecodableCount: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        devices = try container.decodeIfPresent([WorkerDeviceResult].self, forKey: .devices)
        rejectedCount = try container.decodeIfPresent(Int.self, forKey: .rejectedCount)
        if let elements = try container.decodeIfPresent([LossyElement].self, forKey: .sightings) {
            sightings = elements.compactMap(\.value)
            undecodableCount = elements.count - sightings!.count
        } else {
            sightings = nil
            undecodableCount = 0
        }
    }

    enum CodingKeys: String, CodingKey {
        case devices, sightings
        case rejectedCount = "rejected_count"
    }
}

struct GoogleTrackerProvider: TrackerProvider {
    let credentials: KeychainCredentialStore
    let transport: WorkerProcessClient
    let clock: any TagTrailClock
    var displayName: String { "Google Find Hub" }

    init(credentials: KeychainCredentialStore, transport: WorkerProcessClient, clock: any TagTrailClock = SystemTagTrailClock()) {
        self.credentials = credentials
        self.transport = transport
        self.clock = clock
    }

    func authenticate(using browser: BrowserAuthentication?) async throws {
        if let browser { try credentials.saveSetupUsername(browser.accountName) }
        let existing: Data?
        do {
            existing = try credentials.loadAuthenticationBundle()
        } catch CredentialStoreError.itemNotFound {
            existing = nil
        } catch CredentialStoreError.keychain {
            throw ProviderFailure.credentialsLocked
        } catch CredentialStoreError.invalidBundle {
            throw ProviderFailure.authenticationRequired
        } catch {
            throw ProviderFailure.internalError
        }
        let browserConfiguration = try browser?.workerConfiguration()
        let events = try await perform(
            WorkerRequest(command: .authenticate, timeoutMS: 300_000, credentialBundle: existing, browserHelper: browserConfiguration),
            hardTimeout: .seconds(305)
        )
        _ = events
        do {
            _ = try credentials.load()
        } catch CredentialStoreError.keychain {
            throw ProviderFailure.credentialsLocked
        } catch {
            throw ProviderFailure.authenticationRequired
        }
    }

    func discover() async throws -> [ProviderDevice] {
        let bundle = try loadCredentials()
        let events = try await perform(
            WorkerRequest(command: .listDevices, timeoutMS: 45_000, credentialBundle: bundle),
            hardTimeout: .seconds(60)
        )
        guard let result = try decodeResult(events),
              let devices = result.devices else { throw ProviderFailure.protocolError }
        return devices.map { ProviderDevice(canonicID: $0.id, name: $0.name, network: $0.network) }
    }

    func poll(device: TrackerDevice) async throws -> ProviderPollResult {
        let bundle = try loadCredentials()
        let events = try await perform(
            WorkerRequest(command: .poll, timeoutMS: 45_000, credentialBundle: bundle, deviceID: device.canonicID),
            hardTimeout: .seconds(60)
        )
        guard let terminal = events.last(where: { $0.name == "result" }) else { throw ProviderFailure.protocolError }
        return try Self.normalizedPoll(payload: terminal.payload, device: device, ingestedAtMS: Int64(clock.now.timeIntervalSince1970 * 1000))
    }

    static func normalizedPoll(payload: Data, device: TrackerDevice, ingestedAtMS: Int64) throws -> ProviderPollResult {
        let result: WorkerResult
        do { result = try JSONDecoder().decode(WorkerResult.self, from: payload) }
        catch { throw ProviderFailure.protocolError }
        guard
              let rows = result.sightings,
              let rejectedCount = result.rejectedCount, rejectedCount >= 0 else {
            throw ProviderFailure.protocolError
        }
        var valid: [Sighting] = []
        var rejected = rejectedCount + result.undecodableCount
        for row in rows {
            guard row.deviceID == device.canonicID else { throw ProviderFailure.protocolError }
            do {
                valid.append(try row.sighting(localDeviceID: device.id, ingestedAtMS: ingestedAtMS))
            } catch {
                rejected += 1
            }
        }
        return ProviderPollResult(sightings: valid, rejectedCount: rejected)
    }

    private func loadCredentials() throws -> Data {
        do { return try credentials.load() }
        catch CredentialStoreError.itemNotFound { throw ProviderFailure.authenticationRequired }
        catch CredentialStoreError.invalidBundle { throw ProviderFailure.authenticationRequired }
        catch CredentialStoreError.keychain { throw ProviderFailure.credentialsLocked }
        catch { throw ProviderFailure.internalError }
    }

    private func perform(_ request: WorkerRequest, hardTimeout: Duration) async throws -> [WorkerEvent] {
        do {
            return try await transport.request(request, hardTimeout: hardTimeout) { [credentials] payload in
                try Self.persistCredentialUpdate(payload, store: credentials)
            }
        } catch WorkerTransportError.timeout {
            throw ProviderFailure.timeout
        } catch WorkerTransportError.cancelled {
            throw CancellationError()
        } catch CredentialStoreError.keychain {
            throw ProviderFailure.credentialsLocked
        } catch CredentialStoreError.invalidBundle {
            throw ProviderFailure.protocolError
        } catch WorkerTransportError.unavailable, WorkerTransportError.launchFailed, WorkerTransportError.failedExit {
            throw ProviderFailure.internalError
        } catch WorkerTransportError.malformedOutput, WorkerTransportError.unexpectedEvent,
                WorkerTransportError.missingTerminal, WorkerTransportError.outputLimit {
            throw ProviderFailure.protocolError
        } catch let failure as ProviderFailure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderFailure.internalError
        }
    }

    private static func persistCredentialUpdate(_ payload: Data, store: KeychainCredentialStore) throws {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let encoded = object["credential_bundle"],
              JSONSerialization.isValidJSONObject(encoded) else { throw ProviderFailure.protocolError }
        let data = try JSONSerialization.data(withJSONObject: encoded)
        try store.saveWorkerUpdate(data)
    }

    private func decodeResult(_ events: [WorkerEvent]) throws -> WorkerResult? {
        guard let event = events.last(where: { $0.name == "result" }) else { return nil }
        do { return try JSONDecoder().decode(WorkerResult.self, from: event.payload) }
        catch { throw ProviderFailure.protocolError }
    }
}
