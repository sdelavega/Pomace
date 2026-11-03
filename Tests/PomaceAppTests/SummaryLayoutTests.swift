import AppKit
import SwiftUI
import Testing
@testable import PomaceCore
@testable import PomaceApp

@Suite("scan summary layout", .serialized)
@MainActor
struct SummaryLayoutTests {
    @Test("all metrics and actions leave room for the file table at supported window sizes")
    func fitsWithoutScrolling() {
        // Detail-pane space after sidebar/inspector, including the smallest supported window.
        let sizes = [CGSize(width: 808, height: 768), CGSize(width: 676, height: 508),
                     CGSize(width: 388, height: 508), CGSize(width: 300, height: 508)]
        for size in sizes {
            for administrator in [false, true] {
                let model = ScanModel(store: nil)
                var result = ScanResult()
                result.root = administrator ? "/Applications" : "/tmp/PomaceLayout"
                result.progress.filesSeen = 259_410
                result.progress.eligibleFiles = 55_882
                result.progress.compressedFiles = 202_257
                result.progress.excludedFiles = 1_271
                result.progress.eligibleLogicalBytes = 5_500_000_000
                result.progress.logicalBytes = 20_900_000_000
                result.progress.physicalBytes = 11_800_000_000
                result.progress.compressedLogicalBytes = 15_000_000_000
                result.progress.compressedPhysicalBytes = 5_700_000_000
                model.selectedPath = result.root
                model.state = .done(result)
                #expect(model.administratorAvailable == administrator,
                        "Exercise both administrator and standard action layouts")

                let host = NSHostingView(rootView:
                    ScanOverview(model: model, result: result, availableSize: size)
                        .frame(width: size.width - 24)
                        .fixedSize(horizontal: false, vertical: true)
                        .aetherTheme())
                host.frame = CGRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let measured = host.fittingSize
                #expect(measured.height >= 160, "The test must measure laid-out summary content")
                #expect(measured.width <= size.width,
                        "Summary overflowed horizontally at \(size), administrator: \(administrator)")
                // Reserve outer padding, footer, and at least several file rows.
                #expect(measured.height <= size.height - 112,
                        "Summary needs scrolling at \(size): \(measured.height), administrator: \(administrator)")
            }
        }
    }
}
