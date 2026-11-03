import Foundation
import TagTrailCore

enum ProtocolFixtureChecks {
    static func run(url: URL? = nil) throws {
        let location: URL
        if let url {
            location = url
        } else if let resource = Bundle.main.resourceURL?.appendingPathComponent("protocol-v1.json"),
                  FileManager.default.fileExists(atPath: resource.path) {
            location = resource
        } else {
            #if DEBUG
            location = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("worker/fixtures/protocol-v1.json")
            #else
            throw DataError.database("Bundled protocol fixture is missing.")
            #endif
        }
        let data = try Data(contentsOf: location)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requests = root["request_examples"] as? [[String: Any]],
              let examples = root["event_examples"] as? [[String: Any]],
              let request = requests.first(where: { $0["command"] as? String == "poll" }),
              let id = request["request_id"] as? String,
              let poll = examples.first(where: { $0["event"] as? String == "result" && $0["request_id"] as? String == id }),
              let error = examples.first(where: { $0["event"] as? String == "error" }),
              let discovery = examples.first(where: { $0["event"] as? String == "result" && $0["request_id"] as? String != id }),
              let discoveryID = discovery["request_id"] as? String else {
            throw ProviderFailure.protocolError
        }
        let events = examples.filter { ["ready", "progress", "credential_update"].contains($0["event"] as? String ?? "") } + [poll]
        let parsed = try WorkerProcessClient.parse(try stream(events), requestID: id, maxLineBytes: 1_048_576)
        guard parsed.map(\.name) == ["ready", "progress", "result"],
              let result = parsed.last,
              let payload = try JSONSerialization.jsonObject(with: result.payload) as? [String: Any],
              let sightings = payload["sightings"] as? [[String: Any]],
              sightings.count == 2,
              sightings[0]["latitude"] as? Double == 0,
              sightings[0]["longitude"] as? Double == 120,
              sightings[0]["source"] as? String == "google-find-my",
              sightings[1]["latitude"] == nil,
              sightings[1]["kind"] as? String == "semantic",
              sightings[1]["timestamp_provenance"] as? String == "provider" else {
            throw ProviderFailure.protocolError
        }
        let discovered = try WorkerProcessClient.parse(try stream([discovery]), requestID: discoveryID, maxLineBytes: 1_048_576)
        guard let deviceResult = discovered.last,
              let devicePayload = try JSONSerialization.jsonObject(with: deviceResult.payload) as? [String: Any],
              let devices = devicePayload["devices"] as? [[String: Any]],
              devices.first?["network"] as? String == "google",
              devices.first?["name"] as? String == "合成 Tracker" else {
            throw ProviderFailure.protocolError
        }
        do {
            _ = try WorkerProcessClient.parse(try stream([error]), requestID: id, maxLineBytes: 1_048_576)
            throw ProviderFailure.protocolError
        } catch ProviderFailure.rateLimited {}
    }

    private static func stream(_ events: [[String: Any]]) throws -> Data {
        var data = Data()
        for event in events {
            data.append(try JSONSerialization.data(withJSONObject: event))
            data.append(10)
        }
        return data
    }
}
