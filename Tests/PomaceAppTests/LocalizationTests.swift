import Foundation
import Testing
@testable import PomaceApp

@Suite("App localization")
struct LocalizationTests {
    @Test("every locale contains compiled strings and plural rules", arguments: ["en", "zh-Hans", "es", "ja", "ko", "de", "fr", "pt-BR"])
    func compiledCatalog(_ locale: String) throws {
        let stringsURL = try #require(Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: "\(locale).lproj"))
        let strings = try Data(contentsOf: stringsURL)
        #expect(!strings.isEmpty)
        let url = try #require(Bundle.module.url(forResource: "Localizable", withExtension: "stringsdict", subdirectory: "\(locale).lproj"))
        let data = try Data(contentsOf: url)
        let table = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(table["content.decompress_question"] != nil)
        #expect(table["model.administrator_confirmation"] != nil)
    }

    @Test("count templates load zero singular and plural forms", arguments: [0, 1, 2])
    func counts(_ count: Int) {
        let noun = count == 1 ? "file" : "files"
        let hardLink = count == 1 ? "hard link" : "hard links"
        #expect(AppStrings.files(count) == "\(count) \(noun)")
        #expect(AppStrings.decompressQuestion(count) == "Decompress \(count) \(noun)?")
        #expect(AppStrings.decompressAction(count) == "Decompress \(count) \(noun)")
        #expect(AppStrings.examined(count) == "\(count) \(noun) examined")
        #expect(AppStrings.compressEligible(count) == "Compress \(count) eligible \(noun)")
        #expect(AppStrings.processingFailures(count) == "\(count) \(noun) couldn't be processed — details when this finishes")
        #expect(AppStrings.stopped(count) == "Stopped after \(count) \(noun)")
        #expect(AppStrings.decompressed(count) == "Decompressed \(count) \(noun)")
        #expect(AppStrings.compressed(count) == "\(count) \(noun) compressed")
        #expect(AppStrings.hadProblems(count) == "\(count) \(noun) had problems")
        #expect(AppStrings.couldCompress(count) == "\(count) \(noun) could be compressed")
        #expect(AppStrings.hardLinksCountedOnce(count) == "\(count) \(hardLink) counted once")
        #expect(AppStrings.leftAlone(count) == "\(count) left alone")
        // Preserve the notification's existing English, including its singular grammar.
        #expect(AppStrings.notificationSkipped(count) == "\(count) \(noun) were skipped.")
        #expect(AppStrings.foldersFailed(count) == "Pomace had trouble with \(count) folders")
    }

    @Test("plural templates retain every positional payload", arguments: [1, 2])
    func positionalPayloads(_ count: Int) {
        let noun = count == 1 ? "file" : "files"
        #expect(AppStrings.runProgress("Compressing", count, 1234) == "Compressing — \(count) \(noun) of \(1234.formatted())")
        let root = "/Users/alex/Folder with spaces"
        let executable = "/tmp/Custom compressor"
        let warning = AppStrings.customAdministratorWarning
        #expect(!warning.isEmpty)
        #expect(AppStrings.administratorConfirmation("Compress", count, root, executable, warning) == "Compress \(count) scanned \(noun) in \(root)?\n\nThe compressor at \(executable) will run as administrator. macOS will ask for authorization; Pomace does not store your password. Safety exclusions still apply.\(warning)")
    }

    @Test("UI numeric values use the requested system formatters")
    func formatters() {
        let bytes = ByteCountFormatter()
        bytes.countStyle = .file
        bytes.allowsNonnumericFormatting = false
        for count: Int64 in [0, 1000, 4096, 5_000_000_000] {
            #expect(Fmt.bytes(count) == bytes.string(fromByteCount: count))
        }
        #expect(Fmt.percent(0.126) == 0.126.formatted(.percent.precision(.fractionLength(0))))
        #expect(AppStrings.scannedIn(1.25) == "Scanned in \(1.25.formatted(.number.precision(.fractionLength(1))))s")
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 15))!
        #expect(Fmt.hour(15) == date.formatted(Date.FormatStyle().hour(.defaultDigits(amPM: .abbreviated))))
        #expect(Fmt.hour(0) == "midnight")
        #expect(Fmt.hour(12) == "noon")
    }
}
