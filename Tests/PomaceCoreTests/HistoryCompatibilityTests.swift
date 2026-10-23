import Foundation
import Testing
@testable import PomaceCore

@Suite("1.0.2 history compatibility")
struct HistoryCompatibilityTests {
    @Test("history written by 1.0.2 still decodes")
    func history102Decodes() throws {
        let fixture = try #require(Bundle.module.url(forResource: "history-1.0.2", withExtension: "sqlite", subdirectory: "Fixtures"))
        #expect(try fixture.resourceValues(forKeys: [.fileSizeKey]).fileSize! > 0)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let copy = temp.appendingPathComponent("history.sqlite")
        try FileManager.default.copyItem(at: fixture, to: copy)
        let store = try Store(url: copy)
        let path = "/Users/alex/Documents/Fixture"
        let watched = try #require(store.watched().first)
        #expect(watched.path == path)
        #expect(watched.mode == .maximumSavings)
        #expect(watched.mode.rawValue == "Maximum savings")
        let runs = try store.sweepHistory(path: path)
        #expect(runs.count == 3)
        let failed = try #require(runs.first)
        #expect(failed.error == "Fixture compressor error")
        #expect(failed.filesFailed == 1)
        #expect(failed.deferral == nil)
        let deferred = try #require(runs.first { $0.deferral != nil })
        #expect(deferred.deferral == .onBattery)
        #expect(deferred.error == nil)
        let completed = try #require(runs.first { $0.filesCompressed > 0 })
        #expect(completed.filesCompressed == 3)
        #expect(completed.bytesReclaimed == 4096)
        #expect(completed.error == nil)
        #expect(completed.deferral == nil)
        #expect(!completed.cancelled)
    }

    @Test("runtime constraints report every condition in display priority order")
    func allConstraints() {
        #expect(RuntimeConditions().constraints.isEmpty)
        #expect(RuntimeConditions(onBattery: true, lowPowerMode: true, thermalPressure: true, slowMedia: true).constraints == [.thermalPressure, .lowPowerMode, .onBattery, .slowMedia])
    }
}
