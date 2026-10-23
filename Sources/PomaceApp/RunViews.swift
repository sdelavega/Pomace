import SwiftUI
import PomaceCore

struct AdministratorConfirmation: ViewModifier {
    @Bindable var model: ScanModel

    func body(content: Content) -> some View {
        content.confirmationDialog(
            AppStrings.authorizeAdministrator,
            isPresented: $model.confirmingAdministrator,
            titleVisibility: .visible
        ) {
            Button(AppStrings.continueAdministrator) { model.confirmAdministrator() }
            Button(AppStrings.cancel, role: .cancel) { model.cancelAdministrator() }
        } message: {
            Text(model.administratorConfirmationText)
        }
    }
}

/// The action row: compress, decompress, and the mode picker.
///
/// Decompress sits beside compress rather than buried in a menu — the PRD's promise is that
/// anything Pomace does it can undo, and an undo you can't find isn't one. It is still never
/// a single click: it opens a confirmation naming the exact file count (SAFETY.md §4 rule 2).
struct ActionBar: View {
    @Bindable var model: ScanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    model.startCompress()
                } label: {
                    Label(AppStrings.compress, systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .fixedSize()
                .disabled(model.compressibleCount == 0 || !model.toolReady || model.isRunning)
                .help(model.toolReady
                      ? AppStrings.compressEligible(model.compressibleCount)
                      : AppStrings.toolUnavailable(CompressorTool.displayName))

                Button {
                    model.requestDecompress()
                } label: {
                    Label(AppStrings.decompress, systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .controlSize(.large)
                .fixedSize()
                .disabled(model.compressedCount == 0 || !model.toolReady || model.isRunning)

                Picker(AppStrings.mode, selection: $model.mode) {
                    ForEach(CompressionMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // Flexible, not fixed: a fixed width squeezed the buttons until SwiftUI dropped
                // their labels down to bare icons when the inspector opened.
                .frame(minWidth: 200, idealWidth: 260, maxWidth: 300)
                .layoutPriority(-1)
                .disabled(model.isRunning)
                .help(model.mode.text)
            }
            if model.administratorAvailable {
                Toggle(AppStrings.useAdministrator, isOn: $model.useAdministratorPrivileges)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .disabled(model.isRunning || model.isSweeping)
                    .help(AppStrings.administratorHelp)
            }
        }
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
                    Text(AppStrings.runProgress(op.text, progress.filesProcessed, progress.filesTotal))
                        .font(.callout).monospacedDigit()
                    Spacer()
                    Button(model.isStopping ? AppStrings.stopping : AppStrings.stop) { model.cancelRun() }
                        .controlSize(.small)
                        .disabled(model.isStopping)
                }
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                if model.isStopping {
                    Text(AppStrings.stoppingHelp)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let p = progress.currentPath {
                    Text(AppStrings.currentBatch(p)).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if progress.failures > 0 {
                    Text(AppStrings.processingFailures(progress.failures))
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

        case .finished(let outcome):
            OutcomeBanner(outcome: outcome) { model.dismissRunResult() }

        case .refused(let message):
            Label(message, systemImage: "exclamationmark.circle")
                .font(.callout)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
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
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !outcome.failures.isEmpty {
                    Button(showingFailures ? AppStrings.hideDetails : AppStrings.showDetails) {
                        showingFailures.toggle()
                    }
                    .controlSize(.small)
                }
                Button(AppStrings.done, action: onDismiss).controlSize(.small)
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
                                    .font(.caption2)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((f.path as NSString).lastPathComponent)
                                        .font(.caption.weight(.medium))
                                    Text(f.message.text).font(.caption2).foregroundStyle(.secondary)
                                    Text(f.remedy.text).font(.caption2).foregroundStyle(.tertiary)
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
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
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
            return AppStrings.stopped(outcome.filesSucceeded)
        }
        if outcome.operation == .decompress {
            return AppStrings.decompressed(outcome.filesSucceeded)
        }
        return AppStrings.reclaimed(Fmt.bytes(outcome.bytesReclaimed))
    }

    private var detail: String {
        var parts: [String] = []
        if outcome.operation == .compress {
            parts.append(AppStrings.compressed(outcome.filesSucceeded))
        } else {
            parts.append(AppStrings.returnedToDisk(Fmt.bytes(abs(outcome.bytesReclaimed))))
        }
        if !outcome.realFailures.isEmpty {
            parts.append(AppStrings.hadProblems(outcome.realFailures.count))
        }
        if !outcome.skipped.isEmpty {
            parts.append(AppStrings.leftAlone(outcome.skipped.count))
        }
        parts.append(AppStrings.duration(outcome.duration))
        if outcome.wasCancelled {
            parts.append(AppStrings.finishedSafely)
        }
        return parts.joined(separator: " · ")
    }
}
