import Foundation
import Testing
@testable import PomaceCore

@Suite("Diagnostics redaction")
struct RedactorTests {
    private func redactor(_ paths: [String] = []) -> Redactor {
        Redactor(homeDirectory: URL(fileURLWithPath: "/Users/alex"), userName: "alex",
                 hostName: "alex-mbp", roots: paths.map { URL(fileURLWithPath: $0) })
    }

    @Test func homeBecomesTilde() {
        #expect(redactor().redact("/Users/alex/Desktop/a.txt") == "~/Desktop/a.txt")
    }

    @Test func rootContentsHidden() {
        let text = "/Users/alex/Projects/Secret Plans/über/x.mov"
        #expect(text.contains("Secret") && text.contains("über") && text.contains("x.mov"))
        let result = redactor(["/Users/alex/Projects/Secret Plans"]).redact(text)
        #expect(result.contains("<folder-1>") && result.contains("user folder"))
        for secret in ["Secret", "über", "x.mov"] { #expect(!result.contains(secret)) }
    }

    @Test func volumeNameHidden() {
        let result = redactor().redact("/Volumes/Alex's Drive/f")
        #expect(result.contains("/Volumes/<volume>"))
        #expect(!result.contains("Alex's") && !result.contains("Drive"))
    }

    @Test func jsonEscapedPathRedacted() {
        let text = #"{"home":"\/Users\/alex\/Library","root":"\/Users\/alex\/Secret Plans\/über\/x.mov"}"#
        #expect(text.contains(#"\/Users"#))
        let result = redactor(["/Users/alex/Secret Plans"]).redact(text)
        #expect(result.contains("~/Library"))
        #expect(result.contains("<folder-1>"))
        for secret in ["alex", "Secret", "über", "x.mov"] { #expect(!result.contains(secret)) }
    }

    @Test func bareUserAndHostRedacted() {
        #expect(redactor().redact("alex@alex-mbp") == "<user>@<host>")
        #expect(redactor().redact("alexander alex_mbp") == "alexander alex_mbp")
    }

    @Test func tempFoldersRedacted() {
        let result = redactor().redact("/private/var/folders/ab/xyz/T/f\n/var/folders/ab/xyz/C/f")
        #expect(result.contains("<temporary folder>"))
        #expect(!result.contains("xyz") && !result.contains("/ab/"))
    }

    @Test func rootKindsAndBoundaries() {
        let paths = ["/Applications", "/opt/homebrew", "/usr/local/Cellar", "/Volumes/Alex's Drive", "/Users/alex/Plans"]
        let text = paths.map { $0 + "/private name/über.txt" }.joined(separator: "\n")
        let result = redactor(paths).redact(text)
        for kind in ["Applications", "Homebrew", "external volume", "user folder"] { #expect(result.contains(kind)) }
        for n in 1...5 { #expect(result.contains("<folder-\(n)>")) }
        #expect(!result.contains("private name") && !result.contains("über.txt"))
        #expect(redactor(["/Users/alex/Plans"]).redact("/Users/alex/Plans2/file") == "~/Plans2/file")
    }

    @Test func overlappingRootsKeepTheirIdentity() {
        let result = redactor(["/Users/alex/Plans", "/Users/alex/Plans/Nested"]).redact("/Users/alex/Plans/Nested/secret.txt")
        #expect(result.contains("<folder-2>"))
        #expect(!result.contains("Nested") && !result.contains("secret.txt"))
    }

    @Test func jsonKeepsAdjacentDiagnosticFieldsAndEscapedUnicode() {
        let text = #"{"path":"\/Users\/alex\/Secret Plans\/\u00fcber\/x.mov","volume":"\/Volumes\/Alex's Drive\/f","reason":"test crash","count":42}"#
        #expect(text.contains(#"\u00fc"#))
        let result = redactor(["/Users/alex/Secret Plans"]).redact(text)
        #expect(result.contains("<folder-1>"))
        #expect(result.contains("test crash") && result.contains("42"))
        for secret in ["alex", "Secret", "über", "x.mov", #"\u00fc"#] { #expect(!result.contains(secret)) }
    }

    @Test(arguments: ["file:///Users/alex/Café/secret.mov", "/Users/alex/Cafe\u{0301}/secret.mov"])
    func equivalentPathFormsAreRedacted(path: String) {
        #expect(path.contains("secret.mov"))
        let result = redactor(["/Users/alex/Café"]).redact(path)
        #expect(result.contains("<folder-1>"))
        #expect(!result.contains("secret.mov") && !result.contains("Caf"))
    }

    @Test func namesAreLiteralAndEmptyNamesAreSafe() {
        let r = Redactor(homeDirectory: URL(fileURLWithPath: "/Users/alex"), userName: "alex",
                         hostName: "alex.local", roots: [])
        #expect(r.redact("alex.local alexXlocal alex") == "<host> alexXlocal <user>")
        let empty = Redactor(homeDirectory: URL(fileURLWithPath: "/Users/alex"), userName: "", hostName: "", roots: [])
        #expect(empty.redact("/Users/alex/a") == "~/a")
    }
}
