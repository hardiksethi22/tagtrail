import AppKit
import MapKit
import SwiftUI
import UniformTypeIdentifiers
import TagTrailCore

/// Brand tokens for TagTrail: the app icon's teal-to-indigo trail, used only
/// as an accent on marks, connectors, and selection. Text and controls stay on
/// system semantic colors so light, dark, and increased-contrast all hold.
/// White on indigo measures 6.8:1 (light) and 4.9:1 (dark); teal is used for
/// graphics only and clears 3:1 on both surfaces.
private enum TrailStyle {
    static let teal = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.20, green: 0.84, blue: 0.77, alpha: 1)
            : NSColor(srgbRed: 0.03, green: 0.55, blue: 0.51, alpha: 1)
    })
    static let indigo = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.30, green: 0.39, blue: 0.92, alpha: 1)
            : NSColor(srgbRed: 0.22, green: 0.30, blue: 0.80, alpha: 1)
    })
    static let gradient = LinearGradient(colors: [teal, indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// The one repeated brand moment: a small gradient tile holding the app mark.
private struct TrailBadge: View {
    var size: CGFloat = 26
    var body: some View {
        Image(systemName: "mappin.and.ellipse")
            .font(.system(size: size * 0.58, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(TrailStyle.gradient, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .shadow(color: TrailStyle.indigo.opacity(0.25), radius: 2, y: 1)
            .accessibilityHidden(true)
    }
}

struct PopoverView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                             semanticMapping: model.semanticPlace, maximumMapPoints: 5, showsLegend: false) {
                        model.selectSighting($0)
                    }
                    .frame(height: 170)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.separator, lineWidth: 0.5)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    locationReadout
                    feed
                    Divider()
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.selectedDevice?.name ?? "Your trackers")
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                        Text(model.connectionState.title)
                        Text("· \(model.modeLabel)")
                            .foregroundStyle(.tertiary)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
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
            Divider()
                .padding(.horizontal, 16)
            HStack(spacing: 6) {
                Label(syncLabel, systemImage: "arrow.clockwise")
                Spacer(minLength: 8)
                Text(model.filteredCountLabel)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    /// One line of sync truth: when the last report was, and when it was stored.
    private var syncLabel: String {
        let reported = model.latestObservation.map { relativeTime($0.effectiveTimeMS) } ?? "none"
        let stored = model.selectedDevice?.lastIngestionMS.map { relativeTime($0) } ?? "never"
        return "Reported \(reported) · stored \(stored)"
    }

    private var statusColor: Color {
        switch model.connectionState {
        case .ready, .noNewData: .green
        case .polling, .loading: .blue
        case .offline, .stale: .orange
        case .authenticationRequired, .error, .unsupportedDevice, .rateLimited: .red
        case .notConnected: .secondary
        }
    }

    private var locationReadout: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let sighting = model.selectedSighting {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.selectedAddress ?? coordinate(sighting))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if sighting.id != model.latestObservation?.id {
                        Text("Historical")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Text(reportTime(sighting))
                    if sighting.latitude != nil {
                        Text(coordinate(sighting)).monospacedDigit()
                    }
                    if let accuracy = sighting.accuracy { Text("±\(Int(accuracy.rounded())) m") }
                    if sighting.kind == .semantic {
                        Label("Semantic", systemImage: "text.bubble")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.quinary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.selectedSightingID)
    }

    private var feed: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Picker("History window", selection: Binding(get: { model.historyWindow }, set: model.setHistoryWindow)) {
                    ForEach(HistoryWindow.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("History time window")
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
                        .frame(width: 24, height: 20)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Display and polling options")
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            ScrollView {
                SightingFeed(groups: model.visibleGroups, selectedID: model.selectedSightingID, verticalPadding: 4) {
                    model.selectSighting($0)
                }
            }
            .frame(minHeight: 105, maxHeight: 190)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: model.startPollNow) {
                Label(pollButtonTitle, systemImage: model.isBusy ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .frame(minWidth: 88)
            }
            .buttonStyle(.borderedProminent)
            .tint(TrailStyle.indigo)
            .disabled(model.isBusy || model.selectedDevice == nil || model.cooldownRemainingSeconds > 0)
            .keyboardShortcut("r", modifiers: .command)
            Button("Full Map") { openWindow(id: "full-map") }
                .buttonStyle(.bordered)
            Spacer(minLength: 0)
            Menu {
                Button("Export CSV…", action: model.exportCSV)
                Button("Settings…") { openWindow(id: "settings") }
                Divider()
                Button("Quit TagTrail") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
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
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: group.representative.kind == .semantic ? "text.bubble.fill" : "mappin.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(selected ? .white : iconColor)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(group.representative.semanticLabel ?? coordinate(group.representative))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if group.count > 1 {
                        Text("×\(group.count)")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(selected ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(.quaternary),
                                        in: Capsule())
                    }
                    Spacer(minLength: 4)
                    Text(relativeDate(group.representative.effectiveTimeMS))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(selected ? .white.opacity(0.9) : .secondary)
                }
                Text(detailLine)
                    .font(.caption2)
                    .foregroundStyle(selected ? .white.opacity(0.9) : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: selected)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .combine)
    }

    private var iconColor: Color {
        group.representative.kind == .semantic ? .orange : TrailStyle.teal
    }

    private var background: AnyShapeStyle {
        if selected { return AnyShapeStyle(TrailStyle.indigo) }
        return hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)
    }

    /// One metadata line instead of three stacked rows of competing text.
    private var detailLine: String {
        var parts = [absoluteDate(group.representative.effectiveTimeMS)]
        if group.representative.kind == .semantic {
            parts.append("Semantic report")
        } else if let accuracy = group.representative.accuracy {
            parts.append("±\(Int(accuracy.rounded())) m")
        }
        if group.representative.providerTimestampMS == nil { parts.append("ingestion time") }
        if group.count > 1 { parts.append("grouped \(group.count)") }
        return parts.joined(separator: " · ")
    }
}

/// The history list shared by the popover and the full map window: day
/// dividers, hover feedback on macOS, and an empty state that suggests a way
/// forward instead of showing a blank scroll area.
private struct SightingFeed: View {
    let groups: [ObservationGroup]
    let selectedID: String?
    var verticalPadding: CGFloat = 0
    let onSelect: (String) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            if groups.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text("No sightings in this window")
                        .font(.subheadline.weight(.medium))
                    Text("Widen the history filter or wait for the next report.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
            }
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                if index == 0 || !Calendar.current.isDate(
                    Date(timeIntervalSince1970: Double(groups[index - 1].endMS) / 1000),
                    inSameDayAs: Date(timeIntervalSince1970: Double(group.endMS) / 1000)
                ) {
                    Text(absoluteDay(group.endMS))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.top, index == 0 ? 4 : 10)
                        .padding(.bottom, 2)
                }
                Button {
                    onSelect(group.representative.id)
                } label: {
                    SightingRow(group: group, selected: group.representative.id == selectedID)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(rowAccessibility(group))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, verticalPadding)
    }
}

struct MapPanel: View {
    let observations: [Sighting]
    let selectedID: String?
    var semanticMapping: SemanticPlace? = nil
    var maximumMapPoints: Int? = nil
    var showsLegend = true
    var selectionChanged: (String) -> Void
    @State private var position: MapCameraPosition = .automatic
    @State private var fitToken = 0

    /// Hard cap on map annotations. MapKit materialises an NSImage-backed
    /// annotation view per point; rendering thousands of them allocates
    /// gigabytes of CoreUI rendition caches.
    private static let hardMapPointLimit = 150

    private var geographic: [Sighting] {
        observations.filter { $0.kind == .geographic && $0.latitude != nil && $0.longitude != nil }
    }

    private var points: [Sighting] {
        let limit = min(maximumMapPoints ?? Self.hardMapPointLimit, Self.hardMapPointLimit)
        let trailing = Array(geographic.suffix(limit))
        if let selectedID, let selected = geographic.first(where: { $0.id == selectedID }),
           !trailing.contains(where: { $0.id == selectedID }) {
            return (Array(geographic.suffix(max(0, limit - 1))) + [selected])
                .sorted { ($0.effectiveTimeMS, $0.id) < ($1.effectiveTimeMS, $1.id) }
        }
        return trailing
    }
    private var mappedReports: [Sighting] {
        guard let semanticMapping else { return [] }
        return observations.filter { $0.kind == .semantic && $0.semanticLabel == semanticMapping.label }
    }
    private var segments: [[Sighting]] {
        let visibleIDs = Set(points.map(\.id))
        return Simplifier.segments(points)
            .map { $0.filter { visibleIDs.contains($0.id) } }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        Group {
            if points.isEmpty && mappedReports.isEmpty {
                ContentUnavailableView {
                    Label("No map locations", systemImage: "map")
                } description: {
                    Text("Semantic sightings remain available in the history feed.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
            } else {
                Map(position: $position, interactionModes: [.pan, .zoom]) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        if segment.count > 1 {
                            MapPolyline(coordinates: segment.compactMap(coordinateValue))
                                .stroke(TrailStyle.gradient, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [5, 5]))
                        }
                    }
                    ForEach(points) { sighting in
                        if let coordinate = coordinateValue(sighting) {
                            let isLatest = sighting.id == points.last?.id
                            let isSelected = sighting.id == selectedID
                            if isLatest, let accuracy = sighting.accuracy {
                                MapCircle(center: coordinate, radius: accuracy)
                                    .foregroundStyle(TrailStyle.indigo.opacity(0.10))
                                    .stroke(TrailStyle.indigo.opacity(0.22), lineWidth: 1)
                            }
                            Annotation(
                                isLatest ? "Latest in window" : "Historical sighting",
                                coordinate: coordinate,
                                anchor: .bottom
                            ) {
                                Button {
                                    selectionChanged(sighting.id)
                                } label: {
                                    ZStack {
                                        Circle()
                                            .fill(isLatest || isSelected
                                                  ? AnyShapeStyle(TrailStyle.gradient)
                                                  : AnyShapeStyle(.white))
                                            .frame(width: (isLatest || isSelected) ? 15 : 8, height: (isLatest || isSelected) ? 15 : 8)
                                            .overlay {
                                                Circle().strokeBorder(.black.opacity(0.18), lineWidth: 0.5)
                                            }
                                            .shadow(color: .black.opacity(isLatest || isSelected ? 0.25 : 0.1), radius: 2, y: 1)
                                    }
                                    .padding(4)
                                    .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(isLatest ? "Latest in window" : "Historical sighting")
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
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 4)
                                        .background(.orange, in: Capsule())
                                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("User-mapped place, approximate: \(semanticMapping.label)")
                            }
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat, emphasis: .muted))
                .mapControlVisibility(.automatic)
                .onAppear { fit() }
                .onChange(of: fitToken) { _, _ in fit() }
                .overlay(alignment: .topTrailing) {
                    if showsLegend {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(TrailStyle.gradient)
                                .frame(width: 8, height: 8)
                            Text("Latest")
                                .font(.caption2.weight(.medium))
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text("Historical")
                                .font(.caption2)
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .padding(8)
                    }
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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                TrailBadge(size: 54)
                VStack(alignment: .leading, spacing: 6) {
                    Text("TagTrail")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text("A private breadcrumb history of the sightings your trackers make available.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 26)
            .padding(.bottom, 22)

            VStack(alignment: .leading, spacing: 9) {
                Button {
                    Task { await model.enterDemo() }
                } label: {
                    Label("Try Demo", systemImage: "map")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(TrailStyle.indigo)
                .keyboardShortcut(.defaultAction)

                Button {
                    showingBrowserSetup = true
                } label: {
                    Label("Sign in with Google", systemImage: "person.badge.key")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .help("Opens a visible browser window for Google sign-in; a Chromium browser plus a matching ChromeDriver are required.")

                Button {
                    importingCredentials = true
                } label: {
                    Label("Import existing credentials…", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)

                if model.connectionState == .loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for Google sign-in…").font(.caption)
                        Spacer()
                        Button("Cancel", action: model.cancelProviderOperation)
                            .controlSize(.small)
                    }
                }
                if let status = model.statusMessage {
                    Label(status, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 22)

            Spacer(minLength: 16)

            VStack(alignment: .leading, spacing: 7) {
                Label("Unofficial Google Find Hub integration. Connect only devices you own or are authorized to access.", systemImage: "info.circle")
                Label("Reports are intermittent, not a continuous GPS route.", systemImage: "clock")
                Label("History stays on this Mac in local SQLite; credentials live in the Keychain.", systemImage: "lock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary.opacity(0.5), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .padding(.horizontal, 18)
            .padding(.bottom, 12)

            Button("Privacy and limitations") { showingInfo = true }
                .buttonStyle(.link)
                .font(.caption)
                .padding(.horizontal, 22)
                .padding(.bottom, 20)
        }
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
            HStack(spacing: 10) {
                TrailBadge(size: 24)
                Text("Trail Map")
                    .font(.title3.weight(.semibold))
                if model.isDemoMode {
                    Text("DEMO")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.14), in: Capsule())
                }
                Spacer()
                Picker("Time window", selection: Binding(get: { model.historyWindow }, set: model.setHistoryWindow)) {
                    ForEach(HistoryWindow.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .accessibilityLabel("History time window")
                Button("Fit to Sightings") { fitToken += 1 }
                    .disabled(!model.observations.contains(where: { $0.kind == .geographic })
                              && !(model.semanticPlace != nil && model.observations.contains(where: { $0.kind == .semantic })))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            HStack(spacing: 0) {
                MapPanel(observations: model.observations, selectedID: model.selectedSightingID, semanticMapping: model.semanticPlace, maximumMapPoints: 150) {
                    model.selectSighting($0)
                }
                .id(fitToken)
                Divider()
                VStack(spacing: 0) {
                    HStack {
                        Text(model.filteredCountLabel)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    Divider().padding(.horizontal, 12)
                    ScrollView {
                        SightingFeed(groups: model.visibleGroups, selectedID: model.selectedSightingID, verticalPadding: 8) {
                            model.selectSighting($0)
                        }
                    }
                }
                .frame(width: 300)
            }
            Divider()
            HStack(spacing: 10) {
                Text(model.selectedDevice?.name ?? "No tracker selected")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Export CSV…", action: model.exportCSV)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
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

    private var connectionTint: Color {
        switch model.connectionState {
        case .ready, .noNewData: .green
        case .polling, .loading: .blue
        case .offline, .stale: .orange
        case .authenticationRequired, .error, .unsupportedDevice, .rateLimited: .red
        case .notConnected: .secondary
        }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    TrailBadge(size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.modeLabel).font(.headline)
                        Text(model.connectionState.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle()
                        .fill(connectionTint)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 2)
                if model.isDemoMode {
                    Text("Demo records use a separate database and remain labeled as synthetic data.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Exit Demo") { model.leaveDemo() }
                } else {
                    HStack {
                        Button("Reconnect using saved credentials", action: model.reconnectGoogle)
                        Button("Sign in with Google…") { showingBrowserSetup = true }
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
            } header: {
                Text("Connection")
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
                TextField("Place label", text: $placeLabel, prompt: Text("Home, office, school…"))
                    .accessibilityLabel("Place label")
                TextField("Latitude, longitude", text: $placeCoordinate, prompt: Text("37.3349, -122.0090"))
                    .accessibilityLabel("Latitude and longitude")
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

    private var detectedBrowserName: String? { BrowserLocator.detectedBrowserName() }
    private var detectedMajor: Int? { BrowserLocator.browserMajorVersion() }
    private var driverDetected: Bool { BrowserLocator.detectDriver() != nil }
    private var canContinue: Bool {
        accountName.contains("@") && FileManager.default.isExecutableFile(atPath: chromedriverPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    accountSection
                    browserSection
                    requirements
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 560)
        .onAppear(perform: prefillDetectedPaths)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            TrailBadge(size: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text("Sign in with Google")
                    .font(.title3.weight(.semibold))
                Text("A browser window opens where you sign in directly. TagTrail never asks for your password.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(.quinary.opacity(0.5))
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Account")
                .font(.subheadline.weight(.semibold))
            TextField("Google account email", text: $accountName, prompt: Text("you@gmail.com"))
                .textContentType(.emailAddress)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .accessibilityLabel("Google account email")
            if !accountName.isEmpty && !accountName.contains("@") {
                Label("Enter a full email address.", systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var browserSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Browser")
                .font(.subheadline.weight(.semibold))

            LabeledContent("Browser") {
                HStack(spacing: 8) {
                    Text(chromePath.isEmpty ? "None selected" : URL(fileURLWithPath: chromePath).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(chromePath.isEmpty ? .secondary : .primary)
                    Button("Choose…") { chromePath = chooseFile() ?? chromePath }
                        .controlSize(.small)
                }
            }

            LabeledContent("ChromeDriver") {
                HStack(spacing: 8) {
                    Text(chromedriverPath.isEmpty ? "None selected" : URL(fileURLWithPath: chromedriverPath).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(chromedriverPath.isEmpty ? .secondary : .primary)
                    Button("Choose…") { chromedriverPath = chooseFile() ?? chromedriverPath }
                        .controlSize(.small)
                }
            }

            if let detectedBrowserName {
                Label("\(detectedBrowserName) detected\(detectedMajor.map { " · Chromium \($0)" } ?? "")",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Label("No Chromium browser found. Install Chrome, Brave, Chromium, Edge, or Vivaldi.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !driverDetected {
                VStack(alignment: .leading, spacing: 4) {
                    Label("ChromeDriver not found on this Mac.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("Download the driver whose major version matches your browser\(detectedMajor.map { " (\($0))" } ?? ""), then choose it above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var requirements: some View {
        DisclosureGroup("What this does") {
            VStack(alignment: .leading, spacing: 7) {
                Label("TagTrail never downloads or installs a browser or driver, and never changes browser security settings.", systemImage: "info.circle")
                Label("A private sign-in profile is kept in TagTrail's data directory so your Google session is remembered for next time. Delete the browser-artifacts folder there to sign the helper out.", systemImage: "arrow.triangle.2.circlepath")
                Label("Your existing browser session is reused when the system allows it; otherwise sign in once and it is remembered.", systemImage: "person.crop.circle")
                Label("Sign-in and key retrieval can take up to five minutes.", systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        }
        .font(.caption.weight(.medium))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Continue in Browser", action: submit)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func submit() {
        let user = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        let driver = URL(fileURLWithPath: chromedriverPath)
        guard user.contains("@") else {
            errorMessage = "Enter a full email address."
            return
        }
        guard FileManager.default.isExecutableFile(atPath: driver.path) else {
            errorMessage = "Choose an executable ChromeDriver."
            return
        }
        let chrome = chromePath.isEmpty ? BrowserLocator.detectBrowser() : URL(fileURLWithPath: chromePath)
        if let chrome, !FileManager.default.isExecutableFile(atPath: chrome.path) {
            errorMessage = "The selected browser is not executable."
            return
        }
        errorMessage = nil
        authenticate(BrowserAuthentication(accountName: user, driverURL: driver, chromeURL: chrome))
        dismiss()
    }

    /// Prefill whatever is already installed so sign-in needs no manual paths.
    private func prefillDetectedPaths() {
        if chromedriverPath.isEmpty, let driver = BrowserLocator.detectDriver() {
            chromedriverPath = driver.path
        }
        if chromePath.isEmpty, let browser = BrowserLocator.detectBrowser() {
            chromePath = browser.path
        }
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
