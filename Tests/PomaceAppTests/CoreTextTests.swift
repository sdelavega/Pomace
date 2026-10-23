import Foundation
import Testing
import PomaceCore
@testable import PomaceApp

@Suite("Core text")
struct CoreTextTests {
    @Test("every safety reason remains presentable")
    func explanationsArePresentable() throws {
        let all: [SafetyReason] = [
            .systemPath, .sparseFile(allocatedBytes: 0, logicalBytes: 1024),
            .existingResourceFork, .liveDatabase("SQLite database"), .virtualMachineImage,
            .cloudSyncedDirectory("Dropbox"), .timeMachineVolume,
            .unsupportedFilesystem("exfat"), .networkVolume, .zeroLength, .notRegularFile,
            .appStoreApplication, .adobeApplication, .applicationBundle, .hardLinked(linkCount: 2),
            .veryLargeFile(bytes: 5_000_000_000), .likelyIncompressible("JPEG"),
        ]
        #expect(all.count == 17)
        for reason in all {
            let first = try #require(reason.text.first)
            #expect(first.isUppercase || first.isNumber)
            #expect(!reason.text.hasSuffix("."))
        }
        #expect(SafetyReason.hardLinked(linkCount: 2).text == "Shares its data with 1 other file; compressing affects all of them")
        #expect(SafetyReason.hardLinked(linkCount: 3).text == "Shares its data with 2 other files; compressing affects all of them")
    }

    @Test("policy reasons retain verbatim English")
    func policyReasons() {
        let expected: [(JustificationReason, String)] = [
            (.measuredBest, "measured best on this folder"),
            (.defaultLZFSE, "default — reads back fastest, for a ratio within a point of the alternatives"),
            (.maximumSavingsRequested, "you asked for maximum savings — a slightly better ratio, and slower to read back"),
            (.speedRequested, "you asked for speed"),
            (.minimumSavingThreshold, "files that would gain less than this are left alone"),
            (.verificationAlwaysOn, "applesauce re-reads every file and compares it before replacing the original; Pomace never turns this off"),
            (.hardLinksRefused, "applesauce refuses files that share storage with another file, which is why Pomace lists them as excluded rather than silently doing nothing"),
            (.sparseWouldGrow, "compressing one would materialise its empty space and use more disk, not less"),
            (.setByUser, "set by you"),
        ]
        #expect(expected.count == 9)
        for (reason, text) in expected {
            #expect(!reason.text.isEmpty)
            #expect(reason.text == text)
        }
    }

    @Test("constraints and warnings retain their fragments and punctuation")
    func constraintsAndWarnings() {
        let constraints: [(RuntimeConstraint, String)] = [
            (.onBattery, "running on battery"), (.lowPowerMode, "Low Power Mode is on"),
            (.thermalPressure, "the Mac is running warm"), (.slowMedia, "slow media"),
        ]
        #expect(constraints.count == 4)
        for (constraint, text) in constraints {
            #expect(!constraint.text.isEmpty)
            #expect(constraint.text == text)
        }
        let warnings: [(PlanWarning, String)] = [
            (.zlibSlowerReads, "ZLIB reclaims marginally more space than the default, but every later read of these files is slower. Measured on a mixed corpus the difference in size was under one percent."),
            (.compressorUnsupported(requested: "zlib", using: "lzfse"), "This copy of applesauce doesn't support ZLIB; using LZFSE instead."),
        ]
        #expect(warnings.count == 2)
        for (warning, text) in warnings {
            #expect(!warning.text.isEmpty)
            #expect(warning.text == text)
        }
    }

    @Test("all deferrals retain verbatim English")
    func deferrals() {
        let expected: [(SweepDeferral, String)] = [
            (.onBattery, "Skipped — running on battery"),
            (.lowPowerMode, "Skipped — Low Power Mode was on"),
            (.thermalPressure, "Skipped — the Mac was running warm"),
            (.timeMachineRunning, "Skipped — a Time Machine backup was in progress"),
            (.volumeUnavailable, "Skipped — the folder wasn't available"),
            (.alreadyRunning, "Skipped — another sweep was already running"),
        ]
        #expect(expected.count == 6)
        for (reason, text) in expected {
            #expect(!reason.text.isEmpty)
            #expect(reason.text == text)
        }
    }

    @Test("engine errors keep data and render verbatim English")
    func engineErrors() throws {
        let expected: [(CompressionEngineError, String)] = [
            (.toolMissing, "applesauce isn't installed. Pomace can install it for you."),
            (.insufficientFreeSpace(needed: 2000, available: 1000), "Not enough free space to work safely — 1.0 KB available, 2.0 KB needed for the temporary replacement file."),
            (.nothingToDo, "Nothing here needs compressing."),
            (.compressorChanged(confirmed: "/old", resolved: "/new"), "The compressor changed after you confirmed administrator access. Confirmed: /old. Resolved: /new. Start the operation again to confirm the new compressor."),
            (.administratorUnsupported, "Administrator access is available only for /Applications, /opt/homebrew, and /usr/local."),
            (.compressorUnavailable, "The compressor is unavailable or lacks required verification support."),
            (.readOnlyVolume, "This volume is read-only. Administrator access cannot make it writable."),
            (.safetyMetadataUnreadable(path: "/tmp/file"), "Cannot read safety metadata for /tmp/file. Allow Pomace to inspect this file before using administrator access."),
            (.verificationRequired, "Compression refused: verification is required."),
            (.alreadyRunning, "Another compression run is already active."),
        ]
        #expect(expected.count == 10)
        for (error, text) in expected {
            #expect(!error.text.isEmpty)
            #expect(error.text == text)
            let encoded = try JSONEncoder().encode(error)
            let decoded = try JSONDecoder().decode(CompressionEngineError.self, from: encoded)
            #expect(decoded == error)
            #expect(decoded.text == text)
        }
    }

    @Test("display values, statuses, and schedules preserve English")
    func displayValues() {
        #expect(JustificationValue.alwaysOn.text == "Always on")
        #expect(JustificationValue.skipped.text == "Skipped")
        #expect(JustificationValue.percent(5).text == "5%")
        #expect(JustificationValue.compressor("LZFSE").text == "LZFSE")
        #expect(CompressionMode.allCases.map(\.label) == ["Automatic", "Maximum savings", "Fastest"])
        #expect(CompressionMode.allCases.map(\.text) == [
            "Pomace measures this folder and picks what works best for it",
            "Reclaims the most space, and takes noticeably longer",
            "Finishes soonest, reclaiming a little less",
        ])
        let statuses: [(SweepService.Status, String)] = [
            (.notRegistered, "Scheduled sweeps are off"), (.enabled, "Scheduled sweeps are on"),
            (.requiresApproval, "Waiting for your approval in System Settings › General › Login Items"),
            (.notFound, "Pomace can't register its background helper. Move Pomace to your Applications folder and try again."),
            (.unknown, "Unknown state"), (.unavailable("System detail"), "System detail"),
        ]
        #expect(statuses.count == 6)
        for (status, text) in statuses { #expect(!status.text.isEmpty); #expect(status.text == text) }
        #expect(SweepCadence.allCases.map(\.text) == ["Every day", "Every week", "Every month", "Only when I ask"])
        #expect(SweepSchedule(cadence: .daily, preferredHour: 0).text == "Every day, around midnight")
        #expect(SweepSchedule(cadence: .daily, preferredHour: 12).text == "Every day, around noon")
        #expect(SweepSchedule(cadence: .daily, preferredHour: 15).text == "Every day, around 3 PM")
        #expect(SweepSchedule(cadence: .daily, preferredHour: 3).text == "Every day, around 3 AM")
        #expect(SweepSchedule(cadence: .manual).text == "Only when you ask")
        #expect(SweepSchedule(enabled: false).text == "Paused")
        #expect(SystemProfile(performanceCores: 1, efficiencyCores: 0, physicalCores: 1, isAppleSilicon: true).text == "matched to 1 performance core")
        #expect(SystemProfile(performanceCores: 4, efficiencyCores: 4, physicalCores: 8, isAppleSilicon: true).text == "matched to 4 performance cores")
        #expect(SystemProfile(performanceCores: 4, efficiencyCores: 0, physicalCores: 4, isAppleSilicon: false).text == "matched to 4 physical cores")
    }

    @Test("skip remedies and tool details preserve English")
    func skipRemedies() {
        let expected: [(SkipRemedy, String)] = [
            (.hardLinked(otherFiles: 1), "applesauce can't compress hard-linked files. Nothing was changed."),
            (.emptyFile, "There was nothing to compress."),
            (.unreadable, "For protected Homebrew or application files, enable Use administrator privileges and retry. macOS privacy controls may still require Full Disk Access."),
            (.unwritable, "For protected Homebrew or application files, enable Use administrator privileges and retry. Read-only volumes cannot be modified."),
            (.insufficientSaving, "Left as it was — compressing it would have saved little or nothing."),
            (.decompressionFailed, "The file was left exactly as it was."),
            (.fileMissing, "It was moved or deleted while Pomace was working. Nothing was changed."),
            (.diskFull, "Free up disk space and try again."),
            (.resourceFork, "This file already uses its resource fork, so it can't be compressed. It will be skipped."),
            (.readOnly, "This file is on a read-only volume."),
            (.unchanged, "Left unchanged. The file itself was not modified."),
        ]
        #expect(expected.count == 11)
        for (remedy, text) in expected { #expect(!remedy.text.isEmpty); #expect(remedy.text == text) }
        #expect(CompressionFailureMessage.classified(.hardLinked(otherFiles: 1)).text == "Shares its data with 1 other file")
        #expect(CompressionFailureMessage.classified(.hardLinked(otherFiles: 2)).text == "Shares its data with 2 other files")
        #expect(CompressionFailureMessage.toolOutput("External detail").text == "External detail")
        #expect(CompressionFailureMessage.compressorError.text == "The compressor reported an error")
        #expect(CustomCompressorRejection.missingCapabilities([.lzfse, .verify, .minimumRatio]).text == "The chosen compressor lacks: LZFSE compression, --verify, --minimum-compression-ratio.")
        #expect(CoreText.administratorPrompt == "Pomace needs administrator access to modify the selected Homebrew or application files.")
        #expect(CoreText.fileChangedMessage == "A selected path is no longer a regular file.")
    }

    @Test("history renders legacy failures and typed errors with their payloads")
    func historyText() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = try Store(url: temp.appendingPathComponent("history.sqlite"))
        let path = "/Users/alex/Documents/Fixture"
        let error = CompressionEngineError.compressorChanged(confirmed: "/old", resolved: "/new")
        let encoded = try #require(String(data: JSONEncoder().encode(error), encoding: .utf8))
        try store.recordSweep(path: path, startedAt: Date(timeIntervalSince1970: 1), duration: 1, filesCompressed: 3, bytesReclaimed: 4096)
        try store.recordSweep(path: path, startedAt: Date(timeIntervalSince1970: 2), duration: 0, deferral: .onBattery)
        try store.recordSweep(path: path, startedAt: Date(timeIntervalSince1970: 3), duration: 1, error: "Fixture compressor error")
        try store.recordSweep(path: path, startedAt: Date(timeIntervalSince1970: 4), duration: 1, error: encoded)
        let runs = try store.sweepHistory(path: path)
        #expect(runs.count == 4)
        #expect(runs.map(\.text) == ["Failed — " + error.text, "Failed — Fixture compressor error", "Skipped — running on battery", "Compressed 3 files, reclaimed 4.1 KB"])
    }

}
