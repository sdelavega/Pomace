import SwiftUI
import PomaceCore

/// Settings → Advanced, on the Xcode build-settings model (ADR-0009).
///
/// The pane's primary job is DIAGNOSTIC. Seeing what Pomace decided and why is what makes
/// the automatic behaviour trustworthy rather than opaque; overriding is almost a side
/// effect. Rows marked fixed are safety properties and cannot be changed at any tier.
struct AdvancedSettingsView: View {
    @Bindable var model: ScanModel
    @AppStorage("menuBarEnabled") private var menuBarEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.plan.justifications) { j in
                        JustificationRow(justification: j)
                        Divider()
                    }
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 460, idealWidth: 560, maxWidth: 680,
               minHeight: 360, idealHeight: 460, maxHeight: 640)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Compression Settings").font(.headline)
            Text("Pomace chooses these for you. Everything below shows what it picked and why.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("Mode", selection: $model.mode) {
                ForEach(CompressionMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(model.mode.explanation).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.toolSummary).font(.caption)
                if let i = model.installation {
                    Text(i.path).font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Toggle("Show menu bar item", isOn: $menuBarEnabled)
                .controlSize(.small)
            if model.overrides != nil {
                Button("Reset to Automatic") { model.overrides = nil }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct JustificationRow: View {
    let justification: Justification

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(justification.label)
                .font(.callout)
                .frame(width: 120, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(justification.value)
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                    if justification.isFixed {
                        Text("Always")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    if justification.isOverridden {
                        Text("Overridden")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.tint.opacity(0.2), in: Capsule())
                    }
                }
                Text(justification.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}

/// Shown when neither compressor source is usable.
struct InstallToolView: View {
    @Bindable var model: ScanModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Pomace needs \(CompressorTool.displayName)").font(.headline)
            Text("The compressor is unavailable. Pomace can still scan your files.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Button("Check Again") { model.refreshInstallation() }
        }
        .padding(28)
    }
}
