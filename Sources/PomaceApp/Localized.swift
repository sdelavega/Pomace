import Foundation

enum AppStrings {
    static let onboardingTitle = text(
        "onboarding.title",
        defaultValue: "Pomace",
        comment: "First-run window title."
    )

    static let onboardingBody = text(
        "onboarding.body",
        defaultValue: "Pomace keeps selected folders smaller using macOS transparent compression. Files still open normally, with no archive to manage. Writing a compressed file expands it again, so Pomace can periodically recheck watched folders. Every compression is verified, and you can decompress files whenever you need to.",
        comment: "First-run explanation of transparent compression and its write behavior."
    )

    static let onboardingGetStarted = text(
        "onboarding.get_started",
        defaultValue: "Get Started",
        comment: "Confirms the first-run explanation."
    )

    static let appName = text("content.title", defaultValue: "Pomace", comment: "Main window and menu bar title; app name.")
    static let cancel = text("common.cancel", defaultValue: "Cancel", comment: "Confirmation dialog button; dismisses without acting.")
    static let done = text("common.done", defaultValue: "Done", comment: "Settings sheet or run result button; closes the current presentation.")
    static let stop = text("common.stop", defaultValue: "Stop", comment: "Scan or compression control; requests a safe stop.")
    static let rescan = text("common.rescan", defaultValue: "Rescan", comment: "Toolbar and menu action; examines the selected folder again.")
    static let schedule = text("content.schedule", defaultValue: "Schedule", comment: "Inspector heading and toolbar button; configures recurring folder sweeps.")
    static let decompressExplanation = text("content.decompress_explanation", defaultValue: "This returns those files to their full size on disk. Their contents are unchanged, and you can compress them again at any time.", comment: "Decompression confirmation; explains disk growth and reassures that contents stay intact.")
    static let scheduled = text("sidebar.scheduled", defaultValue: "Scheduled", comment: "Sidebar group for folders with automatic sweeps enabled.")
    static let notScheduled = text("sidebar.not_scheduled", defaultValue: "Not Scheduled", comment: "Sidebar group for folders swept only on request.")
    static let noFolders = text("sidebar.empty", defaultValue: "No Folders", comment: "Empty sidebar heading when no folders have been added.")
    static let addFolderHelp = text("sidebar.empty_help", defaultValue: "Add or drop a folder to see what compression would reclaim.", comment: "Empty sidebar instruction for choosing a folder to inspect.")
    static let reveal = text("sidebar.reveal", defaultValue: "Reveal in Finder", comment: "Folder context menu action opening its location in Finder.")
    static let remove = text("sidebar.remove", defaultValue: "Remove", comment: "Folder context menu; removes monitoring, not the folder on disk.")
    static let nothingSelected = text("content.no_selection", defaultValue: "Nothing Selected", comment: "Detail pane heading when no folder is selected.")
    static let chooseFolder = text("content.choose_folder", defaultValue: "Choose a folder in the sidebar, or press ⌘O to add one.", comment: "Empty detail pane instruction; command O opens the folder chooser.")
    static let cannotScan = text("content.scan_failed", defaultValue: "Can't Scan This Folder", comment: "Heading above the reason a folder cannot be scanned.")
    static let compressorUnavailable = text("content.compressor_unavailable", defaultValue: "The compressor is unavailable. You can still scan; choose a compressor in Settings → Advanced.", comment: "Results banner; inspection works and Advanced settings can repair compressor selection.")
    static let recentScan = text("content.recent_scan", defaultValue: "Showing a recent scan. Rescan to check for changes.", comment: "Banner warning that displayed results came from the scan cache.")
    static let settings = text("content.settings", defaultValue: "Settings", comment: "Toolbar button showing compression policy choices.")
    static let settingsHelp = text("content.settings_help", defaultValue: "See what Pomace chose, and why", comment: "Settings toolbar tooltip; explains automatic compression policy choices.")
    static let scheduleHelp = text("content.schedule_help", defaultValue: "Schedule and sweep history", comment: "Schedule toolbar tooltip; shows timing and past background runs.")
    static let scanProgress = text("scan.progress_label", defaultValue: "Scan progress", comment: "Accessibility label for the number of files examined during a scan.")

    static func decompressQuestion(_ count: Int) -> String {
        String(localized: "content.decompress_question", defaultValue: "Decompress \(count) files?", bundle: .module, comment: "Decompression confirmation title; number of files that will expand on disk.")
    }

    static func decompressAction(_ count: Int) -> String {
        String(localized: "content.decompress_action", defaultValue: "Decompress \(count) files", bundle: .module, comment: "Destructive confirmation button; number of files to decompress.")
    }

    static func examined(_ count: Int) -> String {
        String(localized: "scan.examined", defaultValue: "\(count) files examined", bundle: .module, comment: "Scan progress and accessibility value; number of files inspected so far.")
    }

    static let automaticUpdates = text("settings.automatic_updates", defaultValue: "Check for updates automatically", comment: "General settings toggle; periodically checks for a new app version.")
    static let menuBarItem = text("settings.menu_bar_item", defaultValue: "Show menu bar item", comment: "Settings toggle; displays Pomace controls in the system menu bar.")
    static let compressionSettings = text("settings.compression_title", defaultValue: "Compression Settings", comment: "Advanced settings heading for the compression policy.")
    static let settingsExplanation = text("settings.explanation", defaultValue: "Pomace chooses these for you. Everything below shows what it picked and why.", comment: "Advanced settings introduction; automatic policy decisions are explained below.")
    static let mode = text("settings.mode", defaultValue: "Mode", comment: "Compression mode picker in settings and the action bar.")
    static let compressor = text("settings.compressor", defaultValue: "Compressor", comment: "Advanced settings section naming the executable used to compress files.")
    static let chooseCompressor = text("settings.choose_compressor", defaultValue: "Choose…", comment: "Advanced settings action; opens a file chooser for a custom compressor executable.")
    static let useBundled = text("settings.use_bundled", defaultValue: "Use Bundled", comment: "Advanced settings action; clears the override and uses Pomace's included compressor.")
    static let choose = text("settings.choose", defaultValue: "Choose", comment: "Open panel confirmation button for selecting a compressor executable.")
    static let chooseCompressorHelp = text("settings.choose_compressor_help", defaultValue: "Choose an applesauce executable. Pomace checks its capabilities before use.", comment: "Compressor file chooser explanation; selection is validated before running.")
    static let resetAutomatic = text("settings.reset_automatic", defaultValue: "Reset to Automatic", comment: "Advanced settings action; clears user policy overrides.")
    static let always = text("settings.always", defaultValue: "Always", comment: "Policy row badge; this safety setting is fixed and cannot be overridden.")
    static let overridden = text("settings.overridden", defaultValue: "Overridden", comment: "Policy row badge; the user replaced Pomace's automatic choice.")

    static let addFolder = text("app.add_folder", defaultValue: "Add Folder", comment: "Main toolbar action opening the folder chooser.")
    static let addFolderTooltip = text("app.add_folder_help", defaultValue: "Add a folder or application bundle", comment: "Add Folder tooltip; application bundles may also be scanned.")
    static let about = text("app.about", defaultValue: "About Pomace", comment: "App menu action showing version and credits.")
    static let checkUpdates = text("app.check_updates", defaultValue: "Check for Updates…", comment: "App menu action starting a manual update check.")
    static let addFolderMenu = text("app.add_folder_menu", defaultValue: "Add Folder…", comment: "File menu action opening the folder chooser.")
    static let general = text("settings.general", defaultValue: "General", comment: "Settings tab for updates and menu bar visibility.")
    static let advanced = text("settings.advanced", defaultValue: "Advanced", comment: "Settings tab for compressor selection and policy explanations.")
    static let openApp = text("app.open", defaultValue: "Open Pomace", comment: "Menu bar action bringing the main window forward.")
    static let noFolderSelected = text("app.no_folder", defaultValue: "No folder selected", comment: "Menu bar status when no watched folder is selected.")
    static let sweepNow = text("inspector.sweep_now", defaultValue: "Sweep Now", comment: "Inspector and menu bar action; runs a scheduled-style sweep immediately.")
    static let quit = text("app.quit", defaultValue: "Quit Pomace", comment: "Menu bar action terminating the app.")
    static let scan = text("app.scan", defaultValue: "Scan", comment: "Folder chooser confirmation button; starts read-only inspection.")
    static let scanHelp = text("app.scan_help", defaultValue: "Choose a folder or application bundle to scan. Pomace only reads it — nothing is modified.", comment: "Folder chooser explanation; scanning does not change files.")

    static func credits(_ source: String) -> String {
        String(format: text("app.credits", defaultValue: "applesauce (GPL-3.0)\n%@\n\nTranslations are machine-translated — corrections welcome.\nhttps://github.com/sdelavega/Pomace/blob/main/docs/TRANSLATING.md", comment: "About panel credits; placeholder is the compressor source link, followed by the machine translation disclosure and correction guide."), source)
    }

    static let authorizeAdministrator = text("run.authorize", defaultValue: "Authorize administrator access?", comment: "Elevated run confirmation title; asks before requesting macOS authentication.")
    static let continueAdministrator = text("run.continue_administrator", defaultValue: "Continue as Administrator", comment: "Elevated confirmation action; proceeds to macOS authorization.")
    static let compress = text("run.compress", defaultValue: "Compress", comment: "Action bar button; compresses eligible files.")
    static let decompress = text("run.decompress", defaultValue: "Decompress", comment: "Action bar button; restores compressed files to full disk size.")
    static let useAdministrator = text("run.use_administrator", defaultValue: "Use administrator privileges", comment: "Action bar toggle; enables protected application or Homebrew file operations.")
    static let administratorHelp = text("run.administrator_help", defaultValue: "Authorize compression or decompression of protected Homebrew and application files. macOS handles authentication.", comment: "Administrator toggle tooltip; explains protected file access and who authenticates.")
    static let stopping = text("run.stopping", defaultValue: "Stopping…", comment: "Disabled stop button while the active compression batch finishes.")
    static let stoppingHelp = text("run.stopping_help", defaultValue: "Waiting for the active batch to finish safely. No further batches will start.", comment: "Run progress explanation after Stop; active work finishes safely before stopping.")
    static let hideDetails = text("run.hide_details", defaultValue: "Hide details", comment: "Run outcome button; collapses the file failure list.")
    static let showDetails = text("run.show_details", defaultValue: "Show details", comment: "Run outcome button; expands the file failure list.")
    static let finishedSafely = text("run.finished_safely", defaultValue: "files already finished are safely compressed", comment: "Cancelled run outcome suffix; reassures that completed files remain safe.")

    static func compressEligible(_ count: Int) -> String {
        String(localized: "run.compress_eligible", defaultValue: "Compress \(count) eligible files", bundle: .module, comment: "Compress button tooltip; number of eligible files.")
    }

    static func toolUnavailable(_ name: String) -> String {
        String(format: text("run.tool_unavailable", defaultValue: "%@ isn't available", comment: "Disabled compress button tooltip; placeholder is compressor name."), name)
    }

    static func runProgress(_ operation: String, _ count: Int, _ total: Int) -> String {
        String(localized: "run.progress", defaultValue: "\(operation) — \(count) files of \(total.formatted())", bundle: .module, comment: "Run progress; operation verb, processed file count, and formatted total count.")
    }

    static func currentBatch(_ path: String) -> String {
        String(format: text("run.current_batch", defaultValue: "Current batch starts with: %@", comment: "Run progress detail; placeholder is first file path in the active batch."), path)
    }

    static func processingFailures(_ count: Int) -> String {
        String(localized: "run.processing_failures", defaultValue: "\(count) files couldn't be processed — details when this finishes", bundle: .module, comment: "Run progress warning; count of failures whose details appear after completion.")
    }

    static func stopped(_ count: Int) -> String {
        String(localized: "run.stopped", defaultValue: "Stopped after \(count) files", bundle: .module, comment: "Cancelled run headline; count of successfully finished files.")
    }

    static func decompressed(_ count: Int) -> String {
        String(localized: "run.decompressed", defaultValue: "Decompressed \(count) files", bundle: .module, comment: "Decompression outcome headline; count restored to full disk size.")
    }

    static func compressed(_ count: Int) -> String {
        String(localized: "run.compressed", defaultValue: "\(count) files compressed", bundle: .module, comment: "Compression outcome detail; count successfully compressed.")
    }

    static func hadProblems(_ count: Int) -> String {
        String(localized: "run.had_problems", defaultValue: "\(count) files had problems", bundle: .module, comment: "Run outcome detail; number of real failures needing attention.")
    }

    static func leftAlone(_ count: Int) -> String {
        String(localized: "run.left_alone", defaultValue: "\(count) left alone", bundle: .module, comment: "Run outcome detail; count the compressor declined without changing.")
    }

    static func reclaimed(_ bytes: String) -> String {
        String(format: text("run.reclaimed", defaultValue: "Reclaimed %@", comment: "Compression outcome headline; formatted disk space recovered."), bytes)
    }

    static func returnedToDisk(_ bytes: String) -> String {
        String(format: text("run.returned", defaultValue: "%@ returned to disk", comment: "Decompression outcome detail; formatted additional disk space now occupied."), bytes)
    }

    static func duration(_ seconds: Double) -> String {
        String(format: text("run.duration", defaultValue: "%@s", comment: "Run duration; localized decimal seconds, with abbreviated seconds suffix."), seconds.formatted(.number.precision(.fractionLength(1))))
    }

    static let eligible = text("result.eligible", defaultValue: "Eligible", comment: "Summary statistic; files allowed to be compressed.")
    static let alreadyCompressed = text("result.already_compressed", defaultValue: "Already compressed", comment: "Summary statistic; files already using transparent compression.")
    static let excluded = text("result.excluded", defaultValue: "Excluded", comment: "Summary statistic; files omitted by safety rules.")
    static let forSafety = text("result.for_safety", defaultValue: "for safety", comment: "Excluded statistic detail; explains why files are omitted.")
    static let onDisk = text("result.on_disk", defaultValue: "On disk", comment: "Statistic and file table column; actual allocated storage.")
    static let nothingToCompress = text("result.nothing_to_compress", defaultValue: "Nothing left to compress here", comment: "Summary headline when no eligible uncompressed files remain.")
    static let compressionCoverage = text("result.coverage_label", defaultValue: "Compression coverage", comment: "Accessibility label for the bar comparing compressed, eligible and excluded files.")
    static let name = text("result.name", defaultValue: "Name", comment: "File table column and sort option; file name.")
    static let size = text("result.size", defaultValue: "Size", comment: "File table column; logical uncompressed byte size.")
    static let state = text("result.state", defaultValue: "State", comment: "File table column; compression or safety exclusion state.")
    static let compressedState = text("result.compressed", defaultValue: "Compressed", comment: "File state fallback when compression type is unknown.")
    static let notCompressed = text("result.not_compressed", defaultValue: "Not compressed", comment: "File state for eligible files not yet compressed.")
    static let showExcluded = text("result.show_excluded", defaultValue: "Show excluded", comment: "Status bar toggle; includes files excluded by safety rules in the table.")
    static let sort = text("result.sort", defaultValue: "Sort", comment: "Status bar picker for ordering the file table.")
    static let hardLinkHelp = text("result.hard_link_help", defaultValue: "These paths share storage with another file, so their bytes are counted only once.", comment: "Duplicate hard link count tooltip; explains storage is not double-counted.")
    static let largestFirst = text("result.sort_largest", defaultValue: "Largest first", comment: "File sort option ordering by descending logical size.")
    static let compressionState = text("result.sort_state", defaultValue: "Compression state", comment: "File sort option grouping by compressed state.")

    static func files(_ count: Int) -> String {
        String(localized: "result.files", defaultValue: "\(count) files", bundle: .module, comment: "Summary statistic value; number of files in the category named above it.")
    }

    static func couldCompress(_ count: Int) -> String {
        String(localized: "result.could_compress", defaultValue: "\(count) files could be compressed", bundle: .module, comment: "Summary headline; count eligible for compression, without promising an estimated saving.")
    }

    static func hardLinksCountedOnce(_ count: Int) -> String {
        String(localized: "result.hard_links", defaultValue: "\(count) hard links counted once", bundle: .module, comment: "Status bar note; duplicate paths sharing storage were counted once.")
    }

    static func truncatedFiles(_ count: Int) -> String {
        String(localized: "result.truncated", defaultValue: "Showing first \(count) files — totals cover everything", bundle: .module, comment: "Status bar warning; table is truncated to this count but summary totals include all files.")
    }

    static func reclaimedDetail(_ bytes: String) -> String {
        String(format: text("result.reclaimed", defaultValue: "%@ reclaimed", comment: "Already compressed statistic detail; formatted space already recovered."), bytes)
    }

    static func logicalSize(_ bytes: String) -> String {
        String(format: text("result.logical_size", defaultValue: "of %@ logical", comment: "On disk statistic detail; formatted full uncompressed size for comparison."), bytes)
    }

    static func eligibleData(_ bytes: String) -> String {
        String(format: text("result.eligible_data", defaultValue: "%@ of eligible data", comment: "Summary subheading; formatted logical size of eligible files."), bytes)
    }

    static func folderCompressed(_ percent: String) -> String {
        String(format: text("result.folder_compressed", defaultValue: "%@ of this folder is already compressed", comment: "Summary subheading; formatted percentage of files already compressed."), percent)
    }

    static func coverage(_ percent: String, _ eligible: String, _ excluded: String) -> String {
        String(format: text("result.coverage_value", defaultValue: "%@ compressed, %@ eligible, %@ excluded for safety", comment: "Coverage bar accessibility value; formatted percentage then localized eligible and excluded file counts."), percent, eligible, excluded)
    }

    static func scannedIn(_ seconds: Double) -> String {
        String(format: text("result.scanned_in", defaultValue: "Scanned in %@", comment: "Status bar; placeholder is a localized duration in seconds."), duration(seconds))
    }

    static let noScheduledSweeps = text("model.no_schedule", defaultValue: "No scheduled sweeps", comment: "Inspector next-run status when the folder has no active schedule.")
    static let nextOpportunity = text("model.next_opportunity", defaultValue: "Will sweep at the next opportunity", comment: "Inspector next-run status before a first completed sweep establishes an interval.")
    static let dueNow = text("model.due_now", defaultValue: "Due now", comment: "Inspector next-run status when the scheduled interval has elapsed.")
    static let scanningOnly = text("model.scanning_only", defaultValue: "Compressor unavailable — scanning only", comment: "Advanced settings compressor summary; files can be inspected but not changed.")
    static let bundled = text("model.bundled", defaultValue: "Bundled", comment: "Compressor summary source; executable included with Pomace.")
    static let custom = text("model.custom", defaultValue: "Custom", comment: "Compressor summary source; executable selected by the user.")
    static let customAdministratorWarning = text("model.custom_administrator_warning", defaultValue: "\n\nCustom compressor: This is a compressor you chose, not the one bundled with Pomace. It will run with administrator privileges.", comment: "Elevated run confirmation suffix; warns that the user-selected executable receives administrator privileges.")
    static let folderChanged = text("model.folder_changed", defaultValue: "The selected folder changed. Start the operation again.", comment: "Run refusal after folder selection changed during administrator confirmation.")
    static let nothingCompressed = text("model.nothing_compressed", defaultValue: "Nothing here is compressed.", comment: "Decompression refusal when there are no compressed target files.")
    static let folderUnavailable = text("model.folder_unavailable", defaultValue: "That folder is no longer available. It may have been moved, renamed, or its disk ejected.", comment: "Scan failure; selected directory no longer exists or cannot be reached.")

    static func nextSweep(_ date: String) -> String {
        String(format: text("model.next_sweep", defaultValue: "Next sweep %@", comment: "Inspector next-run status; placeholder is a localized relative time."), date)
    }

    static func toolSummary(_ version: String, _ source: String) -> String {
        String(format: text("model.tool_summary", defaultValue: "%@ — %@", comment: "Advanced compressor summary; tool name with version, then localized source label."), version, source)
    }

    static func administratorConfirmation(_ operation: String, _ count: Int, _ root: String, _ executable: String, _ warning: String) -> String {
        String(localized: "model.administrator_confirmation", defaultValue: "\(operation) \(count) scanned files in \(root)?\n\nThe compressor at \(executable) will run as administrator. macOS will ask for authorization; Pomace does not store your password. Safety exclusions still apply.\(warning)", bundle: .module, comment: "Elevated run confirmation; operation action, scanned file count, root path, exact executable path, and optional custom-executable warning.")
    }

    static let compressionTrend = text("inspector.trend", defaultValue: "Compression Trend", comment: "Inspector chart heading; tracks how compressed file coverage changes over time.")
    static let firstScanBaseline = text("inspector.baseline", defaultValue: "The first scan will establish this folder's baseline.", comment: "Empty trend chart explanation; the first scan supplies the comparison point.")
    static let coverageOverTime = text("inspector.coverage_label", defaultValue: "Compression coverage over time", comment: "Trend chart accessibility label; historical fraction of files compressed.")
    static let sweep = text("inspector.sweep", defaultValue: "Sweep", comment: "Schedule cadence picker; controls how often folders are revisited.")
    static let around = text("inspector.around", defaultValue: "Around", comment: "Preferred hour picker; sweeps run approximately at this time.")
    static let scheduledSweeps = text("inspector.scheduled_sweeps", defaultValue: "Scheduled sweeps", comment: "Accessibility label for the actual background service registration status.")
    static let openLoginItems = text("inspector.open_login_items", defaultValue: "Open Login Items…", comment: "Inspector action opening system settings to approve the background helper.")
    static let backgroundService = text("inspector.background_service", defaultValue: "Background sweep service", comment: "Inspector toggle registering or unregistering the recurring background helper.")
    static let sweeping = text("inspector.sweeping", defaultValue: "Sweeping…", comment: "Inspector action label while an immediate sweep is running.")
    static let sweepNowHelp = text("inspector.sweep_now_help", defaultValue: "Runs the same sweep the schedule would, right now", comment: "Sweep Now tooltip; immediately uses the normal scheduled sweep behavior.")
    static let history = text("inspector.history", defaultValue: "History", comment: "Inspector heading for past sweep outcomes.")
    static let noSweeps = text("inspector.no_sweeps", defaultValue: "No sweeps yet.", comment: "Empty sweep history message.")
    static let midnight = text("inspector.midnight", defaultValue: "midnight", comment: "Preferred sweep hour label for the start of the day.")
    static let noon = text("inspector.noon", defaultValue: "noon", comment: "Preferred sweep hour label for the middle of the day.")

    static func currentlyReclaimed(_ bytes: String) -> String {
        String(format: text("inspector.reclaimed", defaultValue: "%@ currently reclaimed", comment: "Trend summary detail; formatted disk space currently saved."), bytes)
    }

    static func trendCompressed(_ percent: String, _ reclaimed: String) -> String {
        String(format: text("inspector.compressed", defaultValue: "%@ compressed · %@", comment: "First trend summary; formatted current coverage followed by current reclaimed-space phrase."), percent, reclaimed)
    }

    static func trendSteady(_ percent: String, _ reclaimed: String) -> String {
        String(format: text("inspector.steady", defaultValue: "Coverage is steady at %@ · %@", comment: "Trend summary when coverage changed less than half a percentage point; coverage then reclaimed-space phrase."), percent, reclaimed)
    }

    static func trendRose(_ percent: String, _ reclaimed: String) -> String {
        String(format: text("inspector.rose", defaultValue: "Coverage rose %@ since the first saved scan · %@", comment: "Trend summary for increased coverage; magnitude in percentage points then reclaimed-space phrase."), percent, reclaimed)
    }

    static func trendFell(_ percent: String, _ reclaimed: String) -> String {
        String(format: text("inspector.fell", defaultValue: "Coverage fell %@ since the first saved scan · %@", comment: "Trend summary for decreased coverage; magnitude in percentage points then reclaimed-space phrase."), percent, reclaimed)
    }

    static let notificationHelp = text("notification.open_help", defaultValue: "Open Pomace to see which files were skipped and why.", comment: "Multi-folder failure notification body; directs the user to actionable details in the app.")

    static func sweepFailed(_ folder: String) -> String {
        String(format: text("notification.sweep_failed", defaultValue: "Pomace couldn't finish sweeping %@", comment: "Single-folder failure notification title; placeholder is folder name."), folder)
    }

    static func notificationSkipped(_ count: Int) -> String {
        String(localized: "notification.skipped", defaultValue: "\(count) files were skipped.", bundle: .module, comment: "Single-folder failure notification body; count skipped. Preserve the existing singular wording in English.")
    }

    static func foldersFailed(_ count: Int) -> String {
        String(localized: "notification.folders_failed", defaultValue: "Pomace had trouble with \(count) folders", bundle: .module, comment: "Multi-folder failure notification title; count of folders with unsuccessful sweeps.")
    }

    static func text(_ key: String, defaultValue: String, comment: String) -> String {
        NSLocalizedString(
            key,
            tableName: "Localizable",
            bundle: .module,
            value: defaultValue,
            comment: comment
        )
    }
}
