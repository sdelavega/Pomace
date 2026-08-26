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
                Stat("Eligible", Fmt.count(result.progress.eligibleFiles, "file"),
                     ByteFormat.short(result.progress.eligibleLogicalBytes))
                Stat("Already compressed", Fmt.count(result.progress.compressedFiles, "file"),
                     ByteFormat.short(result.reclaimedBytes) + " reclaimed")
                Stat("Excluded", Fmt.count(result.progress.excludedFiles, "file"),
                     "for safety")
                Stat("On disk", ByteFormat.short(result.progress.physicalBytes),
                     "of " + ByteFormat.short(result.progress.logicalBytes) + " logical")
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
            return "Nothing left to compress here"
        }
        return "\(Fmt.count(result.progress.eligibleFiles, "file")) could be compressed"
    }

    private var subhead: String {
        var parts = ["\(ByteFormat.short(result.progress.eligibleLogicalBytes)) of eligible data"]
        if result.progress.compressedFiles > 0 {
            parts.append("\(Fmt.percent(result.compressionCoverage)) of this folder is already compressed")
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
        .accessibilityLabel("\(Int(result.compressionCoverage * 100)) percent already compressed")
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
            TableColumn("Name") { entry in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: entry.path))
                        .resizable().frame(width: 14, height: 14)
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(entry.isExcluded ? .secondary : .primary)
                }
            }
            .width(min: 150, ideal: 220)

            TableColumn("Size") { entry in
                Text(ByteFormat.short(entry.logicalSize))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(90)

            TableColumn("On disk") { entry in
                Text(ByteFormat.short(entry.physicalSize))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(90)

            TableColumn("State") { entry in
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
                Text(reason.explanation).lineLimit(1).truncationMode(.tail)
                    .help(reason.explanation)   // full text on hover; the short form elides
            } icon: {
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if entry.isCompressed {
            Label(entry.type?.description ?? "Compressed", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.tint)
        } else if let warning = entry.reasons.first {
            Label {
                Text(warning.explanation).lineLimit(1).truncationMode(.tail)
                    .help(warning.explanation)
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Text("Not compressed").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    @Bindable var model: ScanModel
    let result: ScanResult

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Show excluded", isOn: $model.showExcluded)
                .toggleStyle(.checkbox)
                .controlSize(.small)

            Picker("Sort", selection: $model.sortOrder) {
                ForEach(ScanModel.SortOrder.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .labelsHidden()
            .frame(width: 160)

            Spacer()

            if result.entriesTruncated {
                Label("Showing first \(ScanEngine.maxRetainedEntries.formatted()) files — totals cover everything",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if result.hardLinkDuplicates > 0 {
                Text("\(Fmt.count(result.hardLinkDuplicates, "hard link")) counted once")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("These paths share storage with another file, so their bytes are counted only once.")
            }
            Text(String(format: "Scanned in %.1fs", result.duration))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}
