# Accessibility release walkthrough

Complete this checklist with the coordinator and user before release. Use a disposable folder with ordinary compressible files, an empty file and a file excluded for safety. Record the macOS version, app build, language and any assistive technology settings with the results. Leave the result columns empty until each check is performed.

Keyboard navigation uses Tab and Shift-Tab within regions, with F6 and Shift-F6 cycling sidebar → file table → inspector (when visible). Enable the system's keyboard navigation option for the full keyboard-only walkthrough. Command-Option-S shows the inspector.

| Check | Expected result | Pass | Fail |
|---|---|---|---|
| Keyboard: scan | Command-O opens the folder picker. Select the disposable folder with the keyboard and start its read-only scan. | | |
| Keyboard: rescan | Command-R rescans the selected folder. | | |
| Keyboard: region order | F6 visits sidebar, table, then visible inspector; Shift-F6 reverses the order (use Fn if the keyboard assigns media functions to F6). Arrow keys select folders and file rows. Tab reaches each region's controls without trapping focus. | | |
| Keyboard: compress | Command-Return starts compression of eligible disposable files. Stop with Command-period; the active batch finishes safely. | | |
| Keyboard: decompress | Shift-Command-Return opens confirmation. Return chooses Cancel; Escape also cancels. Explicitly select Decompress to proceed, then verify the files still open. PENDING: the coordinator must rerun AXDefaultButton=Cancel and Return/Escape dismissal with an unlocked GUI session before release; the full file workflow remains manual. | | |
| Keyboard: administrator confirmation | On a supported disposable location, enable administrator privileges. Return and Escape both cancel the confirmation. Proceed only by explicitly selecting Continue as Administrator. PENDING: the coordinator must rerun AXDefaultButton=Cancel and Return/Escape dismissal with an unlocked GUI session before release; the full administrator workflow remains manual. | | |
| Keyboard: settings | Command-comma opens Settings. Reach each tab, toggle, mode and compressor chooser with the keyboard; close the window or sheet without a mouse. | | |
| Keyboard: shortcut conflicts | File-menu shortcuts are unique: Command-O, Command-R, Command-Return, Shift-Command-Return, Command-period. Standard Settings, Hide, Quit and window shortcuts still work. | | |
| VoiceOver: sidebar | The Folders region and each folder name and schedule are spoken. | | |
| VoiceOver: summary | Compression coverage speaks the compressed percentage and localized saved bytes. Statistics have readable labels and values. | | |
| VoiceOver: file table | The Files region, column headings, filenames and full states/exclusion reasons are spoken. Compressed states include the compression type when known. | | |
| VoiceOver: progress and outcome | Run progress speaks processed count out of total files. Scan progress speaks files examined (the final total is unknown during scanning). Stop, failure details and completed outcomes are understandable. | | |
| VoiceOver: inspector | Schedule controls and service status are named. The coverage timeline exposes a list of dated saved-space values. Sweep history reads each date and outcome. | | |
| VoiceOver: settings and dialogs | Both Settings panes and each confirmation have named controls; the safe default and Cancel actions are clear. | | |
| Largest text size | At the largest available system text size, inspect summary, table, inspector, Settings, onboarding and confirmations. Text remains readable; wrapping and scrolling expose long content. Repeat with German or another long-string locale. | | |
| Reduce Motion | Turn on Reduce Motion before launch and while scanning. Decorative numeric transitions and animations stop; scan and run progress remain understandable. | | |
| Increase Contrast | With Increase Contrast enabled, coverage, states, controls, separators and focus indicators remain legible. | | |
| Differentiate Without Color | With this setting enabled, every state remains identifiable from its text and symbol; color is never the only cue. | | |

Automated checks run through `scripts/gate.sh`: accessibility text tests, release-binary fixture exclusion, and a compiled `scripts/check-ax.swift` against the debug bundle. The AX checker launches its own scan-only fixture and terminates it afterward. It checks titles/descriptions on buttons, checkboxes, pop-up buttons, text fields and rows, and requires populated rows to avoid an empty-tree pass. Before launching the fixture, it checks the current Quartz session. If there is no GUI session, the session is off-console or login is incomplete, or the screen is locked, it prints `check-ax: skipped (no unlocked GUI session)` and exits successfully. If Accessibility permission is absent it prints `check-ax: skipped (Accessibility permission not granted)` and exits successfully. It never prompts or changes privacy settings. The checker also opens each real confirmation twice, asserts AXDefaultButton is Cancel, inspects AXCancelButton when exposed, and sends Return and Escape only if the non-prompting event-posting preflight succeeds. Otherwise it explicitly reports that the key check was skipped.

Fix round 1 verification (2026-10-23): **PENDING**. The screen is locked while the user is away. Per the coordinator ruling, a successful gate with the GUI-session skip does not verify either confirmation's AXDefaultButton or Return/Escape behavior. The coordinator must rerun the checker with an unlocked session and record the macOS version, build and language before release. The implementation gives Cancel one default shortcut and a cancel role, with an app-local Escape handler active only while a confirmation is presented. The complete keyboard/file/authorization workflows and all unfilled cells remain for manual release validation.
