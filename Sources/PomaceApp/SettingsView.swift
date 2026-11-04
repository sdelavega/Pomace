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
        .aetherTheme()
    }
}

/// Diagnostic settings preserve the automatic plan and its fixed safety properties.
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
                .aetherSurface()
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(minWidth: 460, idealWidth: 560, maxWidth: 680,
               minHeight: 360, idealHeight: 460, maxHeight: 640)
        .aetherTheme()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppStrings.compressionSettings).font(.system(size: 22, weight: .semibold))
                .tracking(-0.33)
            Text(AppStrings.settingsExplanation)
                .font(.system(size: 12)).foregroundStyle(Aether.muted)
            Picker(AppStrings.mode, selection: $model.mode) {
                ForEach(CompressionMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: model.mode) { model.persistMode() }
            Text(model.mode.text).font(.system(size: 12)).foregroundStyle(Aether.muted)
        }
        .padding(16)
    }

    private var compressorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppStrings.compressor).font(.headline)
            Text(model.toolSummary).font(.callout)
            if let installation = model.resolution.installation {
                Text(installation.path).font(.system(size: 12)).foregroundStyle(Aether.muted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let rejection = model.customCompressorRejectionText {
                Text(rejection).font(.system(size: 12)).foregroundStyle(Aether.muted)
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
                        AetherBadge(text: AppStrings.always)
                    }
                    if justification.isOverridden {
                        AetherBadge(text: AppStrings.overridden)
                    }
                }
                Text(justification.reason.text)
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
