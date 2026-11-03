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
                .aetherSurface()
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(minWidth: 460, idealWidth: 560, maxWidth: 680,
               minHeight: 360, idealHeight: 460, maxHeight: 640)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            AetherBadge(text: "POMACE // PREFERENCES")
            Text("Compression Settings").font(.system(size: 22, weight: .semibold))
                .tracking(-0.33)
            Text("Pomace chooses these for you. Everything below shows what it picked and why.")
                .font(.system(size: 12)).foregroundStyle(Aether.muted)

            Picker("Mode", selection: $model.mode) {
                ForEach(CompressionMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(model.mode.explanation).font(.system(size: 12)).foregroundStyle(Aether.muted)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.toolSummary).font(.system(size: 12))
                if let i = model.installation {
                    Text(i.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(Aether.muted)
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
                        AetherBadge(text: "Always")
                    }
                    if justification.isOverridden {
                        AetherBadge(text: "Overridden")
                    }
                }
                Text(justification.reason)
                    .font(.system(size: 12))
                    .foregroundStyle(Aether.muted)
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
            AetherBadge(text: "COMPRESSOR SETUP")
            Image(systemName: "shippingbox").font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Aether.accent)
            Text("Pomace needs \(CompressorTool.displayName)").font(.headline)
            Text("""
                 \(CompressorTool.displayName) is the tool that actually applies compression. \
                 Pomace can install it for you with Homebrew, or you can install it yourself.
                 """)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(Aether.muted)
                .frame(maxWidth: 420)

            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Text("About to install").font(.caption.weight(.medium))
                    Text("applesauce, by Zachary Dremann")
                        .font(.system(size: 12)).foregroundStyle(Aether.muted)
                    Text("Licensed GPL-3.0 — separate software, not part of Pomace")
                        .font(.system(size: 12)).foregroundStyle(Aether.muted)
                    Text("Installed via: brew install \(ToolInstaller.homebrewFormula)")
                        .font(Aether.metadata)
                        .foregroundStyle(Aether.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 420)

            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(Aether.muted)
                    .frame(maxWidth: 420)
            }

            HStack {
                Button("Install with Homebrew") { install() }
                    .buttonStyle(AetherPrimaryButtonStyle())
                    .disabled(installing || !ToolInstaller.homebrewAvailable)
                Button("Check Again") { model.refreshInstallation() }
                    .disabled(installing)
            }
            if !ToolInstaller.homebrewAvailable {
                Text("Homebrew isn't installed, so Pomace can't install \(CompressorTool.displayName) automatically.")
                    .font(.system(size: 12)).foregroundStyle(Aether.muted)
            }
            if installing { ProgressView().controlSize(.small) }
        }
        .padding(28)
        .aetherSurface()
        .padding(24)
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
