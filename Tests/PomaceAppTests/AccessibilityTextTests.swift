import Foundation
import Testing
@testable import PomaceCore
@testable import PomaceApp

@Suite("Accessibility text")
struct AccessibilityTextTests {
    @Test("coverage speaks the percentage and localized saved bytes")
    func coverageValueSpeaksPercentAndBytes() {
        let saved: Int64 = 1_500_000_000
        let bytes = Fmt.bytes(saved)
        #expect(!bytes.isEmpty)
        let value = CoverageBar.accessibilityValueText(fraction: 0.42, saved: saved)
        #expect(value.contains("42%"))
        #expect(value.contains(bytes))
        #expect(value == "42% compressed, \(bytes) saved")
    }

    @Test("sidebar sections and spoken rows share the same ordered groups")
    func sidebarGroupingKeepsLabelsAligned() {
        let paths = ["/Users/alex/Manual", "/Users/alex/Daily", "/Users/alex/Weekly"]
        let groups = SidebarGroup.grouped(paths, isScheduled: { $0 != paths[0] })
        #expect(groups.count == 2)
        #expect(groups.map(\.isScheduled) == [true, false])
        #expect(groups.map(\.paths) == [[paths[1], paths[2]], [paths[0]]])
        #expect(groups.map(\.title) == [AppStrings.scheduled, AppStrings.notScheduled])
        let labels = groups.flatMap { $0.accessibilityLabels(scheduleSummary: { _ in AppStrings.noScheduledSweeps }) }
        #expect(labels == [AppStrings.scheduled,
                           AppStrings.accessibilityDetail("Daily", AppStrings.noScheduledSweeps),
                           AppStrings.accessibilityDetail("Weekly", AppStrings.noScheduledSweeps),
                           AppStrings.notScheduled,
                           AppStrings.accessibilityDetail("Manual", AppStrings.noScheduledSweeps)])
        #expect(SidebarGroup.grouped([], isScheduled: { _ in true }).isEmpty)
        let scheduled = SidebarGroup.grouped(paths, isScheduled: { _ in true })
        #expect(scheduled.count == 1)
        #expect(scheduled.first?.isScheduled == true)
        #expect(scheduled.first?.paths == paths)
        let manual = SidebarGroup.grouped(paths, isScheduled: { _ in false })
        #expect(manual.count == 1)
        #expect(manual.first?.isScheduled == false)
        #expect(manual.first?.paths == paths)
    }

    @Test("debug fixture scans without persisting or starting a run")
    @MainActor
    func fixtureIsReadOnly() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = temp.appendingPathComponent("fixture.txt")
        let data = Data(repeating: 65, count: 8192)
        try data.write(to: file)
        let helper = temp.appendingPathExtension("sh")
        defer { try? FileManager.default.removeItem(at: helper) }
        try """
        #!/bin/sh
        case "$*" in
            --version) echo 'applesauce 0.5.30' ;;
            'compress --help') echo 'lzfse --verify --minimum-compression-ratio' ;;
            *) exit 1 ;;
        esac
        """.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let installation = CompressorTool.probe(.custom(helper.path))
        #expect(installation.capabilities.isUsable)
        let logURL = temp.appendingPathExtension("log")
        let lockURL = temp.appendingPathExtension("lock")
        defer {
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: lockURL)
        }
        let model = ScanModel(store: nil, resolution: CompressorResolution(installation: installation, customRejection: nil),
                              log: MutationLog(url: logURL), sweepLockURL: lockURL)
        model.prepareUITestFixture(temp.path)
        for _ in 0..<200 {
            if model.result != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let result = try #require(model.result)
        #expect(result.root == temp.path)
        #expect(result.entries.count == 1)
        #expect(result.progress.eligibleFiles == 1)
        #expect(model.watchedPaths == [temp.path])
        #expect(!model.showingOnboarding)
        model.startCompress()
        model.sweepNow()
        #expect(!model.isRunning)
        #expect(!model.isSweeping)
        if case .none = model.runState {} else { Issue.record("Fixture started or prepared a mutation") }
        #expect(try Data(contentsOf: file) == data)
    }

    @Test("every existing row badge names its state and retains its detail")
    func stateBadgeLabelNamesState() {
        let states: [(FileRowState, String)] = [
            (.excluded(.zeroLength), AppStrings.excluded),
            (.compressed(nil), AppStrings.compressedState),
            (.warning(.likelyIncompressible("JPEG")), AppStrings.state),
            (.notCompressed, AppStrings.notCompressed),
        ]
        #expect(states.count == 4)
        for (state, name) in states {
            #expect(!name.isEmpty)
            #expect(!state.accessibilityLabelText.isEmpty)
            #expect(state.accessibilityLabelText.contains(name))
        }
        #expect(FileRowState.excluded(.zeroLength).accessibilityLabelText.contains(SafetyReason.zeroLength.text))
        #expect(FileRowState.warning(.likelyIncompressible("JPEG")).accessibilityLabelText.contains(SafetyReason.likelyIncompressible("JPEG").text))
        #expect(CompressionType.allCases.count == 7)
        for type in CompressionType.allCases {
            let label = FileRowState.compressed(type).accessibilityLabelText
            #expect(label.contains(AppStrings.compressedState))
            #expect(label.contains(type.text))
        }
    }
}
