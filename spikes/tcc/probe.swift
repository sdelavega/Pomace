// M0 TCC-inheritance probe. Tests the central assumption behind ADR-0006: that a
// launchd-spawned instance of the SAME signed binary inherits the GUI app's TCC grants.
//
//   probe --register   register the LaunchAgent via SMAppService, report status
//   probe --unregister remove it
//   probe --gui        read TCC-protected dirs as the foreground app
//   probe --agent      same reads, but invoked by launchd; appends to the shared log
//
// If --gui succeeds and --agent fails, ADR-0006 is wrong and scheduling needs a
// privileged SMAppService.daemon helper instead.

import Foundation
import ServiceManagement

let logPath = NSString(string: "~/Library/Application Support/PomaceTCCProbe/probe.log")
    .expandingTildeInPath

func log(_ s: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(s)\n"
    FileManager.default.createFile(atPath: logPath, contents: nil)
    try? FileManager.default.createDirectory(
        atPath: (logPath as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true)
    if let fh = FileHandle(forWritingAtPath: logPath) {
        fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close()
    } else {
        try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
    print(line, terminator: "")
}

/// Two tiers of protected path:
///  - "consent" tier (Desktop/Documents/Downloads): a per-app TCC prompt normally gates these.
///  - "FDA" tier: readable ONLY with Full Disk Access. This is the discriminator — if both
///    the GUI and the agent are denied here, TCC is genuinely enforcing and any agreement on
///    the consent tier is not just TCC failing to engage.
func probeAccess(_ label: String) {
    var results: [String] = []

    for dir in ["Desktop", "Documents", "Downloads"] {
        let path = NSString(string: "~/\(dir)").expandingTildeInPath
        do {
            let n = try FileManager.default.contentsOfDirectory(atPath: path).count
            results.append("\(dir)=OK(\(n))")
        } catch {
            results.append("\(dir)=DENIED(\((error as NSError).code))")
        }
    }

    let fdaPaths = [
        ("TCC.db", "~/Library/Application Support/com.apple.TCC/TCC.db"),
        ("Mail",   "~/Library/Mail"),
        ("Safari", "~/Library/Safari"),
    ]
    for (name, raw) in fdaPaths {
        let path = NSString(string: raw).expandingTildeInPath
        if FileManager.default.fileExists(atPath: path) {
            if let fh = FileHandle(forReadingAtPath: path) {
                try? fh.close(); results.append("FDA:\(name)=OK")
            } else if (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil {
                results.append("FDA:\(name)=OK")
            } else {
                results.append("FDA:\(name)=DENIED")
            }
        } else {
            results.append("FDA:\(name)=absent")
        }
    }

    // Who does the system hold responsible for this process's TCC decisions?
    let ppid = getppid()
    log("\(label): uid=\(geteuid()) pid=\(getpid()) ppid=\(ppid) | " + results.joined(separator: " "))
}

let plistName = "org.pomace.PomaceTCCProbe.plist"
let mode = CommandLine.arguments.dropFirst().first ?? "--gui"

switch mode {
case "--register":
    let service = SMAppService.agent(plistName: plistName)
    log("pre-register status: \(service.status.rawValue)")
    do {
        try service.register()
        log("registered OK; status now \(service.status.rawValue) (1=enabled 2=requiresApproval 3=notFound)")
    } catch {
        log("register FAILED: \(error)")
    }

case "--unregister":
    let service = SMAppService.agent(plistName: plistName)
    do { try service.unregister(); log("unregistered OK") }
    catch { log("unregister failed: \(error)") }

case "--status":
    let service = SMAppService.agent(plistName: plistName)
    log("status: \(service.status.rawValue) (0=notRegistered 1=enabled 2=requiresApproval 3=notFound)")

case "--agent":
    probeAccess("AGENT (launchd-spawned)")

default:
    probeAccess("GUI (foreground)")
}
