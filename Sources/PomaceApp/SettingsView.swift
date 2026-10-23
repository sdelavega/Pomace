import SwiftUI
import PomaceCore

struct GeneralSettingsView: View {
    @ObservedObject var updates: Updates
    @AppStorage("menuBarEnabled") private var menuBarEnabled = false

    var body: some View {
        Form {
            Toggle(AppStrings.automaticUpdates, isOn: $updates.automaticallyChecksForUpdates)
            Toggle(AppStrings.menuBarItem, isOn: $menuBarEnabled)
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 360)
    }
}

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
                    compressorSection
                    Divider()
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
            Text(AppStrings.compressionSettings).font(.headline)
            Text(AppStrings.settingsExplanation)
                .font(.caption).foregroundStyle(.secondary)

            Picker(AppStrings.mode, selection: $model.mode) {
                ForEach(CompressionMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(model.mode.text).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var compressorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppStrings.compressor).font(.headline)
            Text(model.toolSummary).font(.callout)
            if let installation = model.resolution.installation {
                Text(installation.path).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let rejection = model.customCompressorRejectionText {
                Text(rejection).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(AppStrings.chooseCompressor) { chooseCompressor() }
                Button(AppStrings.useBundled) { model.setCustomCompressor(nil) }
            }
            .disabled(model.isRunning || model.isSweeping || model.confirmingAdministrator)
        }
        .padding(16)
        .onAppear { model.refreshCompressor() }
    }

    private func chooseCompressor() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = AppStrings.choose
        panel.message = AppStrings.chooseCompressorHelp
        if panel.runModal() == .OK, let url = panel.url {
            model.setCustomCompressor(url.path)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Toggle(AppStrings.menuBarItem, isOn: $menuBarEnabled)
                .controlSize(.small)
            if model.overrides != nil {
                Button(AppStrings.resetAutomatic) { model.overrides = nil }
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
                    Text(justification.value.text)
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                    if justification.isFixed {
                        Text(AppStrings.always)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    if justification.isOverridden {
                        Text(AppStrings.overridden)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.tint.opacity(0.2), in: Capsule())
                    }
                }
                Text(justification.reason.text)
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
