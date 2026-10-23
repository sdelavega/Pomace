import Foundation

/// Deliberately discards the remainder of a line below a private root. File names can
/// contain spaces and punctuation, so guessing a path's end could disclose its contents.
public struct Redactor: Sendable {
    private let home: String
    private let userName: String
    private let hostName: String
    private let roots: [(path: String, label: String)]

    public init(homeDirectory: URL, userName: String, hostName: String, roots: [URL]) {
        home = homeDirectory.standardizedFileURL.path.precomposedStringWithCanonicalMapping
        self.userName = userName.precomposedStringWithCanonicalMapping
        self.hostName = hostName.precomposedStringWithCanonicalMapping
        self.roots = roots.enumerated().map { index, url in
            let path = url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
            let kind: String
            if path == "/Applications" || path.hasPrefix("/Applications/") {
                kind = "Applications"
            } else if path == "/opt/homebrew" || path.hasPrefix("/opt/homebrew/") ||
                      path == "/usr/local" || path.hasPrefix("/usr/local/") {
                kind = "Homebrew"
            } else if path.hasPrefix("/Volumes/") {
                kind = "external volume"
            } else {
                kind = "user folder"
            }
            return (path, "<folder-\(index + 1)> (\(kind))")
        }.sorted { $0.path.count > $1.path.count }
    }

    public func redact(_ text: String) -> String {
        var result = text
        // Decode JSON string tokens individually so escaped Unicode paths are covered,
        // while unrelated crash fields on the same line remain useful to the maintainer.
        let tokens = try! NSRegularExpression(pattern: #""(?:\\.|[^"\\])*""#)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        for match in tokens.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result),
                  let value = try? JSONDecoder().decode(String.self, from: Data(result[range].utf8)),
                  let data = try? encoder.encode(redactUnquoted(value)),
                  let encoded = String(data: data, encoding: .utf8) else { continue }
            result.replaceSubrange(range, with: encoded)
        }
        return redactUnquoted(result)
    }

    private func redactUnquoted(_ text: String) -> String {
        // Crash reports may encode every slash. The result is plain text, not JSON.
        var result = text.precomposedStringWithCanonicalMapping.replacingOccurrences(of: #"\/"#, with: "/")
        for root in roots {
            let path = NSRegularExpression.escapedPattern(for: root.path)
            result = replacing(path + #"(?=/|[\s"',;)}\]]|$)(?:/[^\r\n]*)?"#,
                               in: result, with: root.label)
        }
        let homePath = NSRegularExpression.escapedPattern(for: home)
        result = replacing(homePath + #"(?=/|[\s"',;)}\]]|$)"#, in: result, with: "~")
        result = replacing(#"/Volumes/(?!<volume>(?:"|\r|\n|$))[^\r\n]+"#, in: result, with: "/Volumes/<volume>")
        result = replacing(#"/(?:private/)?var/folders/[^\r\n]+"#, in: result, with: "<temporary folder>")
        // Match the host first: a host such as alex-mbp contains the whole word alex.
        let names = [(hostName, "<host>"), (userName, "<user>")].filter { !$0.0.isEmpty }
        guard !names.isEmpty else { return result }
        let pattern = #"(?<![\p{L}\p{N}_])(?:"# + names.map {
            NSRegularExpression.escapedPattern(for: $0.0)
        }.joined(separator: "|") + #")(?![\p{L}\p{N}_])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let range = Range(match.range, in: result),
                  let replacement = names.first(where: { $0.0 == String(result[range]) })?.1 else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }
}
