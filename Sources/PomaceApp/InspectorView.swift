import SwiftUI
import Charts
import PomaceCore

/// Per-folder schedule and sweep history.
///
/// History is what makes drift legible: without it, "your folder decayed 8% last month" is
/// invisible and the watching feature looks like it isn't earning its keep (PRD §5.4).
struct InspectorView: View {
    @Bindable var model: ScanModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                scheduleSection
                Divider()
                trendSection
                Divider()
                historySection
            }
            .padding(16)
        }
        .frame(minWidth: 260, idealWidth: 300)
    }

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppStrings.compressionTrend).font(.headline)
            if model.snapshotHistory.isEmpty {
                Text(AppStrings.firstScanBaseline)
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Chart(model.snapshotHistory, id: \.scannedAt) { snapshot in
                    LineMark(
                        x: .value(AppStrings.scan, snapshot.scannedAt),
                        y: .value(AppStrings.compressedState, snapshot.compressionCoverage)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.tint)

                    PointMark(
                        x: .value(AppStrings.scan, snapshot.scannedAt),
                        y: .value(AppStrings.compressedState, snapshot.compressionCoverage)
                    )
                    .foregroundStyle(.tint)
                }
                .chartYScale(domain: 0...1)
                .chartYAxis {
                    AxisMarks(values: [0, 0.5, 1]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let coverage = value.as(Double.self) {
                                Text(Fmt.percent(coverage))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3))
                }
                .frame(height: 120)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(AppStrings.coverageOverTime)
                .accessibilityValue(trendSummary)
                .accessibilityChildren {
                    ForEach(model.snapshotHistory, id: \.scannedAt) { snapshot in
                        Text(AppStrings.accessibilityDetail(
                            snapshot.scannedAt.formatted(date: .abbreviated, time: .shortened),
                            AppStrings.reclaimedDetail(Fmt.bytes(snapshot.reclaimedBytes))))
                    }
                }

                Text(trendSummary)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppStrings.schedule).font(.headline)

            Picker(AppStrings.sweep, selection: $model.schedule.cadence) {
                ForEach(SweepCadence.allCases) { Text($0.text).tag($0) }
            }
            .accessibilityLabel(AppStrings.sweep)
            .onChange(of: model.schedule.cadence) { model.saveSchedule() }

            if model.schedule.cadence != .manual {
                Picker(AppStrings.around, selection: $model.schedule.preferredHour) {
                    ForEach(0..<24, id: \.self) { h in
                        Text(Fmt.hour(h)).tag(h)
                    }
                }
                .accessibilityLabel(AppStrings.around)
                .onChange(of: model.schedule.preferredHour) { model.saveSchedule() }
            }

            // The real service status, not what we asked for.
            HStack(spacing: 6) {
                Image(systemName: model.serviceStatus.isActive
                      ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(model.serviceStatus.isActive ? .green : .secondary)
                    .accessibilityHidden(true)
                Text(model.serviceStatus.text)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AppStrings.scheduledSweeps)
            .accessibilityValue(model.serviceStatus.text)

            if case .requiresApproval = model.serviceStatus {
                Button(AppStrings.openLoginItems) { model.openLoginItems() }
                    .controlSize(.small)
            }
            if let error = model.serviceError {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(model.nextSweepDescription)
                .font(.caption).foregroundStyle(.tertiary)

            HStack {
                Toggle(AppStrings.backgroundService, isOn: Binding(
                    get: { model.serviceStatus.isActive },
                    set: { model.setScheduledSweepsEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(AppStrings.backgroundService)
            }

            Button {
                model.sweepNow()
            } label: {
                if model.isSweeping {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(AppStrings.sweeping) }
                } else {
                    Text(AppStrings.sweepNow)
                }
            }
            .disabled(model.isSweeping || model.selectedPath == nil || !model.toolReady)
            .help(AppStrings.sweepNowHelp)
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppStrings.history).font(.headline)
            if model.sweepHistory.isEmpty {
                Text(AppStrings.noSweeps)
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(model.sweepHistory) { run in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run.startedAt, format: .relative(presentation: .named))
                            .font(.caption.weight(.medium))
                        Text(run.text)
                            .font(.caption2)
                            .foregroundStyle(run.deferral != nil || run.error != nil
                                             ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var trendSummary: String {
        guard let latest = model.snapshotHistory.last else { return "" }
        let reclaimed = AppStrings.currentlyReclaimed(Fmt.bytes(latest.reclaimedBytes))
        guard let first = model.snapshotHistory.first, first.scannedAt != latest.scannedAt else {
            return AppStrings.trendCompressed(Fmt.percent(latest.compressionCoverage), reclaimed)
        }
        let points = latest.compressionCoverage - first.compressionCoverage
        guard abs(points) >= 0.005 else {
            return AppStrings.trendSteady(Fmt.percent(latest.compressionCoverage), reclaimed)
        }
        return points > 0
            ? AppStrings.trendRose(Fmt.percent(abs(points)), reclaimed)
            : AppStrings.trendFell(Fmt.percent(abs(points)), reclaimed)
    }
}
