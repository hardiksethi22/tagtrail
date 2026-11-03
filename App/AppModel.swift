import AppKit
import Foundation
import SwiftUI
import TagTrailCore

enum HistoryWindow: String, CaseIterable, Identifiable {
    case hour = "1h", day = "24h", week = "7d", all = "All"
    var id: String { rawValue }
    func cutoff(nowMS: Int64) -> Int64? {
        switch self {
        case .hour: nowMS - 3_600_000
        case .day: nowMS - 86_400_000
        case .week: nowMS - 604_800_000
        case .all: nil
        }
    }
}

enum ConnectionState: Equatable {
    case loading, ready, polling, noNewData, offline, stale, authenticationRequired
    case rateLimited(until: Date), unsupportedDevice, error(String), notConnected

    var title: String {
        switch self {
        case .loading: "Loading"
        case .ready: "Ready"
        case .polling: "Polling"
        case .noNewData: "No new data"
        case .offline: "Offline"
        case .stale: "Stale"
        case .authenticationRequired: "Authentication required"
        case .rateLimited: "Rate limited"
        case .unsupportedDevice: "Unsupported tracker"
        case .error(let message): message
        case .notConnected: "Not connected"
        }
    }

    var symbol: String {
        switch self {
        case .ready, .noNewData: "checkmark.circle.fill"
        case .polling, .loading: "arrow.triangle.2.circlepath"
        case .offline, .stale: "wifi.slash"
        case .authenticationRequired, .error, .unsupportedDevice: "exclamationmark.triangle.fill"
        case .rateLimited: "clock.fill"
        case .notConnected: "circle"
        }
    }
}

private struct SemanticPlaceRecord: Codable {
    let label: String
    let latitude: Double
    let longitude: Double
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var devices: [TrackerDevice] = []
    @Published var selectedDeviceID: String?
    @Published var selectedSightingID: String?
    @Published var historyWindow: HistoryWindow = .day
    @Published private(set) var observations: [Sighting] = []
    @Published private(set) var latestObservation: Sighting?
    @Published private(set) var connectionState: ConnectionState = .notConnected
    @Published private(set) var lastSuccessfulSyncMS: Int64?
    @Published private(set) var statusMessage: String?
    @Published private(set) var isDemoMode = false
    @Published private(set) var onboardingComplete = false
    @Published private(set) var isGeocodingEnabled = false
    @Published private(set) var simplified = true
    @Published private(set) var pollingIntervalMinutes = 15
    @Published private(set) var retentionDays = 90
    @Published private(set) var addresses: [String: String] = [:]
    @Published private(set) var cooldownRemainingSeconds = 0
    @Published private(set) var semanticPlace: SemanticPlace?
    @Published private(set) var networkAvailable = true

    private let maxAddressCache = 100
    private let clock: any TagTrailClock
    private let credentialStore = KeychainCredentialStore()
    private let worker: WorkerProcessClient
    private let coordinator: PollCoordinator
    private let connectivityMonitor = ConnectivityMonitor()
    private let applicationSupport: URL
    private var database: Database?
    private var provider: (any TrackerProvider)?
    private var profileID = ""
    private var schedulerTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var geocodingService: GeocodingService?
    private var lastRetentionSweepMS: Int64 = 0
    private var workspaceObservers: [NSObjectProtocol] = []
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var sleeping = false

    init(clock: any TagTrailClock = SystemTagTrailClock()) {
        self.clock = clock
        self.coordinator = PollCoordinator(clock: clock)
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ))?.appendingPathComponent("TagTrail", isDirectory: true)
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TagTrail", isDirectory: true)
        self.applicationSupport = support
        self.worker = WorkerProcessClient(workingDirectory: support)
        connectivityMonitor.start { [weak self] available in
            self?.networkAvailable = available
            if !available {
                if self?.connectionState == .ready || self?.connectionState == .noNewData {
                    self?.connectionState = .offline
                }
            } else if self?.connectionState == .offline {
                self?.connectionState = .stale
            }
        }
        observePowerState()
        observeMemoryPressure()
        // Demo is a per-launch flag (`-TagTrail.demoMode YES`), not a persisted
        // preference: persisting it made `make run` boot into demo mode.
        let launchDemo = UserDefaults.standard.bool(forKey: "TagTrail.demoMode")
        if launchDemo {
            Task { await enterDemo() }
        } else if UserDefaults.standard.bool(forKey: "TagTrail.onboardingComplete") {
            Task { await restoreLiveConnection() }
        }
    }

    deinit {
        schedulerTask?.cancel()
        operationTask?.cancel()
        connectivityMonitor.stop()
        memoryPressureSource?.cancel()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
    }

    var selectedDevice: TrackerDevice? { devices.first { $0.id == selectedDeviceID } }
    var selectedSighting: Sighting? {
        if let selectedSightingID, let selected = observations.first(where: { $0.id == selectedSightingID }) { return selected }
        return observations.last
    }
    var selectedAddress: String? { selectedSighting.flatMap { addresses[$0.id] ?? $0.semanticLabel } }
    var visibleGroups: [ObservationGroup] {
        Simplifier.groups(observations, simplified: simplified).sorted { $0.endMS > $1.endMS }
    }
    var menuBarTitle: String {
        let name = selectedDevice?.name ?? "TagTrail"
        let sync = lastSuccessfulSyncMS.map { Self.relativeTime($0, now: clock.now) } ?? "Not synced"
        return isDemoMode ? "DEMO · \(name) · \(sync)" : "\(name) · \(sync)"
    }
    var menuBarAccessibilityLabel: String {
        "\(selectedDevice?.name ?? "TagTrail"), \(connectionState.title), last sync \(lastSuccessfulSyncMS.map { Self.relativeTime($0, now: clock.now) } ?? "not available")"
    }
    var modeLabel: String { isDemoMode ? "Demo data" : "Google Find Hub" }
    var isBusy: Bool { connectionState == .polling }
    var filteredCountLabel: String {
        let cap = observations.count == ObservationHistory.displayLimit ? " (latest \(ObservationHistory.displayLimit) raw sightings)" : ""
        return "\(visibleGroups.count) \(simplified ? "groups" : "sightings") in \(historyWindow.rawValue)\(cap)"
    }
    func enterDemo() async {
        do {
            let demoURL = applicationSupport.appendingPathComponent("demo.sqlite")
            let demoDB = try await DatabaseOpener.open(url: demoURL)
            database = demoDB
            let demoProvider = DemoProvider(clock: clock)
            provider = demoProvider
            geocodingService = nil
            profileID = "demo-profile"
            isDemoMode = true
            onboardingComplete = true
            // Demo is a per-launch choice, never a persisted preference;
            // persisting it made the next `make run` boot into demo mode.
            UserDefaults.standard.removeObject(forKey: "TagTrail.demoMode")
            UserDefaults.standard.set(true, forKey: "TagTrail.onboardingComplete")
            try await demoDB.upsertProfile(id: profileID, provider: "demo", label: "Demo data")
            let found = try await demoProvider.discover()
            let prior = try await demoDB.devices(profileID: profileID)
            devices = found.map { item in
                let id = "demo-\(item.canonicID)"
                let old = prior.first { $0.id == id }
                return TrackerDevice(
                    id: id, profileID: profileID, canonicID: item.canonicID, name: item.name, network: item.network,
                    trackingEnabled: old?.trackingEnabled ?? (item.canonicID == found.first?.canonicID),
                    lastAttemptMS: old?.lastAttemptMS, lastSuccessMS: old?.lastSuccessMS, lastIngestionMS: old?.lastIngestionMS
                )
            }
            for device in devices { try await demoDB.upsertDevice(device) }
            selectedDeviceID = devices.first(where: \.trackingEnabled)?.id ?? devices.first?.id
            try await coordinator.restoreCooldown(from: demoDB)
            try await refreshObservations()
            await loadSemanticPlace()
            try await loadSettings()
            connectionState = .ready
            if let device = selectedDevice {
                do {
                    _ = try await coordinator.poll(device: device, provider: demoProvider, database: demoDB, manual: false)
                } catch {
                    show(error: error)
                }
            }
            try await refresh()
            await refreshCooldown()
            startScheduler()
        } catch {
            connectionState = .error("Demo data could not be loaded")
            statusMessage = "TagTrail could not initialize its separate demo history."
        }
    }

    func importGoogleCredentials(_ data: Data) async throws {
        try KeychainCredentialStore.validate(data)
        try credentialStore.save(data)
        try credentialStore.deleteSetupUsername()
        isDemoMode = false
        UserDefaults.standard.set(false, forKey: "TagTrail.demoMode")
        try await activateGoogle(discover: true)
    }

    func connectGoogle(using browser: BrowserAuthentication? = nil) async {
        let hadLiveConnection = onboardingComplete && !isDemoMode
        do {
            let support = applicationSupport
            try await Task.detached {
                try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }.value
            provider = GoogleTrackerProvider(credentials: credentialStore, transport: worker, clock: clock)
            connectionState = .loading
            try await provider?.authenticate(using: browser)
            try credentialStore.deleteSetupUsername()
            await coordinator.authenticationRepaired()
            try await activateGoogle(discover: true)
        } catch is CancellationError {
            connectionState = hadLiveConnection ? .ready : .notConnected
            statusMessage = "Authentication was cancelled. Local history is unchanged; any saved credential updates remain in Keychain."
            if hadLiveConnection, !Task.isCancelled { startScheduler() }
        } catch {
            show(error: error)
            if hadLiveConnection, !Task.isCancelled { startScheduler() }
        }
    }

    func startGoogleConnect(using browser: BrowserAuthentication) {
        schedulerTask?.cancel()
        let previousScheduler = schedulerTask
        schedulerTask = nil
        operationTask?.cancel()
        operationTask = Task {
            await previousScheduler?.value
            await connectGoogle(using: browser)
        }
    }

    func reconnectGoogle() {
        schedulerTask?.cancel()
        let previousScheduler = schedulerTask
        schedulerTask = nil
        operationTask?.cancel()
        operationTask = Task {
            await previousScheduler?.value
            await connectGoogle(using: nil)
        }
    }

    func cancelProviderOperation() {
        operationTask?.cancel()
        operationTask = nil
        connectionState = isDemoMode || onboardingComplete ? .ready : .notConnected
        statusMessage = "Authentication was cancelled. Local history is unchanged; any saved credential updates remain in Keychain."
        if onboardingComplete { startScheduler() }
    }

    func disconnectGoogle() async {
        schedulerTask?.cancel()
        schedulerTask = nil
        operationTask?.cancel()
        await operationTask?.value
        operationTask = nil
        schedulerTask?.cancel()
        schedulerTask = nil
        do {
            try credentialStore.deleteConnectionItems()
            provider = nil
            devices = []
            observations = []
            latestObservation = nil
            semanticPlace = nil
            selectedDeviceID = nil
            onboardingComplete = false
            isDemoMode = false
            UserDefaults.standard.set(false, forKey: "TagTrail.onboardingComplete")
            UserDefaults.standard.set(false, forKey: "TagTrail.demoMode")
            connectionState = .notConnected
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func leaveDemo() {
        schedulerTask?.cancel()
        schedulerTask = nil
        database = nil
        provider = nil
        geocodingService = nil
        devices = []
        observations = []
        latestObservation = nil
        semanticPlace = nil
        selectedDeviceID = nil
        isDemoMode = false
        onboardingComplete = false
        UserDefaults.standard.set(false, forKey: "TagTrail.demoMode")
        UserDefaults.standard.set(false, forKey: "TagTrail.onboardingComplete")
        connectionState = .notConnected
    }

    func reportCredentialImportError(_ error: Error) {
        if let credentialError = error as? CredentialStoreError {
            statusMessage = credentialError.localizedDescription
        } else {
            statusMessage = "The selected credential export could not be read or imported."
        }
        connectionState = .authenticationRequired
    }

    func importGoogleCredentialFile(at url: URL) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 512 * 1024 else {
            throw CredentialStoreError.invalidBundle
        }
        try await importGoogleCredentials(Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    func deleteHistory() async {
        guard let database else { return }
        do {
            try await database.deleteHistory(deviceID: selectedDeviceID)
            try await refresh()
        } catch {
            statusMessage = "Could not delete local history."
        }
    }

    func selectDevice(_ id: String?) {
        selectedDeviceID = id
        selectedSightingID = nil
        observations = []
        latestObservation = nil
        semanticPlace = nil
        addresses = [:]
        lastSuccessfulSyncMS = nil
        Task {
            do {
                try await refresh()
                await loadSemanticPlace()
            } catch {
                statusMessage = "Could not load this tracker's local history."
            }
        }
    }

    func selectSighting(_ id: String?) {
        selectedSightingID = id
        Task { await updateAddress() }
    }

    func setHistoryWindow(_ value: HistoryWindow) {
        historyWindow = value
        Task {
            do { try await refreshObservations() }
            catch { statusMessage = "Could not load the requested history window." }
        }
    }

    func pollNow() async {
        guard let device = selectedDevice, let provider, let database else { return }
        guard networkAvailable else {
            connectionState = .offline
            statusMessage = "The Mac is offline. Polling will resume when network connectivity returns."
            return
        }
        connectionState = .polling
        statusMessage = nil
        do {
            let outcome = try await coordinator.poll(device: device, provider: provider, database: database, manual: true)
            connectionState = outcome.insertedCount == 0 ? .noNewData : .ready
            statusMessage = outcome.rejectedCount > 0
                ? "\(outcome.rejectedCount) invalid report(s) were rejected; valid reports were retained."
                : nil
            lastSuccessfulSyncMS = Int64(clock.now.timeIntervalSince1970 * 1000)
            try await refresh()
            await refreshCooldown()
        } catch is CancellationError {
            connectionState = .ready
        } catch {
            show(error: error)
            await refreshCooldown()
        }
    }

    func startPollNow() {
        guard !isBusy else { return }
        operationTask?.cancel()
        operationTask = Task { await pollNow() }
    }

    func refresh() async throws {
        try await refreshObservations()
        if let database, let selectedDeviceID,
           let row = try await database.devices(profileID: profileID).first(where: { $0.id == selectedDeviceID }) {
            lastSuccessfulSyncMS = row.lastSuccessMS
            devices = try await database.devices(profileID: profileID)
        }
    }

    func setTracked(_ enabled: Bool, deviceID: String) async {
        guard let database else { return }
        do {
            try await database.setTracking(deviceID: deviceID, enabled: enabled)
            if enabled { await coordinator.resumeDevice(deviceID) }
            devices = try await database.devices(profileID: profileID)
        } catch {
            statusMessage = "Could not update tracking selection."
        }
    }

    func setPollingInterval(_ minutes: Int) async {
        guard [0, 5, 15, 30, 60].contains(minutes), let database else { return }
        do {
            try await database.setSetting(key: "poll.interval_minutes", value: String(minutes))
            pollingIntervalMinutes = minutes
            startScheduler()
        } catch {
            statusMessage = "Could not save the polling interval."
        }
    }

    func setRetention(_ days: Int) async {
        guard [0, 30, 90, 365].contains(days), let database else { return }
        do {
            try await database.setSetting(key: "retention.days", value: String(days))
            retentionDays = days
            if days > 0 {
                let nowMS = Int64(clock.now.timeIntervalSince1970 * 1000)
                let cutoff = nowMS - Int64(days) * 86_400_000
                try await database.retain(sinceMS: cutoff)
                lastRetentionSweepMS = nowMS
                try await refresh()
            }
        } catch {
            statusMessage = "Could not apply the retention setting."
        }
    }

    func setSimplified(_ value: Bool) async {
        guard let database else { return }
        do {
            try await database.setSetting(key: "display.simplified", value: value ? "true" : "false")
            simplified = value
        } catch {
            statusMessage = "Could not save the display preference."
        }
    }

    func setGeocodingEnabled(_ value: Bool) async {
        guard let database else { return }
        do {
            try await database.setSetting(key: "geocoding.enabled", value: value ? "true" : "false")
            isGeocodingEnabled = value
        } catch {
            statusMessage = "Could not save the geocoding preference."
            return
        }
        await updateAddress()
    }

    func updateAddress() async {
        guard let sighting = selectedSighting else { return }
        if isDemoMode {
            if let value = sighting.semanticLabel {
                pruneAddressCache()
                addresses[sighting.id] = value
            }
            return
        }
        guard let service = geocodingService else { return }
        do {
            if let value = try await service.address(for: sighting, enabled: isGeocodingEnabled, demo: false) {
                pruneAddressCache()
                addresses[sighting.id] = value
            }
        } catch {
            statusMessage = "The address cache could not be updated. Coordinates remain available."
        }
    }

    /// Keeps the in-memory address cache bounded so browsing many sightings
    /// does not leak memory.
    private func pruneAddressCache() {
        guard addresses.count > maxAddressCache else { return }
        // Drop the oldest half of entries to keep the cache small.
        let toRemove = addresses.keys.prefix(addresses.count / 2)
        for key in toRemove { addresses[key] = nil }
    }

    func saveSemanticPlace(label: String, coordinate: String) async {
        guard let device = selectedDevice, let database,
              let pair = Self.parseCoordinate(coordinate),
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "Enter a place label and a valid latitude, longitude pair."
            return
        }
        do {
            let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            try await database.saveSemanticPlace(id: "app-place-\(device.id)", profileID: device.profileID,
                                                 deviceID: device.id, label: cleanLabel, latitude: pair.0, longitude: pair.1)
            semanticPlace = try await database.semanticPlaces(profileID: device.profileID, deviceID: device.id)
                .first { $0.id == "app-place-\(device.id)" }
            statusMessage = "Saved as a user-mapped approximate place."
        } catch {
            statusMessage = "Could not save this semantic-place mapping."
        }
    }

    func clearSemanticPlace() async {
        guard let device = selectedDevice, let database, let semanticPlace else { return }
        do {
            try await database.deleteSemanticPlace(id: semanticPlace.id)
            try await database.setSetting(key: "semantic_place.\(device.id)", value: "")
            self.semanticPlace = nil
        } catch {
            statusMessage = "Could not remove the semantic-place mapping."
        }
    }

    func exportCSV() {
        guard let device = selectedDevice, let database else { return }
        let window = historyWindow
        let cutoff = window.cutoff(nowMS: Int64(clock.now.timeIntervalSince1970 * 1000))
        Task {
            do {
                let rows = try await ObservationHistory.exportRows(database: database, deviceID: device.id, sinceMS: cutoff)
                var exportAddresses = addresses
                for row in rows where exportAddresses[row.id] == nil && row.kind == .geographic {
                    guard let latitude = row.latitude, let longitude = row.longitude else { continue }
                    let key = GeocodingService.cacheKey(latitude: latitude, longitude: longitude)
                    if let entry = try await database.geocode(key: key, locale: Locale.current.identifier),
                       entry.status == "resolved" {
                        exportAddresses[row.id] = entry.shortLabel ?? entry.fullAddress
                    }
                }
                let csv = CSVExporter.string(deviceName: device.name, observations: rows, addresses: exportAddresses)
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.commaSeparatedText]
                panel.nameFieldStringValue = "\(Self.filename(device.name))-\(window.rawValue).csv"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try Data(csv.utf8).write(to: url, options: .atomic)
                statusMessage = "CSV exported."
            } catch {
                statusMessage = "CSV export failed. Check the destination and try again."
            }
        }
    }

    private func activateGoogle(discover: Bool) async throws {
        let liveDB = try await DatabaseOpener.open(url: applicationSupport.appendingPathComponent("live.sqlite"))
        database = liveDB
        geocodingService = GeocodingService(database: liveDB, clock: clock)
        provider = GoogleTrackerProvider(credentials: credentialStore, transport: worker, clock: clock)
        profileID = "google-profile"
        isDemoMode = false
        UserDefaults.standard.set(false, forKey: "TagTrail.demoMode")
        try await liveDB.upsertProfile(id: profileID, provider: "google-find-hub", label: "Google Find Hub")
        if discover, let provider {
            let found = try await provider.discover()
            let prior = try await liveDB.devices(profileID: profileID)
            devices = found.map { item in
                let id = "google-\(item.canonicID)"
                let old = prior.first { $0.id == id }
                return TrackerDevice(id: id, profileID: profileID, canonicID: item.canonicID, name: item.name, network: item.network,
                    trackingEnabled: old?.trackingEnabled ?? false, lastAttemptMS: old?.lastAttemptMS,
                    lastSuccessMS: old?.lastSuccessMS, lastIngestionMS: old?.lastIngestionMS)
            }
            for device in devices { try await liveDB.upsertDevice(device) }
            selectedDeviceID = selectedDeviceID.flatMap { selected in devices.first(where: { $0.id == selected })?.id }
                ?? devices.first?.id
        }
        try await coordinator.restoreCooldown(from: liveDB)
        await refreshCooldown()
        try await loadSettings()
        try await refreshObservations()
        await loadSemanticPlace()
        onboardingComplete = true
        UserDefaults.standard.set(true, forKey: "TagTrail.onboardingComplete")
        connectionState = .ready
        startScheduler()
    }

    private func restoreLiveConnection() async {
        do {
            _ = try credentialStore.load()
            try await activateGoogle(discover: true)
        } catch CredentialStoreError.itemNotFound {
            onboardingComplete = false
            connectionState = .notConnected
        } catch {
            connectionState = .authenticationRequired
            statusMessage = "Saved credentials are unavailable. Reconnect to resume live polling."
        }
    }

    private func loadSettings() async throws {
        guard let database else { return }
        if let value = try await database.setting(key: "poll.interval_minutes"), let parsed = Int(value), [0,5,15,30,60].contains(parsed) {
            pollingIntervalMinutes = parsed
        }
        if let value = try await database.setting(key: "retention.days"), let parsed = Int(value), [0,30,90,365].contains(parsed) {
            retentionDays = parsed
        }
        if let value = try await database.setting(key: "display.simplified") { simplified = value != "false" }
        if let value = try await database.setting(key: "geocoding.enabled") { isGeocodingEnabled = value == "true" }
    }

    private func refreshObservations() async throws {
        guard let database, let selectedDeviceID else { observations = []; latestObservation = nil; return }
        let all = try await database.latestObservations(deviceID: selectedDeviceID, sinceMS: historyWindow.cutoff(nowMS: Int64(clock.now.timeIntervalSince1970 * 1000)), limit: ObservationHistory.displayLimit)
        let latest = try await database.latestObservations(deviceID: selectedDeviceID, limit: 1).last
        guard self.selectedDeviceID == selectedDeviceID else { return }
        // When the trail has nothing in the selected window, still surface the
        // tracker's current location so the map and feed never look empty.
        var displayed = all
        if displayed.isEmpty, let latest {
            displayed = [latest]
        }
        observations = displayed
        latestObservation = latest
        if let id = selectedSightingID, !displayed.contains(where: { $0.id == id }) { selectedSightingID = nil }
        if selectedSightingID == nil { selectedSightingID = displayed.last?.id }
        await updateAddress()
    }

    private func startScheduler() {
        schedulerTask?.cancel()
        guard provider != nil else { return }
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !Task.isCancelled else { return }
                await self.refreshCooldown()
                await self.pollDueDevices()
                await self.cleanupRetention()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch is CancellationError {
                    return
                } catch {
                    self.statusMessage = "The polling scheduler could not wait for its next cycle."
                    return
                }
            }
        }
    }

    private func pollDueDevices() async {
        guard let database, let provider, pollingIntervalMinutes > 0, networkAvailable, !isBusy, !sleeping else { return }
        guard await coordinator.remainingCooldownMS() == 0,
              !(await coordinator.isAuthenticationPaused()) else { return }
        do {
            devices = try await database.devices(profileID: profileID)
            let nowMS = Int64(clock.now.timeIntervalSince1970 * 1000)
            for device in SchedulingPolicy.eligibleDevices(devices, nowMS: nowMS, intervalMinutes: pollingIntervalMinutes) {
                if Task.isCancelled { return }
                if await coordinator.isDevicePaused(device.id) { continue }
                connectionState = .polling
                do {
                    let outcome = try await coordinator.poll(device: device, provider: provider, database: database, manual: false)
                    connectionState = outcome.insertedCount == 0 ? .noNewData : .ready
                    statusMessage = outcome.rejectedCount > 0
                        ? "\(outcome.rejectedCount) invalid report(s) were rejected; valid reports were retained."
                        : nil
                    lastSuccessfulSyncMS = Int64(clock.now.timeIntervalSince1970 * 1000)
                    try await refresh()
                } catch is CancellationError {
                    return
                } catch {
                    show(error: error)
                }
                break
            }
        } catch is CancellationError {
            return
        } catch {
            connectionState = .error("Local history unavailable")
        }
    }

    private func cleanupRetention() async {
        guard retentionDays > 0, let database else { return }
        let nowMS = Int64(clock.now.timeIntervalSince1970 * 1000)
        guard nowMS - lastRetentionSweepMS >= 12 * 60 * 60 * 1000 else { return }
        do {
            try await database.retain(sinceMS: nowMS - Int64(retentionDays) * 86_400_000)
            lastRetentionSweepMS = nowMS
        } catch {
            statusMessage = "Automatic history retention could not run."
        }
    }

    private func refreshCooldown() async {
        let milliseconds = await coordinator.remainingCooldownMS()
        cooldownRemainingSeconds = Int((milliseconds + 999) / 1000)
        if let lastSuccessfulSyncMS, pollingIntervalMinutes > 0, networkAvailable,
           Int64(clock.now.timeIntervalSince1970 * 1000) - lastSuccessfulSyncMS > Int64(pollingIntervalMinutes * 2) * 60_000,
           (connectionState == .ready || connectionState == .noNewData) {
            connectionState = .stale
        }
    }

    private func loadSemanticPlace() async {
        guard let device = selectedDevice, let database else {
            semanticPlace = nil
            return
        }
        do {
            let saved = try await database.semanticPlaces(profileID: device.profileID, deviceID: device.id)
            if let place = saved.first {
                semanticPlace = place
                return
            }
            guard let json = try await database.setting(key: "semantic_place.\(device.id)"),
                  !json.isEmpty,
                  let data = json.data(using: .utf8) else {
                semanticPlace = nil
                return
            }
            let record = try JSONDecoder().decode(SemanticPlaceRecord.self, from: data)
            guard record.latitude.isFinite, record.longitude.isFinite,
                  (-90...90).contains(record.latitude), (-180...180).contains(record.longitude) else {
                semanticPlace = nil
                return
            }
            try await database.saveSemanticPlace(id: "app-place-\(device.id)", profileID: device.profileID,
                                                 deviceID: device.id, label: record.label,
                                                 latitude: record.latitude, longitude: record.longitude)
            semanticPlace = try await database.semanticPlaces(profileID: device.profileID, deviceID: device.id).first
            try await database.setSetting(key: "semantic_place.\(device.id)", value: "")
        } catch {
            semanticPlace = nil
            statusMessage = "The saved semantic-place mapping could not be read."
        }
    }

    private func show(error: Error) {
        if let failure = error as? ProviderFailure {
            switch failure {
            case .authenticationRequired, .credentialsLocked:
                connectionState = .authenticationRequired
            case .unsupportedDevice: connectionState = .unsupportedDevice
            case .rateLimited(let until): connectionState = .rateLimited(until: until ?? Date().addingTimeInterval(60))
            case .networkUnavailable: connectionState = .offline
            default: connectionState = .error(failure.localizedDescription)
            }
            statusMessage = failure.localizedDescription
        } else if let failure = error as? WorkerTransportError {
            connectionState = failure == .timeout ? .offline : .error("Worker protocol error")
            statusMessage = failure == .timeout
                ? "The tracker request timed out. No location was assumed."
                : "The bundled provider worker could not complete the request."
        } else {
            connectionState = .error("Operation failed")
            statusMessage = error.localizedDescription
        }
    }

    private func observePowerState() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.schedulerTask?.cancel()
                self?.schedulerTask = nil
                self?.operationTask?.cancel()
                self?.sleeping = true
                await self?.coordinator.setSuspended(true)
            }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.sleeping = false
                await self?.coordinator.setSuspended(false)
                self?.startScheduler()
            }
        })
    }

    /// Reacts to system memory pressure by flushing in-memory caches
    /// (addresses, observations) so the app does not contribute to
    /// system-wide RAM exhaustion.
    private func observeMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let pressure = source.data
            Task { @MainActor in
                if pressure.contains(.critical) {
                    self.addresses.removeAll(keepingCapacity: false)
                    self.observations.removeAll(keepingCapacity: true)
                    self.latestObservation = nil
                } else if pressure.contains(.warning) {
                    self.pruneAddressCache()
                }
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    private static func relativeTime(_ timestampMS: Int64, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince1970 - Double(timestampMS) / 1000))
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        return "\(seconds / 86_400)d ago"
    }

    private static func filename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return name.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
    }

    private static func parseCoordinate(_ string: String) -> (Double, Double)? {
        let values = string.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard values.count == 2, values[0].isFinite, values[1].isFinite,
              (-90...90).contains(values[0]), (-180...180).contains(values[1]) else { return nil }
        return (values[0], values[1])
    }
}
