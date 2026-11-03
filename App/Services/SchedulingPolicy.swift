import Foundation
import TagTrailCore

enum SchedulingPolicy {
    static func eligibleDevices(_ devices: [TrackerDevice], nowMS: Int64, intervalMinutes: Int) -> [TrackerDevice] {
        guard intervalMinutes > 0 else { return [] }
        let intervalMS = Int64(max(5, intervalMinutes)) * 60_000
        return devices.filter { $0.trackingEnabled && nowMS - ($0.lastAttemptMS ?? 0) >= intervalMS }
            .sorted { ($0.lastAttemptMS ?? 0, $0.id) < ($1.lastAttemptMS ?? 0, $1.id) }
    }
}
