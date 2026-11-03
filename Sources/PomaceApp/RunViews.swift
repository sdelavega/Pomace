import SwiftUI
import PomaceCore

/// The action row: compress, decompress, and the mode picker.
///
/// Decompress sits beside compress rather than buried in a menu — the PRD's promise is that
/// anything Pomace does it can undo, and an undo you can't find isn't one. It is still never
/// a single click: it opens a confirmation naming the exact file count (SAFETY.md §4 rule 2).
struct ActionBar: View {
    @Bindable var model: ScanModel
    var inlineMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if inlineMode {
                HStack(spacing: 12) {
                    operationButtons
                    Spacer(minLength: 0)
                    modePicker
                }
            } else {
                HStack(spacing: 10) { operationButtons }
                modePicker
            }
            if model.administratorAvailable {
                Toggle("Use administrator privileges", isOn: $model.useAdministratorPrivileges)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .disabled(model.isRunning || model.isSweeping)
                    .help("Authorize compression or decompression of protected Homebrew and application files. macOS handles authentication.")
            }
        }
    }

    @ViewBuilder
    private var operationButtons: some View {
        Button {
            model.startCompress()
        } label: {
            Label("Compress", systemImage: "arrow.down.right.and.arrow.up.left")
        }
        .buttonStyle(AetherPrimaryButtonStyle())
        .controlSize(.large)
        .fixedSize()
        .disabled(model.compressibleCount == 0 || !model.toolReady || model.isRunning)
        .help(model.toolReady
              ? "Compress \(Fmt.count(model.compressibleCount, "eligible file"))"
              : "\(CompressorTool.displayName) isn't available")

        Button {
            model.requestDecompress()
        } label: {
            Label("Decompress", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .controlSize(.large)
        .fixedSize()
        .disabled(model.compressedCount == 0 || !model.toolReady || model.isRunning)
    }

    private var modePicker: some View {
        Picker("Mode", selection: $model.mode) {
            ForEach(CompressionMode.allCases) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        // Keep the mode control on its own row so both operation labels remain visible.
        .frame(minWidth: 200, idealWidth: 260, maxWidth: 300)
        .disabled(model.isRunning)
        .help(model.mode.explanation)
    }
}

/// Progress and outcome. Deliberately inline rather than a modal sheet — a long run must not
/// block the window (PRD §6).
struct RunBanner: View {
    @Bindable var model: ScanModel

    var body: some View {
        switch model.runState {
        case .none:
            EmptyView()

        case .running(let op, let progress):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(op.verb) — \(Fmt.count(progress.filesProcessed, "file")) of \(progress.filesTotal.formatted())")
                        .font(.callout).monospacedDigit()
                    Spacer()
                    Button(model.isStopping ? "Stopping…" : "Stop") { model.cancelRun() }
                        .controlSize(.small)
                        .disabled(model.isStopping)
                }
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                if model.isStopping {
                    Text("Waiting for the active batch to finish safely. No further batches will start.")
                        .font(.system(size: 12)).foregroundStyle(Aether.muted)
                }
                if let p = progress.currentPath {
                    Text("Current batch starts with: \(p)").font(.system(size: 12)).foregroundStyle(Aether.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
                if progress.failures > 0 {
                    Text("\(Fmt.count(progress.failures, "file")) couldn't be processed — details when this finishes")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                }
            }
            .padding(12)
            .background(Aether.well.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))

        case .finished(let outcome):
            OutcomeBanner(outcome: outcome) { model.dismissRunResult() }

        case .refused(let message):
            Label(message, systemImage: "exclamationmark.circle")
                .font(.callout)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Aether.well.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct OutcomeBanner: View {
    let outcome: CompressionOutcome
    let onDismiss: () -> Void
    @State private var showingFailures = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: icon).foregroundStyle(tint).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.callout.weight(.medium))
                    Text(detail).font(.system(size: 12)).foregroundStyle(Aether.muted)
                }
                Spacer()
                if !outcome.failures.isEmpty {
                    Button(showingFailures ? "Hide details" : "Show details") {
                        showingFailures.toggle()
                    }
                    .controlSize(.small)
                }
                Button("Done", action: onDismiss).controlSize(.small)
            }

            if showingFailures {
                // Every failure names the file and says what to do next. An error the user
                // can't act on is only half-reported.
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        // Real problems first; the tool declining a file politely is not one.
                        ForEach(outcome.realFailures + outcome.skipped) { f in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: f.kind == .failed
                                      ? "exclamationmark.triangle.fill" : "minus.circle")
                                    .foregroundStyle(f.kind == .failed ? .orange : .secondary)
                                    .font(.system(size: 12))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((f.path as NSString).lastPathComponent)
                                        .font(.system(size: 12, weight: .medium))
                                    Text(f.message).font(.system(size: 12)).foregroundStyle(Aether.muted)
                                    Text(f.remedy).font(.system(size: 12)).foregroundStyle(Aether.muted)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 130)
            }
        }
        .padding(12)
        .background(Aether.well.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        if outcome.wasCancelled { return "stop.circle" }
        return outcome.realFailures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }
    private var tint: Color {
        if outcome.wasCancelled { return .secondary }
        return outcome.realFailures.isEmpty ? .green : .orange
    }

    private var headline: String {
        if outcome.wasCancelled {
            return "Stopped after \(Fmt.count(outcome.filesSucceeded, "file"))"
        }
        if outcome.operation == .decompress {
            return "Decompressed \(Fmt.count(outcome.filesSucceeded, "file"))"
        }
        return "Reclaimed \(ByteFormat.short(outcome.bytesReclaimed))"
    }

    private var detail: String {
        var parts: [String] = []
        if outcome.operation == .compress {
            parts.append("\(Fmt.count(outcome.filesSucceeded, "file")) compressed")
        } else {
            parts.append("\(ByteFormat.short(abs(outcome.bytesReclaimed))) returned to disk")
        }
        if !outcome.realFailures.isEmpty {
            parts.append("\(Fmt.count(outcome.realFailures.count, "file")) had problems")
        }
        if !outcome.skipped.isEmpty {
            parts.append("\(outcome.skipped.count) left alone")
        }
        parts.append(String(format: "%.1fs", outcome.duration))
        if outcome.wasCancelled {
            parts.append("files already finished are safely compressed")
        }
        return parts.joined(separator: " · ")
    }
}
