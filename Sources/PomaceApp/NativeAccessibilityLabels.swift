import SwiftUI
import AppKit
import PomaceCore

// SwiftUI does not pass cell text through to native row labels. Supply those labels and
// the system's localized subrole names for otherwise unnamed standard window/scroller buttons.
struct NativeAccessibilityLabels: NSViewRepresentable {
    let sidebarLabels: [String]
    let fileEntries: [ScanEntry]

    func makeNSView(context: Context) -> LabelingView { LabelingView() }

    func updateNSView(_ view: LabelingView, context: Context) {
        view.sidebarLabels = sidebarLabels
        view.fileEntries = fileEntries
        DispatchQueue.main.async { view.applyLabels() }
    }

    final class LabelingView: NSView {
        var sidebarLabels: [String] = []
        var fileEntries: [ScanEntry] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            setAccessibilityElement(false)
            NotificationCenter.default.removeObserver(self)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(applyLabels),
                                                       name: NSWindow.didUpdateNotification, object: window)
            }
        }

        @objc func applyLabels() {
            guard let window else { return }
            var visited: Set<ObjectIdentifier> = []
            func labelButtons(_ element: any NSAccessibilityProtocol, depth: Int) {
                guard depth < 24, visited.count < 20_000,
                      visited.insert(ObjectIdentifier(element)).inserted else { return }
                if element.accessibilityRole() == .button,
                   (element.accessibilityLabel() ?? "").isEmpty,
                   (element.accessibilityTitle() ?? "").isEmpty,
                   let subrole = element.accessibilitySubrole(),
                   let name = NSAccessibility.Role.button.description(with: subrole) {
                    element.setAccessibilityLabel(name)
                }
                for child in element.accessibilityChildren() ?? [] {
                    if let child = child as? any NSAccessibilityProtocol { labelButtons(child, depth: depth + 1) }
                }
            }
            labelButtons(window, depth: 0)
            func labelTables(_ view: NSView) {
                if let table = view as? NSTableView {
                    // Virtual outline rows do not adopt the modern protocol. The public
                    // legacy override API supplies their descriptions without replacing them.
                    let rows = table.accessibilityAttributeValue(.visibleRows) as? [NSObject] ?? []
                    let visibleRange = table.rows(in: table.visibleRect)
                    for (offset, row) in rows.enumerated() {
                        let index = (row.accessibilityAttributeValue(.index) as? NSNumber)?.intValue
                            ?? visibleRange.location + offset
                        let name: String
                        if table.numberOfColumns == 4, fileEntries.indices.contains(index) {
                            let entry = fileEntries[index]
                            name = AppStrings.accessibilityDetail(entry.name, ListFormatter.localizedString(byJoining: [
                                AppStrings.accessibilityDetail(AppStrings.size, Fmt.bytes(entry.logicalSize)),
                                AppStrings.accessibilityDetail(AppStrings.onDisk, Fmt.bytes(entry.physicalSize)),
                                FileRowState(entry: entry).accessibilityLabelText,
                            ]))
                        } else if table.numberOfColumns == 1, sidebarLabels.indices.contains(index) {
                            name = sidebarLabels[index]
                        } else { continue }
                        row.accessibilitySetOverrideValue(name, forAttribute: .description)
                    }
                }
                view.subviews.forEach(labelTables)
            }
            if let content = window.contentView { labelTables(content) }
        }
    }
}
