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
      crosscheck <dir>                our physical-size figures vs afsctool -v, per file
      verify <dir> [--compressor T]   full compress/decompress integrity cycle
      parse <file>                    parse afsctool -v output for one file
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

let afsctool = ["/opt/homebrew/bin/afsctool", "/usr/local/bin/afsctool"]
    .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "afsctool"

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
    print("background sweep:   -J\(p.threadCount(foreground: false))   (\(p.justification))")
    print("foreground run:     -J\(p.threadCount(foreground: true))")
    print("battery/thermal:    -J\(p.threadCount(foreground: false, constrained: true))")
    print("external media:     -j\(p.threadCount(foreground: false, slowMedia: true))")

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

case "parse":
    guard let path = positional.first else { print("need file"); exit(2) }
    let r = run(afsctool, ["-v", path])
    let p = AfsctoolOutput.parse(r.out)
    print("path:        \(p.path ?? "—")")
    print("type:        \(p.compressionTypeText ?? "—")  raw=\(p.compressionTypeRaw.map(String.init) ?? "—")")
    print("content:     \(p.contentType ?? "—")")
    print("uncompressed:\(p.uncompressedSize.map(String.init) ?? "—")")
    print("compressed:  \(p.compressedSize.map(String.init) ?? "—")")
    print("savings:     \(p.savingsPercent.map { "\($0)%" } ?? "—")")
    print("unparsed:    \(p.unparsedLines.count) line(s)")
    for l in p.unparsedLines { print("   ? \(l)") }

case "crosscheck":
    guard let dir = positional.first else { print("need dir"); exit(2) }
    var files: [FileFacts] = []
    _ = DirectoryWalker.walkFTS(dir) { if $0.isRegularFile { files.append($0) } }
    var agree = 0, disagree = 0, afsctoolZero = 0
    print("comparing our physical-size figures against afsctool -v on \(files.count) files\n")
    for f in files {
        let r = run(afsctool, ["-v", f.path])
        let p = AfsctoolOutput.parse(r.out)
        guard let theirs = p.compressedSize else { continue }
        let ours = f.physicalSize
        if theirs == 0 && ours > 0 {
            afsctoolZero += 1
            if afsctoolZero <= 3 {
                print("  afsctool reports 0, we report \(ours)  [\(f.type?.description ?? "?")]  \((f.path as NSString).lastPathComponent)")
            }
        } else if theirs == ours { agree += 1 } else {
            disagree += 1
            if disagree <= 5 {
                print("  MISMATCH ours=\(ours) theirs=\(theirs) [\(f.type?.description ?? "?")] \((f.path as NSString).lastPathComponent)")
            }
        }
    }
    print("\nagree=\(agree)  disagree=\(disagree)  afsctool-reported-zero=\(afsctoolZero)")
    print(afsctoolZero > 0
          ? "afsctool under-reports inline-xattr storage as 0 bytes; our figure is the accurate one."
          : "")

case "verify":
    guard let dir = positional.first else { print("need dir"); exit(2) }
    let comp = flag("--compressor") ?? "LZFSE"
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
    let c = run(afsctool, ["-c", "-T", comp, "-J4", "-S", "-f", "-v", dir])
    let dt = now() - t0
    print(String(format: "  afsctool exit=%d in %.1fs\n", c.code, dt))

    let afterC = snapshot(dir)
    check(c.code == 0, "afsctool -c exited cleanly")
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
    let d = run(afsctool, ["-d", dir])
    print("  afsctool exit=\(d.code)\n")
    let afterD = snapshot(dir)
    check(d.code == 0, "afsctool -d exited cleanly")
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

default:
    print("unknown command: \(cmd)"); exit(2)
}
