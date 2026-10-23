// Checks interactive labels in a disposable, read-only debug scan.
import AppKit
import ApplicationServices
import Carbon

func fail(_ message: String) -> Never {
    fputs("check-ax: \(message)\n", stderr)
    exit(1)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func string(_ element: AXUIElement, _ name: String) -> String {
    (attribute(element, name) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func checkConfirmations(_ application: AXUIElement, processID: pid_t) throws {
    func descendants(_ roots: [AXUIElement]) -> [AXUIElement] {
        var result: [AXUIElement] = []
        func visit(_ element: AXUIElement) {
            guard result.count < 2_000, !result.contains(where: { CFEqual($0, element) }) else { return }
            result.append(element)
            for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { visit(child) }
        }
        roots.forEach(visit)
        return result
    }
    func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    func label(_ element: AXUIElement) -> String {
        let title = string(element, kAXTitleAttribute)
        return title.isEmpty ? string(element, kAXDescriptionAttribute) : title
    }
    func dialog() -> AXUIElement? {
        let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return descendants(windows).first { elementAttribute($0, kAXDefaultButtonAttribute) != nil }
    }
    func waitForDialog(present: Bool) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            let current = dialog()
            if (current != nil) == present { return current }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return dialog()
    }
    guard let running = NSRunningApplication(processIdentifier: processID), running.activate(options: []) else {
        throw CheckError.failed("could not activate the confirmation fixture")
    }
    guard let menuBar = elementAttribute(application, kAXMenuBarAttribute),
          let fixtureMenu = (attribute(menuBar, kAXChildrenAttribute) as? [AXUIElement] ?? []).first(where: {
              string($0, kAXTitleAttribute) == "State"
          }) else { throw CheckError.failed("confirmation fixture menu unavailable") }
    let canPostKeys = CGPreflightPostEventAccess()
    for (command, name) in [("Decompress", "Decompress"), ("Authorize administrator access?", "Administrator")] {
        for (keyName, keyCode) in [("Return", kVK_Return), ("Escape", kVK_Escape)] {
            guard AXUIElementPerformAction(fixtureMenu, kAXPressAction as CFString) == .success,
                  let item = descendants([fixtureMenu]).first(where: {
                      string($0, kAXRoleAttribute) == kAXMenuItemRole && label($0) == command
                  }), AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
                throw CheckError.failed("could not open \(name) confirmation")
            }
            guard let sheet = waitForDialog(present: true),
                  let defaultButton = elementAttribute(sheet, kAXDefaultButtonAttribute) else {
                throw CheckError.failed("\(name) confirmation has no AXDefaultButton")
            }
            let defaultName = label(defaultButton)
            guard defaultName == "Cancel" else {
                throw CheckError.failed("\(name) AXDefaultButton is \(defaultName), expected Cancel")
            }
            let cancelButton = elementAttribute(sheet, kAXCancelButtonAttribute)
            if let cancelButton, label(cancelButton) != "Cancel" {
                throw CheckError.failed("\(name) AXCancelButton is not Cancel")
            }
            if canPostKeys {
                // Let the menu close and the newly presented sheet take keyboard focus.
                Thread.sleep(forTimeInterval: 0.2)
                for down in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: down) else {
                        throw CheckError.failed("could not create confirmation key event")
                    }
                    event.flags = []
                    event.postToPid(processID)
                }
            } else {
                guard AXUIElementPerformAction(defaultButton, kAXPressAction as CFString) == .success else {
                    throw CheckError.failed("could not close the confirmation fixture")
                }
            }
            guard waitForDialog(present: false) == nil else {
                throw CheckError.failed("\(name) confirmation did not close after \(keyName)")
            }
            let cancelName = cancelButton.map(label) ?? "not exposed"
            let keyResult = canPostKeys ? "\(keyName) dismissed" : "key check skipped (event posting permission not granted)"
            print("check-ax: \(name) AXDefaultButton=\(defaultName), AXCancelButton=\(cancelName); \(keyResult)")
        }
    }
}

// CGSession.h documents nil for no Quartz GUI session / disabled window server,
// and defines the console/login keys. The runtime lock key has no SDK constant.
func hasUnlockedGUISession(_ session: [String: Any]?) -> Bool {
    guard let session,
          session[kCGSessionOnConsoleKey as String] as? Bool == true,
          session[kCGSessionLoginDoneKey as String] as? Bool == true else { return false }
    return session["CGSSessionScreenIsLocked"] as? Bool != true
}

func check() throws {
    guard hasUnlockedGUISession(CGSessionCopyCurrentDictionary() as? [String: Any]) else {
        print("check-ax: skipped (no unlocked GUI session)")
        return
    }
    guard AXIsProcessTrusted() else {
        print("check-ax: skipped (Accessibility permission not granted)")
        return
    }
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("Pomace-AX-\(UUID())")
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: fixture)
        try? FileManager.default.removeItem(at: fixture.appendingPathExtension("log"))
    }
    try Data(repeating: 65, count: 8192).write(to: fixture.appendingPathComponent("Accessible fixture.txt"))
    try Data(repeating: 66, count: 8192).write(to: fixture.appendingPathComponent("Warning fixture.jpg"))
    try Data().write(to: fixture.appendingPathComponent("Empty fixture.txt"))

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "build/Pomace.app/Contents/MacOS/Pomace")
    process.arguments = ["-PomaceUITestFixture", fixture.path, "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    let application = AXUIElementCreateApplication(process.processIdentifier)
    AXUIElementSetMessagingTimeout(application, 2)
    let checkedRoles = Set([kAXButtonRole, kAXCheckBoxRole, kAXPopUpButtonRole, kAXTextFieldRole, kAXRowRole])
    let deadline = Date().addingTimeInterval(20)
    var failures: [String] = []
    var checked = 0
    var rows = 0
    var fixtureVisible = false
    var namedRows: [String] = []
    repeat {
        guard process.isRunning else { throw CheckError.failed("fixture app exited before inspection") }
        var visited: [AXUIElement] = []

        failures = []
        checked = 0
        rows = 0
        fixtureVisible = false
        namedRows = []
        func walk(_ element: AXUIElement) {
            guard visited.count < 20_000, !visited.contains(where: { CFEqual($0, element) }) else { return }
            visited.append(element)
            let role = string(element, kAXRoleAttribute)
            let title = string(element, kAXTitleAttribute)
            let description = string(element, kAXDescriptionAttribute)
            let value = string(element, kAXValueAttribute)

            if [title, description, value].contains(where: { $0.contains("Accessible fixture.txt") }) {
                fixtureVisible = true
            }
            if checkedRoles.contains(role) {
                checked += 1
                if role == kAXRowRole {
                    rows += 1
                    namedRows.append(title + " " + description)
                }
                if title.isEmpty && description.isEmpty {
                    let children = (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).map {
                        "\(string($0, kAXRoleAttribute)):\(string($0, kAXValueAttribute)):\(string($0, kAXDescriptionAttribute))"
                    }.joined(separator: ", ")
                    failures.append("\(role) has no AXTitle or AXDescription (value=\(value), id=\(string(element, kAXIdentifierAttribute)), children=[\(children)])")
                }
            }
            for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child) }
        }
        for window in attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? [] { walk(window) }
        if visited.count >= 20_000 { throw CheckError.failed("AX tree exceeded traversal limit") }
        if fixtureVisible && rows >= 3 && checked >= 5 && failures.isEmpty { break }
        Thread.sleep(forTimeInterval: 0.2)
    } while Date() < deadline

    guard fixtureVisible && rows >= 3 && checked >= 5 else {
        throw CheckError.failed("fixture did not expose populated rows and interactive controls (visible=\(fixtureVisible), rows=\(rows), controls=\(checked))")
    }
    guard failures.isEmpty else { throw CheckError.failed(failures.joined(separator: "; ")) }
    for name in ["Accessible fixture.txt", "Warning fixture.jpg", "Empty fixture.txt"] {
        guard namedRows.contains(where: { $0.contains(name) }) else {
            throw CheckError.failed("fixture row does not speak its filename")
        }
    }
    let expectedShortcuts = Set(["o:0", "r:0", "return:0", "return:1", ".:0"])
    var shortcuts: [String: Int] = [:]
    func commands(_ element: AXUIElement, depth: Int) {
        guard depth < 20 else { return }
        if string(element, kAXRoleAttribute) == kAXMenuItemRole {
            let keyCode = (attribute(element, kAXMenuItemCmdVirtualKeyAttribute) as? NSNumber)?.intValue
            let key = keyCode == kVK_Return ? "return" : string(element, kAXMenuItemCmdCharAttribute).lowercased()
            if let modifiers = attribute(element, kAXMenuItemCmdModifiersAttribute) as? NSNumber {
                let shortcut = "\(key):\(modifiers.intValue)"
                if expectedShortcuts.contains(shortcut) { shortcuts[shortcut, default: 0] += 1 }
            }
        }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            commands(child, depth: depth + 1)
        }
    }
    guard let menu = attribute(application, kAXMenuBarAttribute) else {
        throw CheckError.failed("app menu bar unavailable")
    }
    // The Apple menu contains system-wide items; inspect the app's own menus only.
    for item in (attribute(menu as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] ?? []).dropFirst() {
        commands(item, depth: 0)
    }
    guard expectedShortcuts.allSatisfy({ shortcuts[$0] == 1 }) else {
        throw CheckError.failed("missing or conflicting menu shortcuts: \(shortcuts)")
    }
    try checkConfirmations(application, processID: process.processIdentifier)
    print("check-ax: passed (\(checked) interactive elements, \(rows) rows, 5 unique shortcuts)")
}

enum CheckError: Error { case failed(String) }

#if !CHECK_AX_SESSION_TEST
do { try check() } catch { fail(String(describing: error)) }
#endif
