import SwiftUI
import Charts
import PomaceCore

/// Per-folder schedule and sweep history.
///
/// History is what makes drift legible: without it, "your folder decayed 8% last month" is
/// invisible and the watching feature looks like it isn't earning its keep (PRD §5.4).
struct InspectorView: View {
    @Bindable var model: ScanModel
    @State private var newExclusion = ""
    @State private var exclusionInvalid = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AetherBadge(text: AppStrings.scheduleHelp)
                scheduleSection
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .aetherSurface()
                estimateSection
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .aetherSurface()
                exclusionsSection
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .aetherSurface()
                trendSection
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .aetherSurface()
                historySection
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .aetherSurface()
            }
            .padding(16)
        }
        .frame(minWidth: 280, idealWidth: 320)
    }

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppStrings.compressionTrend).font(.headline)
            if model.snapshotHistory.isEmpty {
                Text(AppStrings.firstScanBaseline)
                    .font(.system(size: 12)).foregroundStyle(Aether.muted)
            } else {
                Chart(model.snapshotHistory, id: \.scannedAt) { snapshot in
                    AreaMark(
                        x: .value(AppStrings.scan, snapshot.scannedAt),
                        y: .value(AppStrings.compressedState, snapshot.compressionCoverage)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(colors: [Aether.accent.opacity(0.4), Aether.accent.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))

                    LineMark(
                        x: .value(AppStrings.scan, snapshot.scannedAt),
                        y: .value(AppStrings.compressedState, snapshot.compressionCoverage)
                    )
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(Aether.accent)

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
                    .font(.system(size: 12)).foregroundStyle(Aether.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.expansion.reExpandedBytes > 0 {
                Text(AppStrings.expansionSummary(Fmt.bytes(model.expansion.reExpandedBytes)))
                    .font(.system(size: 12)).foregroundStyle(Aether.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.expansion.suggestsManualSchedule,
               let path = model.selectedPath, model.isScheduled(path) {
                Text(AppStrings.expansionSuggestion)
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button(AppStrings.expansionSwitch) { model.switchToManualSchedule() }
                    .controlSize(.small)
            }
        }
    }

    private var estimateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppStrings.estimateTitle).font(.headline)
            if model.isEstimating {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(AppStrings.estimateRunning) }
                    .font(.system(size: 12))
            } else if let estimate = model.estimate {
                Text(AppStrings.estimateResult(Fmt.bytes(estimate.recommendedReclaim),
                                               estimate.recommendedCompressor.uppercased()))
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(estimate.measurements, id: \.compressor) { measurement in
                    Text(AppStrings.estimateRow(measurement.compressor.uppercased(),
                                                Fmt.bytes(estimate.estimatedReclaim(for: measurement.compressor) ?? 0)))
                        .font(.system(size: 12)).monospacedDigit()
                }
                Text(AppStrings.estimateBasis(Fmt.bytes(estimate.sampleBytes)))
                    .font(.system(size: 12)).foregroundStyle(Aether.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if model.mode == .automatic {
                    Text(AppStrings.estimateApplied(estimate.recommendedCompressor.uppercased()))
                        .font(.system(size: 12)).foregroundStyle(Aether.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if model.estimateFailed {
                Text(AppStrings.estimateUnavailable)
                    .font(.system(size: 12)).foregroundStyle(Aether.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(AppStrings.estimateAction) { model.estimateSavings() }
                .controlSize(.small)
                .disabled(!model.canEstimate)
                .help(AppStrings.estimateHelp)
        }
    }

    private var exclusionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppStrings.exclusionsTitle).font(.headline)
            Text(AppStrings.exclusionsHelp)
                .font(.system(size: 12)).foregroundStyle(Aether.muted)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.exclusions, id: \.self) { pattern in
                HStack(spacing: 6) {
                    Text(verbatim: pattern)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button {
                        model.removeExclusion(pattern)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(AppStrings.exclusionsRemove(pattern))
                    .help(AppStrings.exclusionsRemove(pattern))
                }
            }
            HStack(spacing: 6) {
                TextField(AppStrings.exclusionsPlaceholder, text: $newExclusion)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(addExclusion)
                    .onChange(of: newExclusion) { exclusionInvalid = false }
                Button(AppStrings.exclusionsAdd, action: addExclusion)
                    .controlSize(.small)
                    .disabled(newExclusion.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if exclusionInvalid {
                Text(AppStrings.exclusionsInvalid)
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(model.selectedPath == nil || model.isRunning || model.isSweeping)
    }

    private func addExclusion() {
        if model.addExclusion(newExclusion) {
            newExclusion = ""
        } else {
            exclusionInvalid = true
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
                    .foregroundStyle(model.serviceStatus.isActive ? Aether.accent : Aether.muted)
                    .accessibilityHidden(true)
                Text(model.serviceStatus.text)
                    .font(.system(size: 12)).foregroundStyle(Aether.muted)
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
                Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(model.nextSweepDescription)
                .font(.system(size: 12)).foregroundStyle(Aether.muted)

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
                    .font(.system(size: 12)).foregroundStyle(Aether.muted)
            } else {
                ForEach(model.sweepHistory) { run in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run.startedAt, format: .relative(presentation: .named))
                            .font(.caption.weight(.medium))
                        Text(run.text)
                            .font(.system(size: 12))
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
