import Foundation
import PomaceCore

extension SafetyReason {
    var text: String {
        switch self {
        case .systemPath:
            NSLocalizedString("core.safetyReason.systemPath", tableName: "Localizable", bundle: .module, value: "On the sealed system volume, which is read-only", comment: "Safety exclusion")
        case .sparseFile(let allocated, let logical):
            String(format: NSLocalizedString("core.safetyReason.sparseFile", tableName: "Localizable", bundle: .module, value: "Sparse file — occupies %@ of %@. Compressing it would materialize the empty space and use more disk, not less", comment: "Allocated and logical sizes"), Fmt.bytes(allocated), Fmt.bytes(logical))
        case .existingResourceFork:
            NSLocalizedString("core.safetyReason.existingResourceFork", tableName: "Localizable", bundle: .module, value: "Already has a resource fork, which is where the compressed data would need to go", comment: "Safety exclusion")
        case .liveDatabase(let kind):
            String(format: NSLocalizedString("core.safetyReason.liveDatabase", tableName: "Localizable", bundle: .module, value: "%@ is written to constantly; compression would be undone immediately", comment: "Database kind"), kind)
        case .virtualMachineImage:
            NSLocalizedString("core.safetyReason.virtualMachineImage", tableName: "Localizable", bundle: .module, value: "Virtual machine images are written in place and can use low-level disk access", comment: "Safety exclusion")
        case .cloudSyncedDirectory(let service):
            String(format: NSLocalizedString("core.safetyReason.cloudSyncedDirectory", tableName: "Localizable", bundle: .module, value: "Inside %@ — modifying every file could trigger a full re-upload", comment: "Cloud service"), service)
        case .timeMachineVolume:
            NSLocalizedString("core.safetyReason.timeMachineVolume", tableName: "Localizable", bundle: .module, value: "Time Machine backup storage", comment: "Safety exclusion")
        case .unsupportedFilesystem(let fs):
            String(format: NSLocalizedString("core.safetyReason.unsupportedFilesystem", tableName: "Localizable", bundle: .module, value: "%@ volumes don't support transparent compression", comment: "Filesystem name"), fs.uppercased())
        case .networkVolume:
            NSLocalizedString("core.safetyReason.networkVolume", tableName: "Localizable", bundle: .module, value: "Network volumes don't support transparent compression", comment: "Safety exclusion")
        case .zeroLength:
            NSLocalizedString("core.safetyReason.zeroLength", tableName: "Localizable", bundle: .module, value: "Empty file — nothing to compress", comment: "Safety exclusion")
        case .notRegularFile:
            NSLocalizedString("core.safetyReason.notRegularFile", tableName: "Localizable", bundle: .module, value: "Not a regular file", comment: "Safety exclusion")
        case .appStoreApplication:
            NSLocalizedString("core.safetyReason.appStoreApplication", tableName: "Localizable", bundle: .module, value: "Mac App Store application — leave the store-managed bundle unchanged", comment: "Safety exclusion")
        case .adobeApplication:
            NSLocalizedString("core.safetyReason.adobeApplication", tableName: "Localizable", bundle: .module, value: "Adobe application — excluded because its installation components perform integrity checks", comment: "Safety exclusion")
        case .applicationBundle:
            NSLocalizedString("core.safetyReason.applicationBundle", tableName: "Localizable", bundle: .module, value: "Application bundle — generally safe, and signatures still validate, but worth verifying the app afterwards", comment: "Safety advisory")
        case .hardLinked(let count):
            String(localized: "core.safetyReason.hardLinkedCount", defaultValue: "Shares its data with \(count - 1) other files; compressing affects all of them", bundle: .module, comment: "File table safety reason; count of other paths sharing the same stored data. Compression would affect every link.")
        case .veryLargeFile(let bytes):
            String(format: NSLocalizedString("core.safetyReason.veryLargeFile", tableName: "Localizable", bundle: .module, value: "%@ — this one file will take a while and can't be interrupted partway", comment: "File size"), Fmt.bytes(bytes))
        case .likelyIncompressible(let kind):
            String(format: NSLocalizedString("core.safetyReason.likelyIncompressible", tableName: "Localizable", bundle: .module, value: "%@ is already compressed; there's little or nothing to reclaim", comment: "File format"), kind)
        }
    }
}

extension CompressionType {
    var text: String {
        if self == .storedInline {
            return NSLocalizedString("core.compressionType.storedInline", tableName: "Localizable", bundle: .module, value: "none / xattr", comment: "File table state for data stored without compression in an extended attribute. Keep xattr as a technical abbreviation.")
        }
        return description // l10n-exempt: Compression algorithm and storage codes
    }
}

extension CompressionMode {
    var text: String {
        switch self {
        case .automatic: NSLocalizedString("core.compressionMode.automatic", tableName: "Localizable", bundle: .module, value: "Pomace measures this folder and picks what works best for it", comment: "Mode explanation")
        case .maximumSavings: NSLocalizedString("core.compressionMode.maximumSavings", tableName: "Localizable", bundle: .module, value: "Reclaims the most space, and takes noticeably longer", comment: "Mode explanation")
        case .fastest: NSLocalizedString("core.compressionMode.fastest", tableName: "Localizable", bundle: .module, value: "Finishes soonest, reclaiming a little less", comment: "Mode explanation")
        }
    }

    var label: String {
        switch self {
        case .automatic: NSLocalizedString("core.compressionMode.automaticLabel", tableName: "Localizable", bundle: .module, value: "Automatic", comment: "Mode name; separate from persistence key")
        case .maximumSavings: NSLocalizedString("core.compressionMode.maximumSavingsLabel", tableName: "Localizable", bundle: .module, value: "Maximum savings", comment: "Mode name")
        case .fastest: NSLocalizedString("core.compressionMode.fastestLabel", tableName: "Localizable", bundle: .module, value: "Fastest", comment: "Mode name")
        }
    }
}

extension RuntimeConstraint {
    var text: String {
        switch self {
        case .onBattery: NSLocalizedString("core.runtimeConstraint.onBattery", tableName: "Localizable", bundle: .module, value: "running on battery", comment: "Constraint fragment")
        case .lowPowerMode: NSLocalizedString("core.runtimeConstraint.lowPowerMode", tableName: "Localizable", bundle: .module, value: "Low Power Mode is on", comment: "Constraint fragment")
        case .thermalPressure: NSLocalizedString("core.runtimeConstraint.thermalPressure", tableName: "Localizable", bundle: .module, value: "the Mac is running warm", comment: "Constraint fragment")
        case .slowMedia: NSLocalizedString("core.runtimeConstraint.slowMedia", tableName: "Localizable", bundle: .module, value: "slow media", comment: "Constraint fragment")
        }
    }
}

extension JustificationReason {
    var text: String {
        switch self {
        case .measuredBest: NSLocalizedString("core.justificationReason.measuredBest", tableName: "Localizable", bundle: .module, value: "measured best on this folder", comment: "Policy reason fragment")
        case .defaultLZFSE: NSLocalizedString("core.justificationReason.defaultLZFSE", tableName: "Localizable", bundle: .module, value: "default — reads back fastest, for a ratio within a point of the alternatives", comment: "Policy reason fragment")
        case .maximumSavingsRequested: NSLocalizedString("core.justificationReason.maximumSavingsRequested", tableName: "Localizable", bundle: .module, value: "you asked for maximum savings — a slightly better ratio, and slower to read back", comment: "Policy reason fragment")
        case .speedRequested: NSLocalizedString("core.justificationReason.speedRequested", tableName: "Localizable", bundle: .module, value: "you asked for speed", comment: "Policy reason fragment")
        case .minimumSavingThreshold: NSLocalizedString("core.justificationReason.minimumSavingThreshold", tableName: "Localizable", bundle: .module, value: "files that would gain less than this are left alone", comment: "Policy reason fragment")
        case .verificationAlwaysOn: NSLocalizedString("core.justificationReason.verificationAlwaysOn", tableName: "Localizable", bundle: .module, value: "applesauce re-reads every file and compares it before replacing the original; Pomace never turns this off", comment: "Fixed safety reason")
        case .hardLinksRefused: NSLocalizedString("core.justificationReason.hardLinksRefused", tableName: "Localizable", bundle: .module, value: "applesauce refuses files that share storage with another file, which is why Pomace lists them as excluded rather than silently doing nothing", comment: "Fixed safety reason")
        case .sparseWouldGrow: NSLocalizedString("core.justificationReason.sparseWouldGrow", tableName: "Localizable", bundle: .module, value: "compressing one would materialise its empty space and use more disk, not less", comment: "Fixed safety reason")
        case .setByUser: NSLocalizedString("core.justificationReason.setByUser", tableName: "Localizable", bundle: .module, value: "set by you", comment: "Override reason")
        }
    }
}

extension JustificationValue {
    var text: String {
        switch self {
        case .compressor(let name): name
        case .percent(let value): Fmt.percent(Double(value) / 100)
        case .alwaysOn: NSLocalizedString("core.justificationValue.alwaysOn", tableName: "Localizable", bundle: .module, value: "Always on", comment: "Fixed verification value")
        case .skipped: NSLocalizedString("core.justificationValue.skipped", tableName: "Localizable", bundle: .module, value: "Skipped", comment: "Fixed exclusion value")
        }
    }
}

extension Justification {
    var label: String {
        switch id {
        case "compressor": NSLocalizedString("core.justification.compressor", tableName: "Localizable", bundle: .module, value: "Compressor", comment: "Policy row label")
        case "threshold": NSLocalizedString("core.justification.threshold", tableName: "Localizable", bundle: .module, value: "Minimum saving", comment: "Policy row label")
        case "verify": NSLocalizedString("core.justification.verify", tableName: "Localizable", bundle: .module, value: "Verification", comment: "Policy row label")
        case "hardlinks": NSLocalizedString("core.justification.hardlinks", tableName: "Localizable", bundle: .module, value: "Hard links", comment: "Policy row label")
        case "sparse": NSLocalizedString("core.justification.sparse", tableName: "Localizable", bundle: .module, value: "Sparse files", comment: "Policy row label")
        default: id
        }
    }
}

extension PlanWarning {
    var text: String {
        switch self {
        case .zlibSlowerReads:
            NSLocalizedString("core.planWarning.zlibSlowerReads", tableName: "Localizable", bundle: .module, value: "ZLIB reclaims marginally more space than the default, but every later read of these files is slower. Measured on a mixed corpus the difference in size was under one percent.", comment: "Maximum savings tradeoff")
        case .compressorUnsupported(let requested, let fallback):
            String(format: NSLocalizedString("core.planWarning.compressorUnsupported", tableName: "Localizable", bundle: .module, value: "This copy of applesauce doesn't support %@; using %@ instead.", comment: "Requested and fallback compressor names"), requested.uppercased(), fallback.uppercased())
        }
    }
}

extension SweepDeferral {
    var text: String {
        switch self {
        case .onBattery: NSLocalizedString("core.sweepDeferral.onBattery", tableName: "Localizable", bundle: .module, value: "Skipped — running on battery", comment: "Deferred sweep")
        case .lowPowerMode: NSLocalizedString("core.sweepDeferral.lowPowerMode", tableName: "Localizable", bundle: .module, value: "Skipped — Low Power Mode was on", comment: "Deferred sweep")
        case .thermalPressure: NSLocalizedString("core.sweepDeferral.thermalPressure", tableName: "Localizable", bundle: .module, value: "Skipped — the Mac was running warm", comment: "Deferred sweep")
        case .timeMachineRunning: NSLocalizedString("core.sweepDeferral.timeMachineRunning", tableName: "Localizable", bundle: .module, value: "Skipped — a Time Machine backup was in progress", comment: "Deferred sweep")
        case .volumeUnavailable: NSLocalizedString("core.sweepDeferral.volumeUnavailable", tableName: "Localizable", bundle: .module, value: "Skipped — the folder wasn't available", comment: "Deferred sweep")
        case .alreadyRunning: NSLocalizedString("core.sweepDeferral.alreadyRunning", tableName: "Localizable", bundle: .module, value: "Skipped — another sweep was already running", comment: "Deferred sweep")
        }
    }
}

extension SkipRemedy {
    var text: String {
        switch self {
        case .hardLinked: NSLocalizedString("core.skipRemedy.hardLinked", tableName: "Localizable", bundle: .module, value: "applesauce can't compress hard-linked files. Nothing was changed.", comment: "Next step for skipped hard links")
        case .emptyFile: NSLocalizedString("core.skipRemedy.emptyFile", tableName: "Localizable", bundle: .module, value: "There was nothing to compress.", comment: "Empty file remedy")
        case .unreadable: NSLocalizedString("core.skipRemedy.unreadable", tableName: "Localizable", bundle: .module, value: "For protected Homebrew or application files, enable Use administrator privileges and retry. macOS privacy controls may still require Full Disk Access.", comment: "Permission remedy")
        case .unwritable: NSLocalizedString("core.skipRemedy.unwritable", tableName: "Localizable", bundle: .module, value: "For protected Homebrew or application files, enable Use administrator privileges and retry. Read-only volumes cannot be modified.", comment: "Write permission remedy")
        case .insufficientSaving: NSLocalizedString("core.skipRemedy.insufficientSaving", tableName: "Localizable", bundle: .module, value: "Left as it was — compressing it would have saved little or nothing.", comment: "Savings threshold remedy")
        case .decompressionFailed: NSLocalizedString("core.skipRemedy.decompressionFailed", tableName: "Localizable", bundle: .module, value: "The file was left exactly as it was.", comment: "Decompression remedy")
        case .fileMissing: NSLocalizedString("core.skipRemedy.fileMissing", tableName: "Localizable", bundle: .module, value: "It was moved or deleted while Pomace was working. Nothing was changed.", comment: "Missing file remedy")
        case .diskFull: NSLocalizedString("core.skipRemedy.diskFull", tableName: "Localizable", bundle: .module, value: "Free up disk space and try again.", comment: "Disk full remedy")
        case .resourceFork: NSLocalizedString("core.skipRemedy.resourceFork", tableName: "Localizable", bundle: .module, value: "This file already uses its resource fork, so it can't be compressed. It will be skipped.", comment: "Resource fork remedy")
        case .readOnly: NSLocalizedString("core.skipRemedy.readOnly", tableName: "Localizable", bundle: .module, value: "This file is on a read-only volume.", comment: "Read-only remedy")
        case .unchanged: NSLocalizedString("core.skipRemedy.unchanged", tableName: "Localizable", bundle: .module, value: "Left unchanged. The file itself was not modified.", comment: "Generic failure remedy")
        }
    }
}

extension CompressionFailureMessage {
    var text: String {
        switch self {
        case .toolOutput(let output): return output
        case .compressorError: return NSLocalizedString("core.failureMessage.compressorError", tableName: "Localizable", bundle: .module, value: "The compressor reported an error", comment: "Fallback when tool output is empty")
        case .classified(let reason):
            switch reason {
            case .hardLinked(let count):
                return String(localized: "core.failureMessage.hardLinkedCount", defaultValue: "Shares its data with \(count) other files", bundle: .module, comment: "Run failure details; count of other paths sharing the file's data, explaining why it was skipped.")
            case .emptyFile: return NSLocalizedString("core.failureMessage.emptyFile", tableName: "Localizable", bundle: .module, value: "Empty file", comment: "Skip message")
            case .unreadable: return NSLocalizedString("core.failureMessage.unreadable", tableName: "Localizable", bundle: .module, value: "Couldn't be read", comment: "Failure message")
            case .unwritable: return NSLocalizedString("core.failureMessage.unwritable", tableName: "Localizable", bundle: .module, value: "Couldn't be modified", comment: "Failure message")
            case .insufficientSaving: return NSLocalizedString("core.failureMessage.insufficientSaving", tableName: "Localizable", bundle: .module, value: "Wouldn't compress enough to be worth it", comment: "Skip message")
            case .decompressionFailed: return NSLocalizedString("core.failureMessage.decompressionFailed", tableName: "Localizable", bundle: .module, value: "Couldn't be decompressed", comment: "Failure message")
            case .fileMissing: return NSLocalizedString("core.failureMessage.fileMissing", tableName: "Localizable", bundle: .module, value: "The file is no longer there", comment: "Failure message")
            case .diskFull, .resourceFork, .readOnly, .unchanged: return CompressionFailureMessage.compressorError.text
            }
        }
    }
}

extension CompressionOperation {
    var text: String {
        switch self {
        case .compress: NSLocalizedString("core.compressionOperation.compress", tableName: "Localizable", bundle: .module, value: "Compressing", comment: "Progress verb")
        case .decompress: NSLocalizedString("core.compressionOperation.decompress", tableName: "Localizable", bundle: .module, value: "Decompressing", comment: "Progress verb")
        }
    }
}

extension SweepService.Status {
    var text: String {
        switch self {
        case .notRegistered: NSLocalizedString("core.serviceStatus.notRegistered", tableName: "Localizable", bundle: .module, value: "Scheduled sweeps are off", comment: "Service status")
        case .enabled: NSLocalizedString("core.serviceStatus.enabled", tableName: "Localizable", bundle: .module, value: "Scheduled sweeps are on", comment: "Service status")
        case .requiresApproval: NSLocalizedString("core.serviceStatus.requiresApproval", tableName: "Localizable", bundle: .module, value: "Waiting for your approval in System Settings › General › Login Items", comment: "Service status")
        case .notFound: NSLocalizedString("core.serviceStatus.notFound", tableName: "Localizable", bundle: .module, value: "Pomace can't register its background helper. Move Pomace to your Applications folder and try again.", comment: "Service status")
        case .unavailable(let reason): reason
        case .unknown: NSLocalizedString("core.serviceStatus.unknown", tableName: "Localizable", bundle: .module, value: "Unknown state", comment: "Unknown service status")
        }
    }
}

extension SweepCadence {
    var text: String {
        switch self {
        case .daily: NSLocalizedString("core.sweepCadence.daily", tableName: "Localizable", bundle: .module, value: "Every day", comment: "Schedule cadence")
        case .weekly: NSLocalizedString("core.sweepCadence.weekly", tableName: "Localizable", bundle: .module, value: "Every week", comment: "Schedule cadence")
        case .monthly: NSLocalizedString("core.sweepCadence.monthly", tableName: "Localizable", bundle: .module, value: "Every month", comment: "Schedule cadence")
        case .manual: NSLocalizedString("core.sweepCadence.manual", tableName: "Localizable", bundle: .module, value: "Only when I ask", comment: "Schedule cadence")
        }
    }
}

extension SweepSchedule {
    var text: String {
        guard enabled else { return NSLocalizedString("core.sweepSchedule.paused", tableName: "Localizable", bundle: .module, value: "Paused", comment: "Disabled schedule") }
        guard cadence != .manual else { return NSLocalizedString("core.sweepSchedule.manual", tableName: "Localizable", bundle: .module, value: "Only when you ask", comment: "Manual schedule") }
        let hour = Fmt.hour(preferredHour)
        return String(format: NSLocalizedString("core.sweepSchedule.scheduled", tableName: "Localizable", bundle: .module, value: "%@, around %@", comment: "Cadence and preferred time"), cadence.text, hour)
    }
}

extension Store.SweepRun {
    var text: String {
        if let deferral { return deferral.text }
        if let error {
            let rendered = (try? JSONDecoder().decode(CompressionEngineError.self, from: Data(error.utf8)))?.text ?? error
            return String(format: NSLocalizedString("core.sweepRun.failed", tableName: "Localizable", bundle: .module, value: "Failed — %@", comment: "Persisted failure"), rendered)
        }
        if cancelled {
            return String(localized: "core.sweepRun.cancelledCount", defaultValue: "Stopped after \(filesCompressed) files", bundle: .module, comment: "Sweep history cancelled outcome; completed file count. English historically uses files even for one.")
        }
        if filesCompressed == 0 { return NSLocalizedString("core.sweepRun.unchanged", tableName: "Localizable", bundle: .module, value: "Nothing had changed", comment: "No files changed") }
        let reclaimed = Fmt.bytes(bytesReclaimed)
        var result = String(localized: "core.sweepRun.completedCount", defaultValue: "Compressed \(filesCompressed) files, reclaimed \(reclaimed)", bundle: .module, comment: "Sweep history success; number compressed and formatted space recovered.")
        if filesFailed > 0 {
            result += String(localized: "core.sweepRun.skippedCount", defaultValue: " · \(filesFailed) skipped", bundle: .module, comment: "Sweep history suffix; number of files skipped, appended to the successful outcome.")
        }
        return result
    }
}

extension ToolCapability {
    var text: String {
        switch self {
        case .lzfse: NSLocalizedString("core.toolCapability.lzfse", tableName: "Localizable", bundle: .module, value: "LZFSE compression", comment: "Required capability")
        case .verify: NSLocalizedString("core.toolCapability.verify", tableName: "Localizable", bundle: .module, value: "--verify", comment: "Required CLI flag")
        case .minimumRatio: NSLocalizedString("core.toolCapability.minimumRatio", tableName: "Localizable", bundle: .module, value: "--minimum-compression-ratio", comment: "Required CLI flag")
        }
    }
}

extension CustomCompressorRejection {
    var text: String {
        switch self {
        case .notFound: NSLocalizedString("core.customCompressorRejection.notFound", tableName: "Localizable", bundle: .module, value: "The chosen compressor could not be found.", comment: "Custom compressor rejection")
        case .notExecutable: NSLocalizedString("core.customCompressorRejection.notExecutable", tableName: "Localizable", bundle: .module, value: "The chosen compressor is not executable.", comment: "Custom compressor rejection")
        case .notRegularFile: NSLocalizedString("core.customCompressorRejection.notRegularFile", tableName: "Localizable", bundle: .module, value: "Choose a regular executable file.", comment: "Custom compressor rejection")
        case .relativePath: NSLocalizedString("core.customCompressorRejection.relativePath", tableName: "Localizable", bundle: .module, value: "The chosen compressor needs an absolute path.", comment: "Custom compressor rejection")
        case .missingCapabilities(let capabilities): String(format: NSLocalizedString("core.customCompressorRejection.missingCapabilities", tableName: "Localizable", bundle: .module, value: "The chosen compressor lacks: %@.", comment: "Missing capability list"), capabilities.map(\.text).joined(separator: ", "))
        }
    }
}

extension CompressorResolution {
    var rejectionText: String? {
        guard let customRejection else { return nil }
        let fallback = installation == nil
            ? NSLocalizedString("core.compressorResolution.unavailable", tableName: "Localizable", bundle: .module, value: "No usable compressor is available. Pomace can still scan your files.", comment: "No fallback available")
            : NSLocalizedString("core.compressorResolution.bundled", tableName: "Localizable", bundle: .module, value: "Pomace is using the bundled compressor.", comment: "Fallback available")
        return String(format: NSLocalizedString("core.compressorResolution.rejection", tableName: "Localizable", bundle: .module, value: "%@ %@", comment: "Rejection and fallback explanation"), customRejection.text, fallback)
    }
}

extension CompressionEngineError {
    var text: String {
        switch self {
        case .toolMissing: NSLocalizedString("core.engineError.toolMissing", tableName: "Localizable", bundle: .module, value: "applesauce isn't installed. Pomace can install it for you.", comment: "Legacy missing-tool error")
        case .insufficientFreeSpace(let needed, let available):
            String(format: NSLocalizedString("core.engineError.insufficientFreeSpace", tableName: "Localizable", bundle: .module, value: "Not enough free space to work safely — %@ available, %@ needed for the temporary replacement file.", comment: "Available and needed space"), Fmt.bytes(available), Fmt.bytes(needed))
        case .nothingToDo: NSLocalizedString("core.engineError.nothingToDo", tableName: "Localizable", bundle: .module, value: "Nothing here needs compressing.", comment: "No eligible files")
        case .administratorUnsupported: NSLocalizedString("core.engineError.administratorUnsupported", tableName: "Localizable", bundle: .module, value: "Administrator access is available only for /Applications, /opt/homebrew, and /usr/local.", comment: "Unsupported elevated root")
        case .compressorUnavailable: NSLocalizedString("core.engineError.compressorUnavailable", tableName: "Localizable", bundle: .module, value: "The compressor is unavailable or lacks required verification support.", comment: "Resolution failed")
        case .readOnlyVolume: NSLocalizedString("core.engineError.readOnlyVolume", tableName: "Localizable", bundle: .module, value: "This volume is read-only. Administrator access cannot make it writable.", comment: "Read-only volume")
        case .safetyMetadataUnreadable(let path): String(format: NSLocalizedString("core.engineError.safetyMetadataUnreadable", tableName: "Localizable", bundle: .module, value: "Cannot read safety metadata for %@. Allow Pomace to inspect this file before using administrator access.", comment: "File path"), path)
        case .verificationRequired: NSLocalizedString("core.engineError.verificationRequired", tableName: "Localizable", bundle: .module, value: "Compression refused: verification is required.", comment: "Missing mandatory verification")
        case .alreadyRunning: NSLocalizedString("core.engineError.alreadyRunning", tableName: "Localizable", bundle: .module, value: "Another compression run is already active.", comment: "Sweep lock held")
        case .compressorChanged(let confirmed, let resolved):
            String(format: NSLocalizedString("core.engineError.compressorChanged", tableName: "Localizable", bundle: .module, value: "The compressor changed after you confirmed administrator access. Confirmed: %@. Resolved: %@. Start the operation again to confirm the new compressor.", comment: "Confirmed and newly resolved paths"), confirmed, resolved)
        }
    }
}


enum CoreText {
    static let administratorPrompt = NSLocalizedString("core.administratorAccess.prompt", tableName: "Localizable", bundle: .module, value: "Pomace needs administrator access to modify the selected Homebrew or application files.", comment: "System authorization prompt")
    static let fileChangedMessage = NSLocalizedString("core.administratorAccess.fileChanged", tableName: "Localizable", bundle: .module, value: "A selected path is no longer a regular file.", comment: "A path changed before elevated execution")
}

extension Store.StoreError {
    var text: String {
        switch self {
        case .open(let message): String(format: NSLocalizedString("core.storeError.open", tableName: "Localizable", bundle: .module, value: "could not open store: %@", comment: "SQLite open error"), message)
        case .sql(let message): String(format: NSLocalizedString("core.storeError.sql", tableName: "Localizable", bundle: .module, value: "sql error: %@", comment: "SQLite error"), message)
        }
    }
}

extension SweepService.RegistrationError {
    var text: String { description }
}


extension SystemProfile {
    var text: String {
        if isAppleSilicon {
            return String(localized: "core.systemProfile.performanceCount", defaultValue: "matched to \(performanceCores) performance cores", bundle: .module, comment: "Machine policy explanation; number of performance cores used to match concurrency.")
        }
        return String(localized: "core.systemProfile.physicalCount", defaultValue: "matched to \(physicalCores) physical cores", bundle: .module, comment: "Machine policy explanation; number of physical cores used to match concurrency. English historically uses cores even for one.")
    }
}
