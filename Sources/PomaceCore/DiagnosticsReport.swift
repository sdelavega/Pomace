import Foundation

public struct DiagnosticsInput: Sendable {
    public var appVersion, build, osVersion, architecture: String
    public var compressor: CompressorResolution
    public var agentRegistered: Bool
    public var logLines: [String]
    public var crashReports: [(name: String, contents: String)]
    public var scannedRoots: [URL]
    public var homeDirectory: URL
    public var userName, hostName: String

    public init(appVersion: String, build: String, osVersion: String, architecture: String,
                compressor: CompressorResolution, agentRegistered: Bool, logLines: [String],
                crashReports: [(name: String, contents: String)], scannedRoots: [URL],
                homeDirectory: URL, userName: String, hostName: String) {
        self.appVersion = appVersion
        self.build = build
        self.osVersion = osVersion
        self.architecture = architecture
        self.compressor = compressor
        self.agentRegistered = agentRegistered
        self.logLines = logLines
        self.crashReports = crashReports
        self.scannedRoots = scannedRoots
        self.homeDirectory = homeDirectory
        self.userName = userName
        self.hostName = hostName
    }
}

/// Reports are maintainer-facing English, independent of the app's interface language.
public enum DiagnosticsReport {
    public static func render(_ input: DiagnosticsInput) -> String {
        var lines = ["Pomace diagnostics", "App: \(input.appVersion) (\(input.build))",
                     "OS: \(input.osVersion)", "Architecture: \(input.architecture)"]
        if let installation = input.compressor.installation {
            let source: String
            switch installation.source {
            case .bundled: source = "bundled"
            case .custom: source = "custom"
            }
            lines.append("Compressor: \(source), version \(installation.capabilities.version?.description ?? "unknown")")
            lines.append("Compressor path: \(installation.path)")
        } else {
            lines.append("Compressor: unavailable")
        }
        if let rejection = input.compressor.customRejection {
            lines.append("Custom compressor rejection: \(String(describing: rejection))")
        }
        lines.append("Agent registered: \(input.agentRegistered ? "yes" : "no")")
        lines += ["", "Recent Pomace log lines and sweep history:"]
        lines += input.logLines.isEmpty ? ["No log lines available"] : input.logLines
        lines += ["", "Pomace crash reports (last 30 days):"]
        if input.crashReports.isEmpty { lines.append("No crash reports available") }
        for crash in input.crashReports {
            lines += ["", "--- \(crash.name) ---", crash.contents]
        }
        return Redactor(homeDirectory: input.homeDirectory, userName: input.userName,
                        hostName: input.hostName, roots: input.scannedRoots)
            .redact(lines.joined(separator: "\n"))
    }

    /// The budget must fit the fixed GitHub URL and attachment note (about 150 characters).
    /// It counts the fully percent-encoded URL, rather than the unescaped body.
    public static func githubIssueURL(body: String, maxURLLength: Int = 7500) -> URL {
        func makeURL(_ text: String) -> URL {
            var components = URLComponents(string: "https://github.com/sdelavega/Pomace/issues/new")!
            components.queryItems = [URLQueryItem(name: "title", value: ""), URLQueryItem(name: "body", value: text)]
            return components.url!
        }
        let complete = makeURL(body)
        if complete.absoluteString.count <= maxURLLength { return complete }
        let note = "\n\nReport truncated; please attach the saved report."
        precondition(maxURLLength >= makeURL(note).absoluteString.count, "URL budget must fit the attachment note")
        let characters = Array(body)
        var lower = 0, upper = characters.count
        while lower < upper {
            let middle = (lower + upper + 1) / 2
            if makeURL(String(characters.prefix(middle)) + note).absoluteString.count <= maxURLLength {
                lower = middle
            } else {
                upper = middle - 1
            }
        }
        return makeURL(String(characters.prefix(lower)) + note)
    }
}

/// File locations are supplied explicitly so tests never touch a user's diagnostics.
public enum DiagnosticsFiles {
    public static func logLines(at url: URL, limit: Int = 500) -> [String] {
        guard limit > 0, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard var offset = try? handle.seekToEnd() else { return [] }
        var data = Data(), newlines = 0
        do {
            while offset > 0 && newlines <= limit {
                let size = min(offset, 64 * 1024)
                offset -= size
                try handle.seek(toOffset: offset)
                let chunk = try handle.read(upToCount: Int(size)) ?? Data()
                newlines += chunk.filter { $0 == 10 }.count
                data.insert(contentsOf: chunk, at: 0)
            }
        } catch { return [] }
        guard !data.isEmpty else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast(data.last == 10 ? 1 : 0).suffix(limit).map { String($0).trimmingCharacters(in: .newlines) }
    }

    public static func crashReports(in directory: URL, now: Date = Date()) -> [(name: String, contents: String)] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return [] }
        let cutoff = now.addingTimeInterval(-30 * 86400)
        return urls.filter { $0.lastPathComponent.hasPrefix("Pomace") && $0.pathExtension == "ips" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                      values.isSymbolicLink != true, let date = values.contentModificationDate,
                      date >= cutoff, date <= now, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return (url.lastPathComponent, text)
            }
    }
}
