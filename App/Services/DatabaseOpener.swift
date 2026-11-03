import Foundation
import TagTrailCore

enum DatabaseOpener {
    static func open(url: URL) async throws -> Database {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            return try Database(url: url)
        }.value
    }
}
