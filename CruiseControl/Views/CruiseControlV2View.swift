import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers

enum V2Section: String, CaseIterable, Identifiable {
    case home
    case performanceLab
    case live
    case session
    case benchmark
    case optimize
    case setup

    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Home"
        case .performanceLab: return "Performance Lab"
        case .live: return "Live Diagnosis"
        case .session: return "Session"
        case .benchmark: return "Benchmark"
        case .optimize: return "Optimize"
        case .setup: return "Setup"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "house"
        case .performanceLab: return "waveform.path.ecg"
        case .live: return "gauge.with.dots.needle.67percent"
        case .session: return "chart.xyaxis.line"
        case .benchmark: return "stopwatch"
        case .optimize: return "slider.horizontal.3"
        case .setup: return "cable.connector"
        }
    }
}

struct CruiseControlV2View: View {
    @EnvironmentObject private var sampler: PerformanceSampler
    @EnvironmentObject private var settings: SettingsStore
    @State private var selected: V2Section? = .home

    var body: some View {
        NavigationSplitView {
            List(V2Section.allCases, selection: $selected) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
                    .accessibilityLabel(section.title)
            }
            .navigationTitle("CruiseControl")
            .safeAreaInset(edge: .bottom) {
                connectionFooter
            }
        } detail: {
            switch selected ?? .home {
            case .home: HomeDashboardView()
            case .performanceLab: PerformanceLabView()
            case .live: LiveDiagnosisView()
            case .session: SessionDiagnosisView()
            case .benchmark: BenchmarkView()
            case .optimize: OptimizeView()
            case .setup: SetupDiagnosisView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear { sampler.start() }
    }

    private var connectionFooter: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: sampler.connectionPhase == .collecting ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(sampler.connectionPhase == .collecting ? .green : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(sampler.connectionPhase.title)
                    .font(.caption.weight(.semibold))
                Text("UDP \(settings.xPlaneUDPPort)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.bar)
    }
}

private struct PerformanceLabView: View {
    @EnvironmentObject private var sampler: PerformanceSampler

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader("Performance Lab", subtitle: "Frame pacing, stutters, and the evidence behind the current diagnosis")

                stabilitySummary
                timeline
                limiter
                evidence
            }
            .padding(28)
            .frame(maxWidth: 1_050, alignment: .leading)
        }
        .navigationTitle("Performance Lab")
    }

    private var isFresh: Bool {
        switch sampler.connectionPhase {
        case .collecting, .missingDiagnosticFields:
            return true
        default:
            return false
        }
    }

    private var stabilitySummary: some View {
        GroupBox("Recent stability") {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: stabilitySymbol)
                    .font(.title2)
                    .foregroundStyle(stabilityColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(stabilityTitle).font(.headline)
                    Text(stabilityDetail).foregroundStyle(.secondary)
                }
                Spacer()
                if let stats = sampler.liveDiagnosis.statistics {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(String(format: "%.1f ms median", stats.medianMilliseconds)).monospacedDigit()
                        Text("\(stats.spikeCount) spikes · \(Int(stats.spikeFrequency * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
        }
    }

    private var timeline: some View {
        PerformanceLabTimeline(
            samples: visibleSamples,
            stutters: visibleStutters,
            telemetryIsStale: sampler.connectionPhase == .connectionLost
        )
    }

    private var limiter: some View {
        GroupBox("Likely limiter") {
            VStack(alignment: .leading, spacing: 8) {
                if isFresh {
                    Text(sampler.liveDiagnosis.bottleneck == .insufficientEvidence ? "Insufficient evidence" : sampler.liveDiagnosis.bottleneck.title)
                        .font(.headline)
                    Text(sampler.liveDiagnosis.explanation)
                    Text("\(sampler.liveDiagnosis.confidence.rawValue.capitalized) confidence")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Insufficient evidence").font(.headline)
                    Text("Fresh X-Plane telemetry is required before CruiseControl can identify a likely limiter.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var evidence: some View {
        GroupBox("Evidence") {
            VStack(alignment: .leading, spacing: 12) {
                Text(isFresh ? sampler.liveDiagnosis.evidence : "The displayed timeline is historical until a fresh telemetry packet arrives.")
                    .foregroundStyle(.secondary)

                Divider()

                HStack(spacing: 28) {
                    technicalValue("Samples", value: "\(visibleSamples.count)")
                    technicalValue("Stutter events", value: "\(visibleStutters.count)")
                    technicalValue("Episodes", value: "\(sampler.stutterEpisodes.count)")
                    technicalValue("Telemetry", value: isFresh ? "Fresh" : "Stale / unavailable")
                }

                if sampler.stutterCauseSummaries.isEmpty {
                    Text("No recurring stutter cause has been recorded yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recorded stutter causes").font(.caption.weight(.semibold))
                        ForEach(sampler.stutterCauseSummaries.prefix(3)) { summary in
                            Text("\(summary.cause.displayName): \(summary.count) event\(summary.count == 1 ? "" : "s") · \(Int(summary.averageConfidence * 100))% confidence")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var visibleSamples: [FrameSample] { Array(sampler.frameSamples.suffix(600)) }

    private var visibleStutters: [StutterEvent] {
        guard let start = visibleSamples.first?.capturedAt else { return [] }
        return sampler.stutterEvents.filter { $0.timestamp >= start }
    }

    private var stabilityTitle: String {
        guard isFresh else { return sampler.connectionPhase == .connectionLost ? "Telemetry is stale" : "Waiting for telemetry" }
        guard let stats = sampler.liveDiagnosis.statistics else { return "Collecting a stability window" }
        return stats.spikeFrequency >= 0.05 || !visibleStutters.isEmpty ? "Frame pacing is unstable" : "Frame pacing is stable"
    }

    private var stabilityDetail: String {
        guard isFresh else { return "CruiseControl will resume analysis when valid X-Plane telemetry returns." }
        guard sampler.liveDiagnosis.statistics != nil else { return "Keep the same aircraft and view while CruiseControl gathers enough samples." }
        return visibleStutters.isEmpty ? "No recorded stutter markers are present in the visible timeline." : "Orange markers show existing recorded stutter events in the visible timeline."
    }

    private var stabilitySymbol: String {
        isFresh ? (stabilityTitle.contains("unstable") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill") : "clock.badge.exclamationmark"
    }

    private var stabilityColor: Color {
        isFresh ? (stabilityTitle.contains("unstable") ? .orange : .green) : .secondary
    }

    private func technicalValue(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
    }
}

private struct PerformanceLabTimeline: View {
    let samples: [FrameSample]
    let stutters: [StutterEvent]
    let telemetryIsStale: Bool

    var body: some View {
        GroupBox("Frame-time and FPS timeline") {
            if samples.isEmpty {
                ContentUnavailableView(
                    telemetryIsStale ? "Telemetry is stale" : "No frame-time samples",
                    systemImage: "chart.xyaxis.line",
                    description: Text(telemetryIsStale
                        ? "CruiseControl will not use stale samples to make a live performance claim."
                        : "Start X-Plane and configure Data Output in Setup to begin the timeline.")
                )
                .frame(height: 340)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    frameTimeChart
                    fpsChart
                    legend
                }
                .padding(8)
            }
        }
    }

    private var frameTimeChart: some View {
        Chart {
            ForEach(samples) { sample in
                LineMark(
                    x: .value("Time", sample.capturedAt),
                    y: .value("Frame time", sample.frameTimeMilliseconds)
                )
                .foregroundStyle(.blue)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            ForEach(stutters) { event in
                RuleMark(x: .value("Stutter", event.timestamp))
                    .foregroundStyle(.orange.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartYScale(domain: 0...frameTimeMaximum)
        .chartYAxisLabel("Frame time (ms)")
        .frame(height: 210)
        .accessibilityLabel("Frame-time timeline with stutter markers")
    }

    private var fpsChart: some View {
        Chart(samples) { sample in
            LineMark(
                x: .value("Time", sample.capturedAt),
                y: .value("FPS", sample.fps)
            )
            .foregroundStyle(.green)
            .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartYScale(domain: 0...fpsMaximum)
        .chartYAxisLabel("FPS")
        .frame(height: 150)
        .accessibilityLabel("Frames-per-second timeline")
    }

    private var legend: some View {
        HStack(spacing: 14) {
            Label("Frame time", systemImage: "line.diagonal").foregroundStyle(.blue)
            Label("FPS", systemImage: "line.diagonal").foregroundStyle(.green)
            Label("Stutter marker", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Spacer()
            Text("\(stutters.count) recorded marker\(stutters.count == 1 ? "" : "s") in view")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private var frameTimeMaximum: Double {
        let values = samples.map(\.frameTimeMilliseconds).sorted()
        let p99 = values[min(Int(Double(values.count - 1) * 0.99), values.count - 1)]
        return max(50, min(250, ceil(p99 * 1.25 / 10) * 10))
    }

    private var fpsMaximum: Double {
        max(60, min(500, ceil((samples.map(\.fps).max() ?? 60) / 10) * 10))
    }
}

private struct HomeDashboardView: View {
    @EnvironmentObject private var sampler: PerformanceSampler
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var featureStore: V112FeatureStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader("Home", subtitle: "Your X-Plane performance at a glance")

                HStack(spacing: 14) {
                    metricCard(title: "Current FPS", value: latest.map { String(format: "%.1f", $0.fps) } ?? "Not available yet", detail: freshnessDetail)
                    metricCard(title: "Frame time", value: latest.map { String(format: "%.1f ms", $0.frameTimeMilliseconds) } ?? "Not available yet", detail: freshnessDetail)
                    metricCard(title: "Stability", value: stabilityTitle, detail: stabilityDetail)
                }

                GroupBox("Connection") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(sampler.connectionPhase.title)
                            .font(.headline)
                        Text(sampler.snapshot.udpStatus.detail ?? "Waiting for a connection update.")
                            .foregroundStyle(.secondary)
                        Text("UDP \(sampler.snapshot.udpStatus.listenHost):\(sampler.snapshot.udpStatus.listenPort) · \(packetRate) packets/sec")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Simulator: \(sampler.flightContext.simulatorVersion.displayName) · Flight state: \(sampler.flightContext.phaseOfFlightDetail)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(alignment: .top, spacing: 14) {
                    contextCard(title: "Aircraft", value: sampler.flightContext.aircraftDisplayName, detail: aircraftDetail)
                    contextCard(title: "Airport", value: airportLabel, detail: airportDetail)
                    contextCard(title: "Optimization mode", value: optimizationMode, detail: "Automatic mode is not available in this build.")
                }

                GroupBox("Recommended next step") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(recommendationTitle)
                            .font(.headline)
                        Text(recommendationDetail)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .navigationTitle("Home")
    }

    private var latest: FrameSample? {
        guard isFresh else { return nil }
        return sampler.frameSamples.last
    }

    private var isFresh: Bool {
        switch sampler.connectionPhase {
        case .collecting, .missingDiagnosticFields:
            return true
        default:
            return false
        }
    }

    private var freshnessDetail: String {
        isFresh ? "Live X-Plane telemetry" : sampler.connectionPhase.title
    }

    private var stabilityTitle: String {
        guard isFresh else { return sampler.connectionPhase == .connectionLost ? "Telemetry stale" : "Not available yet" }
        guard sampler.liveDiagnosis.statistics != nil else { return "Collecting trend" }
        return sampler.liveDiagnosis.bottleneck == .instability ? "Unstable pacing" : "Stable evidence"
    }

    private var stabilityDetail: String {
        guard isFresh else { return "Fresh telemetry is required before judging stability." }
        return sampler.liveDiagnosis.explanation
    }

    private var airportLabel: String {
        sampler.flightContext.nearestAirportICAO ?? "Not available yet"
    }

    private var airportDetail: String {
        sampler.flightContext.nearestAirportICAO == nil
            ? "No reliable airport identifier has arrived yet."
            : "From X-Plane telemetry or a fresh companion bridge update."
    }

    private var aircraftDetail: String {
        if let identifier = sampler.flightContext.aircraftIdentifier {
            return "Identifier: \(identifier)"
        }
        return sampler.flightContext.aircraftName == nil
            ? "Aircraft identity has not arrived yet."
            : "Name from a fresh companion bridge update."
    }

    private var optimizationMode: String {
        settings.governorModeEnabled ? "Assisted" : "Manual"
    }

    private var packetRate: String {
        String(format: "%.1f", sampler.snapshot.udpStatus.packetsPerSecond)
    }

    private var recommendationTitle: String {
        if !isFresh { return "Restore fresh X-Plane telemetry" }
        if sampler.liveDiagnosis.bottleneck == .insufficientEvidence,
           sampler.liveDiagnosis.statistics != nil {
            return "No action needed"
        }
        return sampler.liveDiagnosis.bottleneck.title
    }

    private var recommendationDetail: String {
        if !isFresh { return "Wait for a fresh X-Plane packet before acting on performance data." }
        if recommendationTitle == "No action needed" {
            return "No sustained bottleneck pattern is established in the current evidence window."
        }
        return sampler.liveDiagnosis.recommendation
    }

    private func metricCard(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 122, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private func contextCard(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct LiveDiagnosisView: View {
    @EnvironmentObject private var sampler: PerformanceSampler

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader("Live Diagnosis", subtitle: "What is limiting X-Plane right now?")

                if sampler.connectionPhase != .collecting {
                    ConnectionCallout(phase: sampler.connectionPhase)
                }

                metrics
                diagnosisCard
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .navigationTitle("Live Diagnosis")
    }

    private var metrics: some View {
        HStack(spacing: 14) {
            metricCard(
                title: "Current FPS",
                value: latest.map { String(format: "%.1f", $0.fps) } ?? "—",
                detail: medianDetail(usesFPS: true)
            )
            metricCard(
                title: "Current frame time",
                value: latest.map { String(format: "%.1f ms", $0.frameTimeMilliseconds) } ?? "—",
                detail: medianDetail(usesFPS: false)
            )
            metricCard(
                title: "Stable trend",
                value: trendLabel,
                detail: "Based on the sustained evidence window"
            )
        }
    }

    private var diagnosisCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(sampler.liveDiagnosis.bottleneck.title)
                        .font(.system(size: 30, weight: .bold))
                    Spacer()
                    Text("\(sampler.liveDiagnosis.confidence.rawValue.capitalized) confidence")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
                }

                Text(sampler.liveDiagnosis.explanation)
                    .font(.title3)

                Divider()
                evidenceRow(title: "Evidence", text: sampler.liveDiagnosis.evidence, symbol: "checkmark.seal")
                evidenceRow(title: "Change one thing", text: sampler.liveDiagnosis.recommendation, symbol: "slider.horizontal.3")
                evidenceRow(title: "How to verify", text: sampler.liveDiagnosis.validation, symbol: "timer")
                evidenceRow(title: "Revert", text: sampler.liveDiagnosis.revert, symbol: "arrow.uturn.backward")
            }
            .padding(8)
        } label: {
            Text("Most likely limiter")
        }
        .accessibilityElement(children: .contain)
    }

    private var latest: FrameSample? {
        guard sampler.connectionPhase == .collecting || sampler.connectionPhase == .missingDiagnosticFields else {
            return nil
        }
        return sampler.frameSamples.last
    }
    private var trendLabel: String {
        guard sampler.connectionPhase == .collecting || sampler.connectionPhase == .missingDiagnosticFields else {
            return "Unavailable"
        }
        guard let stats = sampler.liveDiagnosis.statistics else { return "Collecting" }
        let dispersion = stats.medianAbsoluteDeviationMilliseconds
        if stats.spikeFrequency >= 0.05 { return "Unstable" }
        if dispersion <= 1 { return "Stable" }
        return "Variable"
    }

    private func medianDetail(usesFPS: Bool) -> String {
        guard let stats = sampler.liveDiagnosis.statistics else { return "Waiting for a stable window" }
        return usesFPS
            ? String(format: "%.1f FPS median · %d samples", stats.medianFPS, stats.sampleCount)
            : String(format: "%.1f ms median · %.0f s window", stats.medianMilliseconds, stats.durationSeconds)
    }

    private func metricCard(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
    }

    private func evidenceRow(title: String, text: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

private struct SessionDiagnosisView: View {
    @EnvironmentObject private var sampler: PerformanceSampler
    @EnvironmentObject private var sessionHistory: SessionHistoryStore
    @State private var exportResult: String?
    @State private var selectedRecordID: FlightSessionRecord.ID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    pageHeader("Sessions", subtitle: "Saved flight summaries and current live evidence")
                    Spacer()
                    Menu("Export…") {
                        Button("Session history…") { exportHistory() }
                        Button("Live report…") { exportReport() }
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                }

                savedSessions
                savedSessionDetail
                graph
                summary
                statistics
                changes
                if let exportResult {
                    Text(exportResult).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(28)
            .frame(maxWidth: 1050, alignment: .leading)
        }
        .navigationTitle("Sessions")
    }

    private var savedSessions: some View {
        GroupBox("Saved sessions") {
            if sessionHistory.records.isEmpty {
                ContentUnavailableView(
                    "No completed sessions yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("CruiseControl saves a compact summary when live telemetry becomes stale or stops.")
                )
                .padding(8)
            } else {
                VStack(spacing: 0) {
                    ForEach(sessionHistory.records) { record in
                        Button {
                            selectedRecordID = record.id
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.flightContext.aircraftDisplayName)
                                        .font(.subheadline.weight(.semibold))
                                    Text(sessionContextText(record))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(record.endedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(record.averageFPS.map { String(format: "%.1f FPS", $0) } ?? "FPS unavailable")
                                        .font(.caption.weight(.semibold))
                                }
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(selectedRecordID == record.id ? Color.accentColor.opacity(0.12) : .clear)
                        if record.id != sessionHistory.records.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .onAppear {
            if selectedRecordID == nil {
                selectedRecordID = sessionHistory.records.first?.id
            }
        }
        .onChange(of: sessionHistory.records.map(\.id)) { _, ids in
            if let selectedRecordID, ids.contains(selectedRecordID) { return }
            selectedRecordID = ids.first
        }
    }

    @ViewBuilder
    private var savedSessionDetail: some View {
        if let record = selectedRecord {
            GroupBox("Selected session") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 28) {
                        savedStat("Duration", durationText(record.durationSeconds))
                        savedStat("Average FPS", record.averageFPS.map { String(format: "%.1f", $0) } ?? "—")
                        savedStat("Lowest FPS", record.stability.lowestFPS.map { String(format: "%.1f", $0) } ?? "—")
                        savedStat("Stutters", "\(record.stutterCount)")
                        savedStat("Frame pacing", framePacingText(record))
                    }
                    Text("\(record.flightContext.simulatorVersion.displayName) · \(sessionContextText(record))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let comparison = comparisonRecord(for: record) {
                        Text(comparisonText(record, comparison))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !record.actions.isEmpty {
                        Text("Recorded actions: \(record.actions.map(\.kind).joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Button("Delete selected session", role: .destructive) {
                        sessionHistory.delete(record)
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var selectedRecord: FlightSessionRecord? {
        guard let selectedRecordID else { return nil }
        return sessionHistory.records.first { $0.id == selectedRecordID }
    }

    private var summary: some View {
        GroupBox("Session summary") {
            Text(summaryText)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var summaryText: String {
        guard let stats = sampler.sessionFrameStatistics else {
            return "No defensible session summary is available until valid frame-time samples arrive."
        }
        let p95 = stats.p95Milliseconds.map { String(format: "%.1f ms", $0) } ?? "not yet meaningful"
        return String(
            format: "%d samples over %.0f seconds: %.1f ms median frame time, p95 %@, and %.1f%% spikes. Current conclusion: %@ (%@ confidence).",
            stats.sampleCount,
            stats.durationSeconds,
            stats.medianMilliseconds,
            p95,
            stats.spikeFrequency * 100,
            sampler.liveDiagnosis.bottleneck.title,
            sampler.liveDiagnosis.confidence.rawValue
        )
    }

    private var graph: some View {
        GroupBox("Frame time (milliseconds)") {
            if visibleSamples.isEmpty {
                ContentUnavailableView("No frame-time samples", systemImage: "chart.xyaxis.line", description: Text("Start X-Plane and configure Data Output in Setup."))
                    .frame(height: 280)
            } else {
                Chart(visibleSamples) { sample in
                    LineMark(
                        x: .value("Time", sample.capturedAt),
                        y: .value("Frame time", sample.frameTimeMilliseconds)
                    )
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .foregroundStyle(.blue)
                    .interpolationMethod(.linear)
                }
                .chartYScale(domain: 0...graphMaximum)
                .chartYAxisLabel("ms")
                .frame(height: 300)
                .padding(8)
                .accessibilityLabel("Frame-time graph for the current session")
            }
        }
    }

    private var statistics: some View {
        let stats = sampler.sessionFrameStatistics
        return GroupBox("Useful statistics") {
            HStack(spacing: 28) {
                stat("Median", stats.map { String(format: "%.1f ms", $0.medianMilliseconds) } ?? "—")
                stat("p95", stats?.p95Milliseconds.map { String(format: "%.1f ms", $0) } ?? "Need 20 samples")
                stat("p99", stats?.p99Milliseconds.map { String(format: "%.1f ms", $0) } ?? "Need 100 samples")
                stat("Spikes", stats.map { "\($0.spikeCount) (\(Int($0.spikeFrequency * 100))%)" } ?? "—")
                stat("Variability", stats.map { String(format: "%.1f ms MAD", $0.medianAbsoluteDeviationMilliseconds) } ?? "—")
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var changes: some View {
        GroupBox("Bottleneck changes") {
            if sampler.diagnosticChanges.isEmpty {
                Text("No diagnostic changes yet.").foregroundStyle(.secondary).padding(8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(sampler.diagnosticChanges.suffix(8).reversed()) { change in
                        HStack {
                            Text(change.timestamp, style: .time).monospacedDigit().foregroundStyle(.secondary)
                            Text(change.bottleneck.title)
                            Spacer()
                            Text(change.confidence.rawValue.capitalized).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    private var visibleSamples: [FrameSample] { Array(sampler.frameSamples.suffix(600)) }
    private var graphMaximum: Double {
        let values = visibleSamples.map(\.frameTimeMilliseconds).sorted()
        let p99 = values.isEmpty ? 50 : values[min(Int(Double(values.count - 1) * 0.99), values.count - 1)]
        return max(50, min(250, ceil(p99 * 1.25 / 10) * 10))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
    }

    private func savedStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
    }

    private func sessionContextText(_ record: FlightSessionRecord) -> String {
        [record.flightContext.nearestAirportICAO, record.flightContext.phaseOfFlightDetail]
            .compactMap { $0 }
            .filter { $0 != "Not available yet" }
            .joined(separator: " · ")
            .ifEmpty("Context not available")
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration.rounded())
        return totalSeconds >= 3600
            ? String(format: "%dh %02dm", totalSeconds / 3600, (totalSeconds % 3600) / 60)
            : String(format: "%dm %02ds", totalSeconds / 60, totalSeconds % 60)
    }

    private func framePacingText(_ record: FlightSessionRecord) -> String {
        guard let fraction = record.stability.spikeFraction else { return "—" }
        return String(format: "%.1f%% spikes", fraction * 100)
    }

    private func comparisonRecord(for record: FlightSessionRecord) -> FlightSessionRecord? {
        sessionHistory.records.first { $0.id != record.id }
    }

    private func comparisonText(_ record: FlightSessionRecord, _ comparison: FlightSessionRecord) -> String {
        guard let fps = record.averageFPS, let baselineFPS = comparison.averageFPS else {
            return "Comparison: FPS evidence is unavailable for one of these sessions."
        }
        let delta = fps - baselineFPS
        let direction = delta >= 0 ? "higher" : "lower"
        return String(format: "Compared with the most recent other session: %.1f FPS %@ (%+.1f FPS).", abs(delta), direction, delta)
    }

    @MainActor
    private func exportReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "CruiseControl-diagnostic-report.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let diagnosis = sampler.liveDiagnosis
        let samples: [[String: Any]] = sampler.frameSamples.map {
            var item: [String: Any] = [
                "capturedAt": ISO8601DateFormatter().string(from: $0.capturedAt),
                "monotonicNanoseconds": $0.monotonicNanoseconds,
                "fps": $0.fps,
                "frameTimeMilliseconds": $0.frameTimeMilliseconds
            ]
            item["simulatorCPUTimeMilliseconds"] = $0.simulatorCPUTimeMilliseconds
            item["gpuTimeMilliseconds"] = $0.gpuTimeMilliseconds
            item["hostCPUPercent"] = $0.hostCPUPercent
            return item
        }
        let report: [String: Any] = [
            "schemaVersion": 2,
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "connection": sampler.connectionPhase.rawValue,
            "diagnosis": [
                "bottleneck": diagnosis.bottleneck.rawValue,
                "confidence": diagnosis.confidence.rawValue,
                "explanation": diagnosis.explanation,
                "evidence": diagnosis.evidence,
                "recommendation": diagnosis.recommendation,
                "validation": diagnosis.validation,
                "revert": diagnosis.revert
            ],
            "samples": samples
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            exportResult = "Exported \(samples.count) samples to \(url.lastPathComponent)."
        } catch {
            exportResult = "Export failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func exportHistory() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "CruiseControl-session-history.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try sessionHistory.exportData().write(to: url, options: .atomic)
            exportResult = "Exported \(sessionHistory.records.count) saved session(s) to \(url.lastPathComponent)."
        } catch {
            exportResult = "Export failed: \(error.localizedDescription)"
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}

private struct BenchmarkView: View {
    @EnvironmentObject private var sampler: PerformanceSampler
    @EnvironmentObject private var benchmarkStore: BenchmarkStore
    @State private var name = "X-Plane comparison"
    @State private var selectedPairID: BenchmarkPair.ID?
    @State private var resultMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    pageHeader("Benchmark", subtitle: "Measure one manual change against the same X-Plane view")
                    Spacer()
                    if sampler.benchmarkIsCapturing || sampler.benchmarkNeedsComparison {
                        Button("Discard draft", role: .destructive) { sampler.discardManualBenchmark() }
                    }
                }

                captureControls
                savedPairs
                pairDetail
                if let resultMessage {
                    Text(resultMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(28)
            .frame(maxWidth: 1050, alignment: .leading)
        }
        .navigationTitle("Benchmark")
    }

    private var captureControls: some View {
        GroupBox("Manual capture") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Benchmark name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(sampler.benchmarkIsCapturing || sampler.benchmarkNeedsComparison)
                Text(sampler.benchmarkStatusMessage)
                    .foregroundStyle(.secondary)
                HStack {
                    if sampler.benchmarkIsCapturing {
                        Button("Stop capture") { resultMessage = sampler.stopManualBenchmark().message }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(sampler.benchmarkNeedsComparison ? "Start comparison" : "Start baseline") {
                            resultMessage = sampler.startManualBenchmark(named: name).message
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Text("CruiseControl does not change X-Plane settings or control the aircraft.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }

    private var savedPairs: some View {
        GroupBox("Saved benchmarks") {
            if benchmarkStore.pairs.isEmpty {
                ContentUnavailableView("No saved benchmarks", systemImage: "stopwatch", description: Text("Capture a baseline, make one manual change, then capture the comparison."))
                    .padding(8)
            } else {
                VStack(spacing: 0) {
                    ForEach(benchmarkStore.pairs) { pair in
                        Button { selectedPairID = pair.id } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(pair.name).font(.subheadline.weight(.semibold))
                                    Text(pair.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(fpsDeltaText(pair.averageFPSDelta))
                                    .font(.caption.weight(.semibold))
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(selectedPairID == pair.id ? Color.accentColor.opacity(0.12) : .clear)
                        if pair.id != benchmarkStore.pairs.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .onAppear { selectedPairID = selectedPairID ?? benchmarkStore.pairs.first?.id }
        .onChange(of: benchmarkStore.pairs.map(\.id)) { _, ids in
            if let selectedPairID, ids.contains(selectedPairID) { return }
            selectedPairID = ids.first
        }
    }

    @ViewBuilder
    private var pairDetail: some View {
        if let pair = selectedPair {
            GroupBox("Benchmark result") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 30) {
                        comparisonMetric("Average FPS", baseline: number(pair.baseline.averageFPS), comparison: number(pair.comparison.averageFPS), delta: fpsDeltaText(pair.averageFPSDelta))
                        comparisonMetric("Median frame time", baseline: frameTimeText(pair.baseline.medianFrameTimeMilliseconds), comparison: frameTimeText(pair.comparison.medianFrameTimeMilliseconds), delta: milliseconds(pair.medianFrameTimeDelta))
                        comparisonMetric("Lowest FPS", baseline: number(pair.baseline.lowestFPS), comparison: number(pair.comparison.lowestFPS), delta: fpsDeltaText(pair.comparison.lowestFPS - pair.baseline.lowestFPS))
                        comparisonMetric("Stutters", baseline: "\(pair.baseline.stutterCount)", comparison: "\(pair.comparison.stutterCount)", delta: signed(pair.stutterDelta))
                    }
                    Text(pair.compatibility.summary)
                        .font(.caption)
                        .foregroundStyle(compatibilityColor(pair))
                    Text("Baseline: \(contextText(pair.baseline)) · Comparison: \(contextText(pair.comparison))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Delete benchmark", role: .destructive) { benchmarkStore.delete(pair) }
                        .controlSize(.small)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var selectedPair: BenchmarkPair? {
        guard let selectedPairID else { return nil }
        return benchmarkStore.pairs.first { $0.id == selectedPairID }
    }

    private func comparisonMetric(_ title: String, baseline: String, comparison: String, delta: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(baseline) → \(comparison)").font(.headline).monospacedDigit()
            Text(delta).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func number(_ value: Double) -> String { String(format: "%.1f", value) }
    private func frameTimeText(_ value: Double) -> String { String(format: "%.1f ms", value) }
    private func milliseconds(_ value: Double) -> String { String(format: "%+.1f ms", value) }
    private func signed(_ value: Int) -> String { String(format: "%+d", value) }
    private func fpsDeltaText(_ value: Double) -> String { String(format: "%+.1f FPS", value) }
    private func contextText(_ run: BenchmarkRun) -> String {
        "\(run.flightContext.aircraftDisplayName) · \(run.flightContext.nearestAirportICAO ?? "airport unknown")"
    }
    private func compatibilityColor(_ pair: BenchmarkPair) -> Color {
        if case .questionable = pair.compatibility { return .orange }
        return .secondary
    }
}

private struct OptimizeView: View {
    @EnvironmentObject private var sampler: PerformanceSampler
    @State private var plan: AssistedOptimizationPlan?
    @State private var approvedActionIDs: Set<String> = []
    @State private var executionResult: AssistedPlanExecutionResult?

    var body: some View {
        let recommendation = sampler.optimizationRecommendation
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader("Optimize", subtitle: "One evidence-based next step; CruiseControl will not change settings for you")
                GroupBox("Recommended next step") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(recommendation.title).font(.title3.weight(.semibold))
                        Text(recommendation.reason)
                        Text(recommendation.evidence).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("What this means") {
                    HStack(spacing: 28) {
                        detail("Confidence", recommendation.confidence.rawValue.capitalized)
                        detail("Visual impact", recommendation.visualImpact.rawValue.capitalized)
                        detail("Performance", recommendation.performanceDirection == .likelyImproves ? "Likely improves" : "Validate manually")
                        detail("Restart", recommendation.restartRequired ? "Required" : "Not expected")
                    }
                    .padding(8)
                }
                GroupBox("Apply status") {
                    Text(recommendation.canApplySafely ? "CruiseControl can apply this safely." : "Read-only recommendation. Change it manually in X-Plane or macOS, then use Benchmark to verify the result.")
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
                GroupBox("Assisted plan") {
                    VStack(alignment: .leading, spacing: 12) {
                        if let plan {
                            Text("Review the selected steps before taking action.")
                                .foregroundStyle(.secondary)
                            ForEach(plan.actions) { action in
                                Toggle(isOn: approvalBinding(for: action.id)) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(action.title).font(.headline)
                                        Text(action.reason).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                            Button("Approve selected steps") {
                                executionResult = AssistedOptimizationPlanExecutor().execute(
                                    plan: plan,
                                    approvedActionIDs: approvedActionIDs,
                                    runtime: .unavailable,
                                    writer: nil
                                )
                            }
                            .disabled(approvedActionIDs.isEmpty)

                            if let executionResult, let receipt = executionResult.receipts.first(where: { $0.outcome != .skipped }) {
                                Text(receipt.message).font(.caption).foregroundStyle(.secondary)
                                if receipt.outcome == .manualActionRequired {
                                    Text("After the manual change, use Benchmark with the same X-Plane view to verify it.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            Text("Create a plan to review the current recommendation. CruiseControl only applies settings that a bridge has verified as writable.")
                                .foregroundStyle(.secondary)
                            Button("Create review plan") {
                                let generated = AssistedOptimizationPlanEngine.makePlan(for: recommendation)
                                plan = generated
                                approvedActionIDs = Set(generated.actions.map(\.id))
                                executionResult = nil
                            }
                        }
                    }
                    .padding(8)
                }
            }
            .padding(28)
            .frame(maxWidth: 1050, alignment: .leading)
        }
        .navigationTitle("Optimize")
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline)
        }
    }

    private func approvalBinding(for actionID: String) -> Binding<Bool> {
        Binding(
            get: { approvedActionIDs.contains(actionID) },
            set: { approved in
                if approved { approvedActionIDs.insert(actionID) }
                else { approvedActionIDs.remove(actionID) }
            }
        )
    }
}

private struct SetupDiagnosisView: View {
    @EnvironmentObject private var sampler: PerformanceSampler
    @EnvironmentObject private var settings: SettingsStore
    @State private var testResult: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader("Setup", subtitle: "Connect X-Plane and prove telemetry is usable")
                ConnectionCallout(phase: sampler.connectionPhase)

                GroupBox("X-Plane Data Output") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("1. Open X-Plane → Settings → Data Output.")
                        Text("2. Enable network output for Data Set 0: Frame rate.")
                        Text("3. Set the destination IP to 127.0.0.1.")
                        Text("4. Set the destination port to \(settings.xPlaneUDPPort).")
                        Text("5. Return to the same aircraft and camera view for diagnosis.")
                        Divider()
                        Text("Data Set 0 must include f-act, frame, cpu, and gpu. Data Set 20 is optional and only supports altitude-aware companion features.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .textSelection(.enabled)
                }

                GroupBox("Connection test") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Listener", value: sampler.snapshot.udpStatus.state.displayName)
                        LabeledContent("Packets received", value: "\(sampler.snapshot.udpStatus.totalPackets)")
                        LabeledContent("Invalid packets", value: "\(sampler.snapshot.udpStatus.invalidPackets)")
                        LabeledContent("Locally dropped samples", value: "\(sampler.snapshot.udpStatus.droppedSamples)")
                        LabeledContent("Packet rate", value: String(format: "%.1f / second", sampler.snapshot.udpStatus.packetsPerSecond))
                        if let detail = sampler.snapshot.udpStatus.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Button("Run diagnostic connection test") {
                            testResult = connectionTestSummary
                        }
                        .buttonStyle(.borderedProminent)
                        if let testResult { Text(testResult).font(.callout).textSelection(.enabled) }
                    }
                    .padding(8)
                }

                Text("Advanced telemetry settings, licensing, and updates are available in CruiseControl Settings. They do not block core diagnosis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle("Setup")
    }

    private var connectionTestSummary: String {
        let status = sampler.snapshot.udpStatus
        return "\(sampler.connectionPhase.title). Received \(status.totalPackets) packets; \(status.invalidPackets) were invalid and \(status.droppedSamples) were dropped locally. \(status.detail ?? "No additional detail.")"
    }
}

private struct ConnectionCallout: View {
    let phase: ConnectionPhase

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: phase == .collecting ? "checkmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(phase == .collecting ? .green : .blue)
                .font(.title2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(phase.title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        switch phase {
        case .xPlaneNotRunning: return "Launch X-Plane. CruiseControl will keep listening without polling or modifying the simulator."
        case .awaitingTelemetry: return "The listener is ready but a usable packet has not arrived yet."
        case .incorrectDataOutput: return "Enable X-Plane Data Set 0 and send it to the IP and port shown below."
        case .portConflict: return "Another process owns the configured UDP port. Choose an unused port in Settings and match it in X-Plane."
        case .permissionDenied: return "macOS denied the incoming UDP listener. Check the app’s network entitlement and firewall settings."
        case .malformedOrUnsupported: return "Packets reached CruiseControl, but their header, record layout, or FPS value is invalid."
        case .collecting: return "Fresh frame-rate, simulator CPU, and GPU timing evidence is available."
        case .missingDiagnosticFields: return "Packets are arriving, but CPU/GPU timing is absent or invalid. CruiseControl will not claim CPU- or GPU-bound."
        case .connectionLost: return "Valid telemetry stopped. CruiseControl discarded the stale reading and is waiting to reconnect."
        }
    }
}

@ViewBuilder
private func pageHeader(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.largeTitle.bold())
        Text(subtitle).font(.title3).foregroundStyle(.secondary)
    }
}

struct CruiseControlV2SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var proGate: ProGate

    var body: some View {
        Form {
            Section("Telemetry") {
                Toggle("Listen for X-Plane UDP telemetry", isOn: $settings.xPlaneUDPListeningEnabled)
                LabeledContent("UDP port") {
                    TextField("Port", value: $settings.xPlaneUDPPort, format: .number)
                        .frame(width: 100)
                }
            }
            Section("Updates") {
                Text("Update checks are manual and outside the measurement loop.")
                    .foregroundStyle(.secondary)
                Button("Open releases page") { AppMaintenanceService.openReleasesPage() }
            }
            DisclosureGroup("License") {
                UpgradeSettingsView().environmentObject(proGate)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 600, height: 460)
    }
}
