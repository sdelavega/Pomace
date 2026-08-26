import SwiftUI
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
                historySection
            }
            .padding(16)
        }
        .frame(minWidth: 260, idealWidth: 300)
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Schedule").font(.headline)

            Picker("Sweep", selection: $model.schedule.cadence) {
                ForEach(SweepCadence.allCases) { Text($0.label).tag($0) }
            }
            .onChange(of: model.schedule.cadence) { model.saveSchedule() }

            if model.schedule.cadence != .manual {
                Picker("Around", selection: $model.schedule.preferredHour) {
                    ForEach(0..<24, id: \.self) { h in
                        Text(hourLabel(h)).tag(h)
                    }
                }
                .onChange(of: model.schedule.preferredHour) { model.saveSchedule() }
            }

            // The real service status, not what we asked for.
            HStack(spacing: 6) {
                Image(systemName: model.serviceStatus.isActive
                      ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(model.serviceStatus.isActive ? .green : .secondary)
                Text(model.serviceStatus.explanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .requiresApproval = model.serviceStatus {
                Button("Open Login Items…") { model.openLoginItems() }
                    .controlSize(.small)
            }
            if let error = model.serviceError {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(model.nextSweepDescription)
                .font(.caption).foregroundStyle(.tertiary)

            HStack {
                Toggle("Scheduled sweeps", isOn: Binding(
                    get: { model.serviceStatus.isActive },
                    set: { model.setScheduledSweepsEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            Button {
                model.sweepNow()
            } label: {
                if model.isSweeping {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Sweeping…") }
                } else {
                    Text("Sweep Now")
                }
            }
            .disabled(model.isSweeping || model.selectedPath == nil || !model.toolReady)
            .help("Runs the same sweep the schedule would, right now")
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("History").font(.headline)
            if model.sweepHistory.isEmpty {
                Text("No sweeps yet.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(model.sweepHistory) { run in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run.startedAt, format: .relative(presentation: .named))
                            .font(.caption.weight(.medium))
                        Text(run.summary)
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

    private func hourLabel(_ h: Int) -> String {
        if h == 0 { return "midnight" }
        if h == 12 { return "noon" }
        return h < 12 ? "\(h) AM" : "\(h - 12) PM"
    }
}
