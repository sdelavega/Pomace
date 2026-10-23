import SwiftUI
import AppKit
import Carbon

// Some SwiftUI confirmation sheets omit the native cancel binding when Cancel is also
// the default button. Route Escape to the same action while a confirmation is presented.
struct ConfirmationEscapeHandler: NSViewRepresentable {
    let isPresented: Bool
    let onCancel: () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onCancel = isPresented ? onCancel : nil
        view.updateMonitor()
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stopMonitoring() }

    final class MonitorView: NSView {
        var onCancel: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            setAccessibilityElement(false)
            updateMonitor()
        }

        func updateMonitor() {
            guard window != nil, onCancel != nil else { stopMonitoring(); return }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == UInt16(kVK_Escape),
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                      let cancel = self?.onCancel else { return event }
                cancel()
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
