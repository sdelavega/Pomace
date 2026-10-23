import SwiftUI
import AppKit
import PomaceCore

struct ResultView: View {
    @Bindable var model: ScanModel
    let result: ScanResult

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                SummaryHeader(result: result)
                    .padding(.bottom, -6)
                ActionBar(model: model).padding(.horizontal, 20)
                RunBanner(model: model).padding(.horizontal, 20)
            }
            .padding(.bottom, 14)
            Divider()
            FileTable(model: model, result: result)
            Divider()
            StatusBar(model: model, result: result)
        }
    }
}

// MARK: - Summary

private struct SummaryHeader: View {
    let result: ScanResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.system(.title2, weight: .semibold))
                    Text(subhead)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            CoverageBar(result: result)

            HStack(spacing: 22) {
                Stat(AppStrings.eligible, AppStrings.files(result.progress.eligibleFiles),
                     Fmt.bytes(result.progress.eligibleLogicalBytes))
                Stat(AppStrings.alreadyCompressed, AppStrings.files(result.progress.compressedFiles),
                     AppStrings.reclaimedDetail(Fmt.bytes(result.reclaimedBytes)))
                Stat(AppStrings.excluded, AppStrings.files(result.progress.excludedFiles),
                     AppStrings.forSafety)
                Stat(AppStrings.onDisk, Fmt.bytes(result.progress.physicalBytes),
                     AppStrings.logicalSize(Fmt.bytes(result.progress.logicalBytes)))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    /// Deliberately does NOT promise a figure. Estimating real savings needs sampling, which
    /// is M2 — claiming a number here we haven't measured would be the one thing that loses
    /// the user's trust permanently.
    private var headline: String {
        if result.progress.eligibleFiles == 0 {
            return AppStrings.nothingToCompress
        }
        return AppStrings.couldCompress(result.progress.eligibleFiles)
    }

    private var subhead: String {
        var parts = [AppStrings.eligibleData(Fmt.bytes(result.progress.eligibleLogicalBytes))]
        if result.progress.compressedFiles > 0 {
            parts.append(AppStrings.folderCompressed(Fmt.percent(result.compressionCoverage)))
        }
        return parts.joined(separator: " · ")
    }
}

private struct CoverageBar: View {
    let result: ScanResult

    var body: some View {
        GeometryReader { geo in
            let total = max(1, result.progress.filesSeen)
            let compressed = Double(result.progress.compressedFiles) / Double(total)
            let excluded = Double(result.progress.excludedFiles) / Double(total)
            let eligible = max(0, 1 - compressed - excluded)

            HStack(spacing: 1) {
                segment(.accentColor, compressed, geo.size.width)
                segment(Color.secondary.opacity(0.45), eligible, geo.size.width)
                segment(Color.secondary.opacity(0.18), excluded, geo.size.width)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppStrings.compressionCoverage)
        .accessibilityValue(AppStrings.coverage(Fmt.percent(result.compressionCoverage),
                                              AppStrings.files(result.progress.eligibleFiles),
                                              AppStrings.files(result.progress.excludedFiles)))
    }

    @ViewBuilder
    private func segment(_ color: Color, _ fraction: Double, _ width: CGFloat) -> some View {
        if fraction > 0 { color.frame(width: max(1, width * fraction)) }
    }
}

private struct Stat: View {
    let label: String, value: String, detail: String
    init(_ l: String, _ v: String, _ d: String) { label = l; value = v; detail = d }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, weight: .medium)).monospacedDigit()
            Text(detail).font(.caption2).foregroundStyle(.tertiary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - File table

private struct FileTable: View {
    @Bindable var model: ScanModel
    let result: ScanResult

    var body: some View {
        Table(model.visibleEntries) {
            TableColumn(AppStrings.name) { entry in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: entry.path))
                        .resizable().frame(width: 14, height: 14)
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(entry.isExcluded ? .secondary : .primary)
                }
            }
            .width(min: 150, ideal: 220)

            TableColumn(AppStrings.size) { entry in
                Text(Fmt.bytes(entry.logicalSize))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(90)

            TableColumn(AppStrings.onDisk) { entry in
                Text(Fmt.bytes(entry.physicalSize))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(90)

            TableColumn(AppStrings.state) { entry in
                StateCell(entry: entry)
            }
            .width(min: 200, ideal: 320)
        }
        .tableStyle(.inset)
    }
}

private struct StateCell: View {
    let entry: ScanEntry

    var body: some View {
        if let reason = entry.reasons.first(where: { $0.isHardExclusion }) {
            Label {
                Text(reason.text).lineLimit(1).truncationMode(.tail)
                    .help(reason.text)   // full text on hover; the short form elides
            } icon: {
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if entry.isCompressed {
            Label(entry.type?.text ?? AppStrings.compressedState, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.tint)
        } else if let warning = entry.reasons.first {
            Label {
                Text(warning.text).lineLimit(1).truncationMode(.tail)
                    .help(warning.text)
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Text(AppStrings.notCompressed).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    @Bindable var model: ScanModel
    let result: ScanResult

    var body: some View {
        HStack(spacing: 12) {
            Toggle(AppStrings.showExcluded, isOn: $model.showExcluded)
                .toggleStyle(.checkbox)
                .controlSize(.small)

            Picker(AppStrings.sort, selection: $model.sortOrder) {
                ForEach(ScanModel.SortOrder.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .labelsHidden()
            .frame(width: 160)

            Spacer()

            if result.entriesTruncated {
                Label(AppStrings.truncatedFiles(ScanEngine.maxRetainedEntries), systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if result.hardLinkDuplicates > 0 {
                Text(AppStrings.hardLinksCountedOnce(result.hardLinkDuplicates))
                    .font(.caption).foregroundStyle(.secondary)
                    .help(AppStrings.hardLinkHelp)
            }
            Text(AppStrings.scannedIn(result.duration))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}
