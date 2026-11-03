import AppKit
import MapKit
import SwiftUI
import UniformTypeIdentifiers
import TagTrailCore

struct PopoverView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var importingCredentials = false

    var body: some View {
        Group {
            if !model.onboardingComplete {
                OnboardingView(importingCredentials: $importingCredentials)
            } else {
                VStack(spacing: 0) {
                    header
                    if let message = model.statusMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 5)
                    }
                    MapPanel(observations: model.observations, selectedID: model.selectedSightingID,
                             semanticMapping: model.semanticPlace, maximumMapPoints: 5) {
                        model.selectSighting($0)
                    }
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    locationReadout
                    feed
                    actions
                }
                .background(.regularMaterial)
            }
        }
        .fileImporter(isPresented: $importingCredentials, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task {
                do {
                    try await model.importGoogleCredentialFile(at: url)
                } catch {
                    model.reportCredentialImportError(error)
                }
            }
        }
        .accessibilityIdentifier("tagtrail-popover")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectedDevice?.name ?? "Your trackers")
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Image(systemName: model.connectionState.symbol)
                            .foregroundStyle(model.connectionState == .ready || model.connectionState == .noNewData ? .green : .secondary)
                        Text(model.connectionState.title)
                        Text("· \(model.modeLabel)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if model.devices.count > 1 {
                    Picker("Tracker", selection: Binding(
                        get: { model.selectedDeviceID ?? "" },
                        set: { model.selectDevice($0) }
                    )) {
                        ForEach(model.devices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 138)
                    .accessibilityLabel("Selected tracker")
                }
            }
            HStack {
                Label("Synced \(model.lastSuccessfulSyncMS.map { relativeTime($0) } ?? "never")", systemImage: "arrow.clockwise")
                Spacer()
                Text(model.filteredCountLabel)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text("Latest report \(model.latestObservation.map { relativeTime($0.effectiveTimeMS) } ?? "none recorded")")
                Spacer()
                Text("New stored \(model.selectedDevice?.lastIngestionMS.map { relativeTime($0) } ?? "never")")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if let reported = model.latestObservation {
                HStack(spacing: 4) {
                    Text("Last reported sighting:")
                    Text(reportTime(reported))
                    Spacer()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var locationReadout: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let sighting = model.selectedSighting {
                HStack {
                    Text(model.selectedAddress ?? coordinate(sighting))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    if sighting.id != model.latestObservation?.id {
                        Text("Historical selection")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 9) {
                    Text(reportTime(sighting))
                    if sighting.latitude != nil { Text(coordinate(sighting)) }
                    if let accuracy = sighting.accuracy { Text("±\(Int(accuracy.rounded())) m") }
                    if sighting.kind == .semantic { Label("Semantic", systemImage: "text.bubble") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("Timestamp: \(sighting.timestampProvenance)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("No sightings in this time window")
                    .font(.subheadline.weight(.medium))
                Text("Try a wider history filter or wait for the next available report.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var feed: some View {
        VStack(spacing: 4) {
            HStack {
                Picker("History window", selection: Binding(get: { model.historyWindow }, set: model.setHistoryWindow)) {
                    ForEach(HistoryWindow.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("History time window")
                Spacer()
                Menu {
                    Toggle("Simplified display", isOn: Binding(get: { model.simplified }, set: { value in Task { await model.setSimplified(value) } }))
                    Divider()
                    ForEach([0, 5, 15, 30, 60], id: \.self) { value in
                        Button {
                            Task { await model.setPollingInterval(value) }
                        } label: {
                            if model.pollingIntervalMinutes == value { Label(intervalTitle(value), systemImage: "checkmark") }
                            else { Text(intervalTitle(value)) }
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 28, height: 24)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Display and polling options")
            }
            .padding(.horizontal, 12)
            ScrollView {
                LazyVStack(spacing: 0) {
                            ForEach(Array(model.visibleGroups.enumerated()), id: \.element.id) { index, group in
                                if index == 0 || !Calendar.current.isDate(
                                    Date(timeIntervalSince1970: Double(model.visibleGroups[index - 1].endMS) / 1000),
                                    inSameDayAs: Date(timeIntervalSince1970: Double(group.endMS) / 1000)
                                ) {
                                    Text(absoluteDay(group.endMS))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 10)
                                        .padding(.top, 8)
                                }
                                Button {
                                    model.selectSighting(group.representative.id)
                                } label: {
                                    SightingRow(group: group, selected: group.representative.id == model.selectedSightingID)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(rowAccessibility(group))
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(minHeight: 105, maxHeight: 190)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: model.startPollNow) {
                Label(pollButtonTitle, systemImage: model.isBusy ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
            }
            .disabled(model.isBusy || model.selectedDevice == nil || model.cooldownRemainingSeconds > 0)
            .keyboardShortcut("r", modifiers: .command)
            Button("Full Map") { openWindow(id: "full-map") }
            Menu {
                Button("Export CSV…", action: model.exportCSV)
                Button("Settings…") { openWindow(id: "settings") }
                Divider()
                Button("Quit TagTrail") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("More actions")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func relativeTime(_ ms: Int64) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince1970 - Double(ms) / 1000))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }

    private func intervalTitle(_ minutes: Int) -> String { minutes == 0 ? "Off" : "Every \(minutes) minutes" }
    private var pollButtonTitle: String {
        if model.isBusy { return "Polling…" }
        if model.cooldownRemainingSeconds > 0 { return "Poll in \(model.cooldownRemainingSeconds)s" }
        return "Poll Now"
    }
}

private struct SightingRow: View {
    let group: ObservationGroup
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: group.representative.kind == .semantic ? "text.bubble" : "mappin.circle.fill")
                .foregroundStyle(selected ? .white : .blue)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(group.representative.semanticLabel ?? coordinate(group.representative))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if group.count > 1 {
                        Text("×\(group.count)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .background(selected ? Color.white.opacity(0.18) : Color.blue.opacity(0.10), in: Capsule())
                    }
                    Spacer(minLength: 3)
                    Text(relativeDate(group.representative.effectiveTimeMS))
                        .font(.caption)
                        .foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
                }
                HStack(spacing: 8) {
                    Text(absoluteDate(group.representative.effectiveTimeMS))
                    if group.representative.kind == .semantic {
                        Text("Semantic report")
                    } else if let accuracy = group.representative.accuracy {
                        Text("±\(Int(accuracy.rounded())) m")
                    }
                    if group.representative.providerTimestampMS == nil { Text("Ingestion time") }
                }
                .font(.caption2)
                .foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
                if group.count > 1 {
                    Text("Grouped \(group.count) reports · \(absoluteDate(group.startMS)) – \(absoluteDate(group.endMS))")
                        .font(.caption2)
                        .foregroundStyle(selected ? .white.opacity(0.75) : .secondary)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

struct MapPanel: View {
    let observations: [Sighting]
    let selectedID: String?
    var semanticMapping: SemanticPlace? = nil
    var maximumMapPoints: Int? = nil
    var selectionChanged: (String) -> Void
    @State private var position: MapCameraPosition = .automatic
    @State private var fitToken = 0

    private var points: [Sighting] {
        let geographic = observations.filter { $0.kind == .geographic && $0.latitude != nil && $0.longitude != nil }
        guard let maximumMapPoints else { return geographic }
        let trailing = Array(geographic.suffix(maximumMapPoints))
        if let selectedID, let selected = geographic.first(where: { $0.id == selectedID }),
           !trailing.contains(where: { $0.id == selectedID }) {
            return (Array(geographic.suffix(max(0, maximumMapPoints - 1))) + [selected])
                .sorted { ($0.effectiveTimeMS, $0.id) < ($1.effectiveTimeMS, $1.id) }
        }
        return trailing
    }
    private var mappedReports: [Sighting] {
        guard let semanticMapping else { return [] }
        return observations.filter { $0.kind == .semantic && $0.semanticLabel == semanticMapping.label }
    }
    private var segments: [[Sighting]] {
        let visibleIDs = Set((maximumMapPoints.map { Array(observations.filter { $0.kind == .geographic }.suffix($0)) } ?? observations)
            .map(\.id))
        return Simplifier.segments(observations)
            .map { $0.filter { visibleIDs.contains($0.id) } }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        Group {
            if points.isEmpty && mappedReports.isEmpty {
                ContentUnavailableView("No map locations", systemImage: "map", description: Text("Semantic sightings remain available in the history feed."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor))
            } else {
                Map(position: $position, interactionModes: [.pan, .zoom]) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        if segment.count > 1 {
                            MapPolyline(coordinates: segment.compactMap(coordinateValue))
                                .stroke(.blue, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                        }
                    }
                    ForEach(points) { sighting in
                        if let coordinate = coordinateValue(sighting) {
                            if let accuracy = sighting.accuracy {
                                MapCircle(center: coordinate, radius: accuracy)
                                    .foregroundStyle(.blue.opacity(0.10))
                                    .stroke(.blue.opacity(0.24), lineWidth: 1)
                            }
                            Annotation(
                                sighting.id == points.last?.id ? "Latest in window" : "Historical sighting",
                                coordinate: coordinate,
                                anchor: .bottom
                            ) {
                                Button {
                                    selectionChanged(sighting.id)
                                } label: {
                                    Image(systemName: sighting.id == points.last?.id ? "mappin.circle.fill" : "circle")
                                        .font(.system(size: sighting.id == points.last?.id || sighting.id == selectedID ? 24 : 15))
                                        .foregroundStyle(sighting.id == points.last?.id || sighting.id == selectedID ? .blue : .white)
                                        .padding(3)
                                        .background(Circle().fill(.white))
                                        .overlay(Circle().stroke(.blue, lineWidth: 1.5))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(sighting.id == points.last?.id ? "Latest in window" : "Historical sighting")
                            }
                        }
                    }
                    if let semanticMapping {
                        ForEach(mappedReports) { sighting in
                            Annotation("User-mapped place: \(semanticMapping.label)", coordinate: CLLocationCoordinate2D(
                                latitude: semanticMapping.latitude, longitude: semanticMapping.longitude
                            ), anchor: .bottom) {
                                Button {
                                    selectionChanged(sighting.id)
                                } label: {
                                    Label("Mapped", systemImage: "mappin.and.ellipse")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(6)
                                        .background(.orange, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("User-mapped place, approximate: \(semanticMapping.label)")
                            }
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat))
                .mapControlVisibility(.automatic)
                .onAppear { fit() }
                .onChange(of: fitToken) { _, _ in fit() }
                .overlay(alignment: .bottomTrailing) {
                    Text("Connectors show observation order, not the traveled route.")
                        .font(.caption2)
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .padding(7)
                }
            }
        }
        .onChange(of: observations.map(\.id)) { _, _ in fit() }
        .onChange(of: selectedID) { _, _ in fit() }
        .onChange(of: semanticMapping?.label) { _, _ in fit() }
    }

    func fit() {
        let latitudes = points.compactMap(\.latitude) + (mappedReports.isEmpty ? [] : semanticMapping.map { [$0.latitude] } ?? [])
        let longitudes = points.compactMap(\.longitude) + (mappedReports.isEmpty ? [] : semanticMapping.map { [$0.longitude] } ?? [])
        guard !latitudes.isEmpty else { return }
        guard let minLat = latitudes.min(), let maxLat = latitudes.max() else { return }
        let anchor = longitudes[0]
        let adjusted = longitudes.map { value -> Double in
            var delta = value - anchor
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            return anchor + delta
        }
        guard let minLon = adjusted.min(), let maxLon = adjusted.max() else { return }
        let centerLon = (minLon + maxLon) / 2
        let normalizedCenter = ((centerLon + 540).truncatingRemainder(dividingBy: 360)) - 180
        let latitudeSpan = max(0.005, (maxLat - minLat) * 1.7)
        let longitudeSpan = max(0.005, (maxLon - minLon) * 1.7)
        position = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: normalizedCenter),
            span: MKCoordinateSpan(latitudeDelta: min(170, latitudeSpan), longitudeDelta: min(350, longitudeSpan))
        ))
    }

    private func coordinateValue(_ sighting: Sighting) -> CLLocationCoordinate2D? {
        guard let latitude = sighting.latitude, let longitude = sighting.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var importingCredentials: Bool
    @State private var showingInfo = false
    @State private var showingBrowserSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("TagTrail", systemImage: "mappin.and.ellipse")
                .font(.largeTitle.weight(.semibold))
            Text("Save available tracker sightings as a private local breadcrumb history.")
                .font(.body)
            VStack(alignment: .leading, spacing: 7) {
                Label("Unofficial Google Find Hub integration; only connect devices you own or are authorized to access.", systemImage: "info.circle")
                Label("Reports are intermittent and do not form a continuous GPS route.", systemImage: "clock")
                Label("History is stored locally in ordinary SQLite files. Credentials are stored in macOS Keychain.", systemImage: "lock")
                Label("Live polling uses Google services; maps and optional reverse geocoding contact external services.", systemImage: "network")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Button {
                Task { await model.enterDemo() }
            } label: {
                Label("Try Demo", systemImage: "map")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            Button {
                importingCredentials = true
            } label: {
                Label("Import Google credentials", systemImage: "person.crop.circle.badge.checkmark")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            Button {
                showingBrowserSetup = true
            } label: {
                Label("Set Up Google in Browser", systemImage: "safari")
                    .frame(maxWidth: .infinity)
            }
            .help("Runs the upstream-supported visible Chrome authentication flow; Chrome and a matching ChromeDriver are required.")
            if model.connectionState == .loading {
                ProgressView("Waiting for Google browser authentication…")
                Button("Cancel authentication", action: model.cancelProviderOperation)
            }
            if let status = model.statusMessage {
                Text(status).font(.caption).foregroundStyle(.red)
            }
            Button("Details about privacy and limitations") { showingInfo = true }
                .buttonStyle(.link)
            Spacer(minLength: 0)
        }
        .padding(20)
        .alert("Privacy and use", isPresented: $showingInfo) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text("TagTrail records reports made available by Google Find Hub, not continuous GPS. Google account credentials and location history are sensitive. Disconnect removes credentials; retained history is deleted separately after confirmation. Map tiles are provided externally, and reverse geocoding is opt-in and sends coordinates to Apple.")
        }
        .sheet(isPresented: $showingBrowserSetup) {
            BrowserSetupView { browser in model.startGoogleConnect(using: browser) }
        }
    }
}

struct FullMapWindow: View {
    @EnvironmentObject private var model: AppModel
    @State private var fitToken = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Full Map").font(.title2.weight(.semibold))
                if model.isDemoMode { Text("DEMO").font(.caption.weight(.bold)).padding(4).background(.orange.opacity(0.2), in: Capsule()) }
                Spacer()
                Picker("Time window", selection: Binding(get: { model.historyWindow }, set: model.setHistoryWindow)) {
                    ForEach(HistoryWindow.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 250)
                Button("Fit to Sightings") { fitToken += 1 }
                    .disabled(!model.observations.contains(where: { $0.kind == .geographic })
                              && !(model.semanticPlace != nil && model.observations.contains(where: { $0.kind == .semantic })))
            }
            .padding()
            HStack(spacing: 0) {
                MapPanel(observations: model.observations, selectedID: model.selectedSightingID, semanticMapping: model.semanticPlace) {
                    model.selectSighting($0)
                }
                .id(fitToken)
                .overlay(alignment: .topLeading) {
                    Text("Connectors show observation order, not an actual route.")
                        .font(.caption)
                        .padding(7)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                        .padding(12)
                }
                Divider()
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(model.visibleGroups) { group in
                            Button {
                                model.selectSighting(group.representative.id)
                            } label: {
                                SightingRow(group: group, selected: group.representative.id == model.selectedSightingID)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
                .frame(width: 290)
            }
            Divider()
            HStack {
                Text(model.selectedDevice?.name ?? "No tracker selected").font(.headline)
                Spacer()
                Text(model.filteredCountLabel).foregroundStyle(.secondary)
                Button("Export CSV…", action: model.exportCSV)
            }
            .padding(12)
        }
    }
}

struct SettingsWindow: View {
    @EnvironmentObject private var model: AppModel
    @State private var importingCredentials = false
    @State private var confirmDelete = false
    @State private var pendingRetention: Int?
    @State private var confirmRetention = false
    @State private var confirmDisconnect = false
    @State private var placeLabel = ""
    @State private var placeCoordinate = ""
    @State private var showingBrowserSetup = false

    var body: some View {
        Form {
            Section("Connection") {
                HStack {
                    Label(model.modeLabel, systemImage: model.isDemoMode ? "map" : "person.crop.circle")
                    Spacer()
                    Text(model.connectionState.title).foregroundStyle(.secondary)
                }
                if model.isDemoMode {
                    Text("Demo records use a separate database and remain labeled as synthetic data.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Exit Demo") { model.leaveDemo() }
                } else {
                    HStack {
                        Button("Reconnect using saved credentials", action: model.reconnectGoogle)
                        Button("Set Up in Browser…") { showingBrowserSetup = true }
                        Button("Import credential export…") { importingCredentials = true }
                        Button("Disconnect Google", role: .destructive) { confirmDisconnect = true }
                    }
                    if model.connectionState == .loading {
                        HStack {
                            ProgressView("Waiting for Google browser authentication…")
                            Button("Cancel", action: model.cancelProviderOperation)
                        }
                    }
                    Text("Authentication uses the upstream visible-browser flow. Imported exports remain sensitive at their original location; TagTrail does not modify them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Trackers") {
                if model.devices.isEmpty {
                    Text("No trackers have been discovered. Connect Google or choose Try Demo.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.devices) { device in
                    Toggle(isOn: Binding(
                        get: { device.trackingEnabled },
                        set: { value in Task { await model.setTracked(value, deviceID: device.id) } }
                    )) {
                        VStack(alignment: .leading) {
                            Text(device.name)
                            Text(device.network).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
                Text("Only selected trackers are polled. Collection requires TagTrail to be running while the Mac is awake and connected.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Polling and history") {
                Picker("Automatic polling", selection: Binding(
                    get: { model.pollingIntervalMinutes },
                    set: { value in Task { await model.setPollingInterval(value) } }
                )) {
                    Text("Off").tag(0)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("60 minutes").tag(60)
                }
                Picker("History retention", selection: Binding(
                    get: { model.retentionDays },
                    set: { value in
                        pendingRetention = value
                        if value == 0 || value < model.retentionDays {
                            confirmRetention = true
                        } else {
                            Task { await model.setRetention(value) }
                        }
                    }
                )) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("365 days").tag(365)
                    Text("Forever").tag(0)
                }
                Toggle("Simplified display", isOn: Binding(get: { model.simplified }, set: { value in Task { await model.setSimplified(value) } }))
                Text("All valid observations remain stored. Simplification only groups nearby reports in the display; CSV always contains raw observations.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Privacy and geocoding") {
                Toggle("Reverse geocode live reports", isOn: Binding(
                    get: { model.isGeocodingEnabled },
                    set: { value in Task { await model.setGeocodingEnabled(value) } }
                ))
                Text("Optional reverse geocoding sends tracker coordinates to Apple's geocoding service. Map tiles are also provided by an external service. No Mac location or Bluetooth permission is requested.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Credentials are protected by Keychain. Local SQLite history is not application-level encrypted and may include precise locations.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Semantic place mapping") {
                Text("Add an explicitly approximate label-to-coordinate mapping for a semantic report. It does not change stored reports or create measured location evidence.")
                    .font(.caption).foregroundStyle(.secondary)
                if let mapping = model.semanticPlace {
                    Label("\(mapping.label) · User-mapped place", systemImage: "mappin.and.ellipse")
                    Text(String(format: "%.5f, %.5f", mapping.latitude, mapping.longitude))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("Remove mapping", role: .destructive) { Task { await model.clearSemanticPlace() } }
                }
                TextField("Place label", text: $placeLabel)
                TextField("Latitude, longitude", text: $placeCoordinate)
                Button("Save mapping") {
                    Task { await model.saveSemanticPlace(label: placeLabel, coordinate: placeCoordinate) }
                }
                .disabled(model.selectedDevice == nil || placeLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section("Local history") {
                Button("Delete selected tracker history…", role: .destructive) { confirmDelete = true }
                    .disabled(model.selectedDevice == nil)
                Text("Deleting history does not remove credentials. Disconnecting does not delete retained history.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = model.statusMessage {
                Section("Status") { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .fileImporter(isPresented: $importingCredentials, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task {
                do { try await model.importGoogleCredentialFile(at: url) }
                catch { model.reportCredentialImportError(error) }
            }
        }
        .sheet(isPresented: $showingBrowserSetup) {
            BrowserSetupView { browser in model.startGoogleConnect(using: browser) }
        }
        .confirmationDialog("Delete this tracker's retained history?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete History", role: .destructive) { Task { await model.deleteHistory() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes local sightings for the selected tracker. Credentials are unchanged.")
        }
        .confirmationDialog("Disconnect Google?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { Task { await model.disconnectGoogle() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved Google credentials will be removed from Keychain. Local history will remain until separately deleted.")
        }
        .confirmationDialog("Shorten or change retention?", isPresented: $confirmRetention, titleVisibility: .visible) {
            Button("Apply retention", role: .destructive) {
                if let pendingRetention { Task { await model.setRetention(pendingRetention) } }
            }
            Button("Cancel", role: .cancel) { pendingRetention = nil }
        } message: {
            Text("Changing retention may permanently delete older observations. Choosing Forever stops automatic deletion.")
        }
    }
}

struct BrowserSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var accountName = ""
    @State private var chromedriverPath = ""
    @State private var chromePath = ""
    @State private var errorMessage: String?

    let authenticate: (BrowserAuthentication) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Up Google").font(.title2.weight(.semibold))
            Text("TagTrail uses GoogleFindMyTools' visible Chrome flow. Sign in directly in the browser window and complete any ordinary Google security checks there. TagTrail never asks for your password.")
                .font(.callout)
            Form {
                TextField("Google account email", text: $accountName)
                    .textContentType(.emailAddress)
                HStack {
                    TextField("ChromeDriver executable path", text: $chromedriverPath)
                    Button("Choose…") { chromedriverPath = chooseFile() ?? chromedriverPath }
                }
                HStack {
                    TextField("Chrome executable (optional)", text: $chromePath)
                    Button("Choose…") { chromePath = chooseFile() ?? chromePath }
                }
            }
            .formStyle(.grouped)
            VStack(alignment: .leading, spacing: 5) {
                Label("Install Chrome and a matching ChromeDriver first; TagTrail will not install software or alter browser security.", systemImage: "info.circle")
                Label("A temporary private profile under ~/Library/Application Support/TagTrail/browser-artifacts is removed after setup. If force-terminated, remove leftover profiles there manually.", systemImage: "trash")
                Label("Google authentication and key retrieval may take up to five minutes. Closing this dialog before starting cancels setup.", systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Continue in Chrome") {
                    let user = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let driver = URL(fileURLWithPath: chromedriverPath)
                    guard user.contains("@"), FileManager.default.isExecutableFile(atPath: driver.path) else {
                        errorMessage = "Enter an account email and select an executable ChromeDriver."
                        return
                    }
                    let chrome = chromePath.isEmpty ? nil : URL(fileURLWithPath: chromePath)
                    if let chrome, !FileManager.default.isExecutableFile(atPath: chrome.path) {
                        errorMessage = "The selected Chrome executable is not executable."
                        return
                    }
                    authenticate(BrowserAuthentication(accountName: user, driverURL: driver, chromeURL: chrome))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chromedriverPath.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 560, height: 470)
    }

    private func chooseFile() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }
}

private func coordinate(_ sighting: Sighting) -> String {
    guard let latitude = sighting.latitude, let longitude = sighting.longitude else { return "Location unavailable" }
    let lat = String(format: "%.5f° %@", abs(latitude), latitude < 0 ? "S" : "N")
    let lon = String(format: "%.5f° %@", abs(longitude), longitude < 0 ? "W" : "E")
    return "\(lat), \(lon)"
}

private func absoluteDate(_ timestamp: Int64) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: Date(timeIntervalSince1970: Double(timestamp) / 1000))
}

private func relativeDate(_ timestamp: Int64) -> String {
    RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: Double(timestamp) / 1000), relativeTo: Date())
}

private func absoluteDay(_ timestamp: Int64) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .full
    formatter.timeStyle = .none
    return formatter.string(from: Date(timeIntervalSince1970: Double(timestamp) / 1000))
}

private func reportTime(_ sighting: Sighting) -> String {
    let label = sighting.providerTimestampMS == nil ? "Recorded" : "Reported"
    return "\(label) \(absoluteDate(sighting.effectiveTimeMS))"
}

private func rowAccessibility(_ group: ObservationGroup) -> String {
    let item = group.representative
    let place = item.semanticLabel ?? coordinate(item)
    let count = group.count > 1 ? ", \(group.count) grouped sightings" : ""
    return "\(place), \(reportTime(item))\(count)"
}
