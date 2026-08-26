import Foundation
import CryptoKit
import PomaceCore

// M0 spike harness. Verifies the assumptions docs/ROADMAP.md M0 lists before any UI exists.

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    print("""
    pomace-spike <command>
      inspect <paths...>              per-file detection detail
      profile                         machine profile and computed thread policy
      walk <dir> [--repeat N]         FTS vs FileManager walk benchmark
      crosscheck <dir>                our physical-size figures vs the tool's own, per file
      verify <dir> [--compressor T]   full compress/decompress integrity cycle
    """)
    exit(2)
}
let rest = Array(args.dropFirst())
func flag(_ name: String) -> String? {
    guard let i = rest.firstIndex(of: name), i + 1 < rest.count else { return nil }
    return rest[i + 1]
}
let positional = { () -> [String] in
    var out: [String] = [], skip = false
    for a in rest {
        if skip { skip = false; continue }
        if a.hasPrefix("--") { skip = true; continue }
        out.append(a)
    }
    return out
}()

@discardableResult
func run(_ launch: String, _ argv: [String]) -> (out: String, err: String, code: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launch)
    p.arguments = argv
    let o = Pipe(), e = Pipe()
    p.standardOutput = o; p.standardError = e
    do { try p.run() } catch { return ("", "\(error)", -1) }
    let od = o.fileHandleForReading.readDataToEndOfFile()
    let ed = e.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(decoding: od, as: UTF8.self), String(decoding: ed, as: UTF8.self), p.terminationStatus)
}

let toolPath = CompressorTool.locate()?.path ?? CompressorTool.executableName

func sha256(_ path: String) -> String? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    var h = SHA256()
    while let chunk = try? fh.read(upToCount: 1 << 20), !chunk.isEmpty { h.update(data: chunk) }
    return h.finalize().map { String(format: "%02x", $0) }.joined()
}

struct Snap { var sha: String?; var size: Int64; var nlink: UInt16; var ino: UInt64; var compressed: Bool }
func snapshot(_ dir: String) -> [String: Snap] {
    var map: [String: Snap] = [:]
    _ = DirectoryWalker.walkFTS(dir) { f in
        guard f.isRegularFile else { return }
        var st = stat(); lstat(f.path, &st)
        map[f.path] = Snap(sha: sha256(f.path), size: f.logicalSize,
                           nlink: f.linkCount, ino: UInt64(st.st_ino), compressed: f.isCompressed)
    }
    return map
}

func fmtBytes(_ b: Int64) -> String {
    let u = ["B", "KB", "MB", "GB", "TB"]; var v = Double(b), i = 0
    while v >= 1000, i < u.count - 1 { v /= 1000; i += 1 }
    return String(format: i == 0 ? "%.0f %@" : "%.2f %@", v, u[i])
}
func now() -> Double { Date().timeIntervalSince1970 }

switch cmd {

case "profile":
    let p = SystemProfile.current()
    print("Apple silicon:      \(p.isAppleSilicon)")
    print("performance cores:  \(p.performanceCores)")
    print("efficiency cores:   \(p.efficiencyCores)")
    print("physical cores:     \(p.physicalCores)")
    print("")
    print("(thread tuning removed with the applesauce pivot — it parallelises internally)")

case "inspect":
    for path in positional {
        guard let f = FileInspector.inspect(path) else { print("\(path): lstat failed"); continue }
        let t = f.type?.description ?? (f.rawType.map { "unknown(\($0))" } ?? "—")
        print(String(format: "%-40@ compressed=%@ logical=%10lld physical=%10lld saved=%6.1f%% xattr=%6d %@",
                     (path as NSString).lastPathComponent as NSString,
                     f.isCompressed ? "yes" : " no",
                     f.logicalSize, f.physicalSize, f.savedPercent, f.decmpfsXattrSize, t as NSString))
    }

case "walk":
    guard let dir = positional.first else { print("need dir"); exit(2) }
    let reps = Int(flag("--repeat") ?? "3") ?? 3
    print("walking \(dir), \(reps) reps each, best-of\n")

    func bench(_ name: String, _ body: () -> WalkResult) {
        var times: [Double] = []
        var last = DirectoryWalker.walkFTS("/nonexistent-warmup")
        for _ in 0..<reps { let t = now(); last = body(); times.append(now() - t) }
        let best = times.min() ?? 0
        print(String(format: "%-12@ best=%6.2fs  files=%7d dirs=%6d  files/sec=%8d",
                     name as NSString, best, last.files, last.directories,
                     best > 0 ? Int(Double(last.files) / best) : 0))
        if last.logicalTotal > 0 {
            print("             \(fmtBytes(last.logicalTotal)) logical / \(fmtBytes(last.physicalTotal)) physical, compressed=\(last.compressedFiles)")
        }
        if last.errors > 0 { print("             \(last.errors) unreadable entries (expected on system paths)") }
    }

    bench("FTS") { DirectoryWalker.walkFTS(dir) }
    bench("FTS-nostat") { DirectoryWalker.walkFTS(dir, inspect: false) }
    bench("FileManager") { DirectoryWalker.walkFileManager(dir) }

case "crosscheck":
    guard let dir = positional.first else { print("need dir"); exit(2) }
    guard let install = CompressorTool.discover() else { print("tool not found"); exit(1) }
    var files: [FileFacts] = []
    _ = DirectoryWalker.walkFTS(dir) { if $0.isRegularFile { files.append($0) } }
    var agree = 0, disagree = 0, toolZero = 0
    print("comparing our physical-size figures against `\(CompressorTool.displayName) info` on \(files.count) files\n")
    for f in files {
        let out = Subprocess.capture(install.path, ["info", f.path]).combined
        guard let line = out.split(separator: "\n").first(where: { $0.contains("Compressed size:") }),
              let theirs = Int64(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "")
        else { continue }
        let ours = f.physicalSize
        if theirs == 0 && ours > 0 {
            toolZero += 1
            if toolZero <= 3 {
                print("  tool reports 0, we report \(ours)  [\(f.type?.description ?? "?")]  \((f.path as NSString).lastPathComponent)")
            }
        } else if theirs == ours { agree += 1 } else {
            disagree += 1
            if disagree <= 5 {
                print("  MISMATCH ours=\(ours) theirs=\(theirs) [\(f.type?.description ?? "?")] \((f.path as NSString).lastPathComponent)")
            }
        }
    }
    print("\nagree=\(agree)  disagree=\(disagree)  tool-reported-zero=\(toolZero)")

case "verify":
    guard let dir = positional.first else { print("need dir"); exit(2) }
    let comp = flag("--compressor") ?? "lzfse"
    var failures: [String] = []
    func check(_ ok: Bool, _ label: String) {
        print("  [\(ok ? "PASS" : "FAIL")] \(label)")
        if !ok { failures.append(label) }
    }

    print("integrity cycle on \(dir) using \(comp)\n")
    let before = snapshot(dir)
    print("baseline: \(before.count) regular files\n")

    print("compressing…")
    let t0 = now()
    let c = run(toolPath, ["compress", "--verify", "-c", comp.lowercased(), dir])
    let dt = now() - t0
    print(String(format: "  compress exit=%d in %.1fs\n", c.code, dt))

    let afterC = snapshot(dir)
    check(c.code == 0, "compress exited cleanly")
    check(afterC.count == before.count, "file count unchanged (\(before.count) -> \(afterC.count))")
    var shaMismatch = 0, sizeMismatch = 0, nlinkMismatch = 0, inoChanged = 0, gotCompressed = 0
    for (path, b) in before {
        guard let a = afterC[path] else { continue }
        if a.sha != b.sha { shaMismatch += 1 }
        if a.size != b.size { sizeMismatch += 1 }
        if a.nlink != b.nlink { nlinkMismatch += 1 }
        if a.ino != b.ino { inoChanged += 1 }
        if a.compressed { gotCompressed += 1 }
    }
    check(shaMismatch == 0, "SHA-256 identical after compression (\(shaMismatch) mismatches)")
    check(sizeMismatch == 0, "logical size unchanged (\(sizeMismatch) mismatches)")
    check(nlinkMismatch == 0, "hard-link counts preserved (\(nlinkMismatch) mismatches)")
    check(inoChanged == 0, "inodes stable (\(inoChanged) changed)")
    print("  [INFO] \(gotCompressed)/\(before.count) files now carry UF_COMPRESSED")

    print("\ndecompressing…")
    let d = run(toolPath, ["decompress", dir])
    print("  decompress exit=\(d.code)\n")
    let afterD = snapshot(dir)
    check(d.code == 0, "decompress exited cleanly")
    var shaMismatch2 = 0, stillCompressed = 0
    for (path, b) in before {
        guard let a = afterD[path] else { continue }
        if a.sha != b.sha { shaMismatch2 += 1 }
        if a.compressed { stillCompressed += 1 }
    }
    check(shaMismatch2 == 0, "SHA-256 identical after round trip (\(shaMismatch2) mismatches)")
    check(stillCompressed == 0, "UF_COMPRESSED cleared (\(stillCompressed) still set)")

    print("\n\(failures.isEmpty ? "ALL CHECKS PASSED" : "FAILURES: \(failures.count)")")
    for f in failures { print("  - \(f)") }
    exit(failures.isEmpty ? 0 : 1)

case "scan":
    guard let dir = positional.first else { print("need dir"); exit(2) }
    // NOTE: an earlier version wrapped this in `Task { ... }` + `DispatchSemaphore.wait()`.
    // Top-level code in main.swift runs on the main actor, so the semaphore blocked the very
    // actor the Task needed to resume on — a deadlock that looked exactly like a slow scan.
    // main.swift supports top-level `await`; just use it.
    do {
        for await event in ScanEngine.scan(root: dir) {
            switch event {
            case .progress(let p):
                FileHandle.standardError.write(Data("\r  \(p.filesSeen) files… ".utf8))
            case .finished(let r):
                print("\r" + String(repeating: " ", count: 40))
                print("root:        \(r.root)  [\(r.volume.filesystem ?? "?")]")
                print("files:       \(r.progress.filesSeen)  dirs: \(r.progress.directoriesSeen)")
                print("logical:     \(ByteFormat.short(r.progress.logicalBytes))")
                print("physical:    \(ByteFormat.short(r.progress.physicalBytes))")
                print("reclaimed:   \(ByteFormat.short(r.reclaimedBytes))")
                print(String(format: "coverage:    %.1f%% of files already compressed", r.compressionCoverage * 100))
                print("excluded:    \(r.progress.excludedFiles)")
                print("eligible:    \(r.progress.eligibleFiles) files, \(ByteFormat.short(r.progress.eligibleLogicalBytes))")
                if r.entriesTruncated {
                    print("             (per-file detail capped at \(ScanEngine.maxRetainedEntries); totals cover the whole tree)")
                }
                print("hard-link dupes: \(r.hardLinkDuplicates)   unreadable: \(r.unreadableEntries)")
                print(String(format: "duration:    %.2fs", r.duration))
                let excluded = r.entries.filter { $0.isExcluded }.prefix(8)
                if !excluded.isEmpty {
                    print("\nsample exclusions:")
                    for e in excluded {
                        print("  \(e.name)")
                        for reason in e.reasons where reason.isHardExclusion {
                            print("     \(reason.explanation)")
                        }
                    }
                }
            }
        }
    }

case "engine-verify":
    guard let dir = positional.first else { print("need dir"); exit(2) }
    let mode = CompressionMode(rawValue: flag("--mode") ?? "Automatic") ?? .automatic
    guard let install = CompressorTool.discover() else {
        print("\(CompressorTool.displayName) not found"); exit(1)
    }
    print("\(CompressorTool.displayName): \(install.path) (\(install.source.description))")
    print("  version: \(install.capabilities.version?.description ?? "?")")
    print("  compressors: \(install.capabilities.compressors.sorted().joined(separator: ", "))")
    print("  usable: \(install.capabilities.isUsable)")
    if !install.capabilities.missingCapabilities.isEmpty {
        print("  missing: \(install.capabilities.missingCapabilities.joined(separator: ", "))")
    }

    let plan = CompressionPolicy.plan(mode: mode)
    print("\nplan (\(mode.rawValue)):")
    for j in plan.justifications {
        print("  \(j.label.padding(toLength: 14, withPad: " ", startingAt: 0)) \(j.value.padding(toLength: 18, withPad: " ", startingAt: 0)) \(j.reason)\(j.isFixed ? "  [fixed]" : "")")
    }
    print("  argv: \(plan.arguments.joined(separator: " "))")
    for w in plan.warnings { print("  ! \(w)") }

    var failures: [String] = []
    func check(_ ok: Bool, _ label: String) {
        print("  [\(ok ? "PASS" : "FAIL")] \(label)")
        if !ok { failures.append(label) }
    }

    var engineRefused: String?
    let before = snapshot(dir)
    print("\nbaseline: \(before.count) regular files")
    check(before.count > 0, "baseline inspected a non-empty file set")

    var allPaths: [String] = []
    _ = DirectoryWalker.walkFTS(dir) { if $0.isRegularFile { allPaths.append($0.path) } }

    // The log must live OUTSIDE the tree under test — writing it inside makes it a file
    // whose contents legitimately change mid-run, which reads as an integrity failure.
    let logURL = URL(fileURLWithPath: dir)
        .deletingLastPathComponent()
        .appendingPathComponent("pomace-mutations.log")
    let log = MutationLog(url: logURL)
    print("mutation log: \(logURL.path)")

    print("\ncompressing via CompressionEngine…")
    var compressOutcome: CompressionOutcome?
    for await ev in CompressionEngine.run(operation: .compress, paths: allPaths, root: dir,
                                          installation: install, plan: plan, logger: log) {
        switch ev {
        case .started(let p): print("  start: \(p.filesTotal) eligible")
        case .progress(let p):
            FileHandle.standardError.write(Data("\r  \(p.filesProcessed)/\(p.filesTotal)".utf8))
        case .finished(let o): compressOutcome = o
        case .failed(let m):
            print("  engine refused: \(m)")
            engineRefused = m
        }
    }
    print("")
    // A run that never happened must not report success. The M0 spike already made this
    // mistake once by iterating an empty set.
    check(engineRefused == nil, "engine ran (did not refuse: \(engineRefused ?? "-"))")
    check(compressOutcome != nil, "engine produced an outcome")
    if let o = compressOutcome {
        print(String(format: "  attempted=%d succeeded=%d problems=%d skipped=%d reclaimed=%@ in %.2fs",
                     o.filesAttempted, o.filesSucceeded, o.realFailures.count, o.skipped.count,
                     ByteFormat.short(o.bytesReclaimed), o.duration))
        for f in o.realFailures.prefix(5) {
            print("    PROBLEM \((f.path as NSString).lastPathComponent): \(f.message)")
            print("            -> \(f.remedy)")
        }
        for f in o.skipped.prefix(5) {
            print("    skipped \((f.path as NSString).lastPathComponent): \(f.message)")
        }
        check(o.realFailures.isEmpty, "no real failures (\(o.realFailures.count))")
        check(o.filesSucceeded > 0, "engine compressed at least one file")
        check(o.bytesReclaimed > 0, "engine reclaimed space")
    }

    let afterC = snapshot(dir)
    var mismatch = 0, nlinkBad = 0
    for (path, b) in before {
        guard let a = afterC[path] else { continue }
        if a.sha != b.sha {
            mismatch += 1
            if mismatch <= 5 { print("    CONTENT CHANGED: \(path)") }
        }
        if a.nlink != b.nlink { nlinkBad += 1 }
    }
    check(mismatch == 0, "SHA-256 identical after compression (\(mismatch) mismatches)")
    check(nlinkBad == 0, "hard-link counts preserved (\(nlinkBad) mismatches)")

    print("\ndecompressing via CompressionEngine…")
    for await ev in CompressionEngine.run(operation: .decompress, paths: allPaths, root: dir,
                                          installation: install, plan: plan, logger: log) {
        if case .finished(let o) = ev {
            print(String(format: "  attempted=%d succeeded=%d in %.2fs",
                         o.filesAttempted, o.filesSucceeded, o.duration))
        }
        if case .failed(let m) = ev { print("  engine refused: \(m)") }
    }
    let afterD = snapshot(dir)
    var mismatch2 = 0, stillCompressed = 0
    for (path, b) in before {
        guard let a = afterD[path] else { continue }
        if a.sha != b.sha {
            mismatch2 += 1
            if mismatch2 <= 5 { print("    CONTENT CHANGED: \(path)") }
        }
        if a.compressed { stillCompressed += 1 }
    }
    check(mismatch2 == 0, "SHA-256 identical after round trip (\(mismatch2) mismatches)")
    check(stillCompressed == 0, "UF_COMPRESSED cleared (\(stillCompressed) still set)")

    print("\n\(failures.isEmpty ? "ALL CHECKS PASSED" : "FAILURES: \(failures.count)")")
    for f in failures { print("  - \(f)") }
    exit(failures.isEmpty ? 0 : 1)

default:
    print("unknown command: \(cmd)"); exit(2)
}
