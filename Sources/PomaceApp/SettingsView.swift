import SwiftUI
import PomaceCore

/// Settings → Advanced, on the Xcode build-settings model (ADR-0009).
///
/// The pane's primary job is DIAGNOSTIC. Seeing what Pomace decided and why is what makes
/// the automatic behaviour trustworthy rather than opaque; overriding is almost a side
/// effect. Rows marked fixed are safety properties and cannot be changed at any tier.
struct AdvancedSettingsView: View {
    @Bindable var model: ScanModel

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
        .frame(width: 560, height: 460)
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

/// Shown when the compressor is missing. The license disclosure is not optional — Pomace is about
/// to install third-party GPL software on the user's behalf (ADR-0003).
struct InstallToolView: View {
    @Bindable var model: ScanModel
    @State private var installing = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Pomace needs \(CompressorTool.displayName)").font(.headline)
            Text("""
                 \(CompressorTool.displayName) is the tool that actually applies compression. \
                 Pomace can install it for you with Homebrew, or you can install it yourself.
                 """)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)

            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Text("About to install").font(.caption.weight(.medium))
                    Text("applesauce, by Zachary Dremann")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Licensed GPL-3.0 — separate software, not part of Pomace")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Installed via: brew install \(ToolInstaller.homebrewFormula)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 420)

            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }

            HStack {
                Button("Install with Homebrew") { install() }
                    .buttonStyle(.borderedProminent)
                    .disabled(installing || !ToolInstaller.homebrewAvailable)
                Button("Check Again") { model.refreshInstallation() }
                    .disabled(installing)
            }
            if !ToolInstaller.homebrewAvailable {
                Text("Homebrew isn't installed, so Pomace can't install \(CompressorTool.displayName) automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if installing { ProgressView().controlSize(.small) }
        }
        .padding(28)
    }

    private func install() {
        installing = true
        message = "Installing…"
        Task {
            let result = await ToolInstaller.installViaHomebrew()
            installing = false
            switch result {
            case .success:
                model.refreshInstallation()
                message = model.toolReady ? nil : "Installed, but Pomace still can't find it."
            case .failure(let error):
                message = error
            }
        }
    }
}
