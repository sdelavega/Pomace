import SwiftUI
import AppKit
import PomaceCore

struct ResultView: View {
    @Bindable var model: ScanModel
    let result: ScanResult

    var body: some View {
        // Anchor the result to the space offered by the split view. Table's ideal content
        // height must never enlarge the window's layout and push the overview above its top.
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ScanOverview(model: model, result: result, availableSize: geometry.size)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .padding(12)

                FileTable(model: model, result: result)
                    .frame(minHeight: 0, maxHeight: .infinity)
                    .aetherSurface()
                    .padding(.horizontal, 16)
                StatusBar(model: model, result: result)
                    .background(Aether.canvas)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
    }
}

// MARK: - Summary

/// Intrinsic height, with no scroll container or table-dependent size proposal.
/// Keep this separate so minimum-window layouts can be measured in regression tests.
struct ScanOverview: View {
    @Bindable var model: ScanModel
    let result: ScanResult
    let availableSize: CGSize

    private var compact: Bool { availableSize.width < 640 || availableSize.height < 620 }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            SummaryHeader(result: result, columns: availableSize.width < 640 ? 2 : 4,
                          compact: compact)
            Divider()
            ActionBar(model: model, inlineMode: availableSize.width >= 640)
            RunBanner(model: model)
        }
        .padding(compact ? 12 : 16)
        .aetherSurface()
    }
}

private struct SummaryHeader: View {
    let result: ScanResult
    let columns: Int
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.system(size: compact ? 18 : 22, weight: .semibold))
                    .tracking(-0.27)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subhead)
                    .font(.system(size: 12))
                    .foregroundStyle(Aether.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CoverageBar(result: result)
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                if columns == 4 {
                    GridRow { metrics }
                } else {
                    GridRow {
                        eligibleMetric
                        compressedMetric
                    }
                    GridRow {
                        excludedMetric
                        diskMetric
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var metrics: some View {
        eligibleMetric
        compressedMetric
        excludedMetric
        diskMetric
    }

    private var eligibleMetric: some View {
        Stat("Eligible", Fmt.count(result.progress.eligibleFiles, "file"),
             ByteFormat.short(result.progress.eligibleLogicalBytes))
    }

    private var compressedMetric: some View {
        Stat("Compressed", Fmt.count(result.progress.compressedFiles, "file"),
             ByteFormat.short(result.reclaimedBytes) + " reclaimed")
    }

    private var excludedMetric: some View {
        Stat("Excluded", Fmt.count(result.progress.excludedFiles, "file"), "for safety")
    }

    private var diskMetric: some View {
        Stat("On disk", ByteFormat.short(result.progress.physicalBytes),
             "of " + ByteFormat.short(result.progress.logicalBytes) + " logical")
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
        "\(Fmt.percent(result.compressionCoverage)) compressed · \(ByteFormat.short(result.progress.eligibleLogicalBytes)) eligible"
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
                segment(Aether.accent, compressed, geo.size.width)
                segment(Aether.accent.opacity(0.35), eligible, geo.size.width)
                segment(Aether.muted.opacity(0.18), excluded, geo.size.width)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Compression coverage")
        .accessibilityValue("\(Fmt.percent(result.compressionCoverage)) compressed, \(Fmt.count(result.progress.eligibleFiles, "file")) eligible, \(Fmt.count(result.progress.excludedFiles, "file")) excluded for safety")
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
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 12)).foregroundStyle(Aether.muted)
            Text(value).font(.system(size: 15, weight: .semibold, design: .monospaced))
                .monospacedDigit()
            Text(detail).font(.system(size: 12)).foregroundStyle(Aether.muted)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Aether.well.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
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
                    .monospacedDigit().foregroundStyle(Aether.muted)
            }
            .width(90)

            TableColumn("On disk") { entry in
                Text(ByteFormat.short(entry.physicalSize))
                    .monospacedDigit().foregroundStyle(Aether.muted)
            }
            .width(90)

            TableColumn("State") { entry in
                StateCell(entry: entry)
            }
            .width(min: 200, ideal: 320)
        }
        .tableStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Aether.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
                Image(systemName: "minus.circle").foregroundStyle(Aether.muted)
            }
            .font(.system(size: 12))
            .foregroundStyle(Aether.muted)
        } else if entry.isCompressed {
            Label(entry.type?.description ?? "Compressed", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.tint)
        } else if let warning = entry.reasons.first {
            Label {
                Text(warning.explanation).lineLimit(1).truncationMode(.tail)
                    .help(warning.explanation)
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Aether.warning)
            }
            .font(.system(size: 12))
            .foregroundStyle(Aether.muted)
        } else {
            Text("Not compressed").font(.system(size: 12)).foregroundStyle(Aether.muted)
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
                    .font(.system(size: 12)).foregroundStyle(Aether.muted)
            }
            if result.hardLinkDuplicates > 0 {
                Text("\(Fmt.count(result.hardLinkDuplicates, "hard link")) counted once")
                    .font(.system(size: 12)).foregroundStyle(Aether.muted)
                    .help("These paths share storage with another file, so their bytes are counted only once.")
            }
            Text(String(format: "Scanned in %.1fs", result.duration))
                .font(.system(size: 12)).foregroundStyle(Aether.muted).monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}
