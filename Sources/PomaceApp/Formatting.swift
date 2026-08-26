import Foundation

/// Plain-String formatting helpers.
///
/// NOTE: do NOT use SwiftUI's `^[\(n) file](inflect: true)` markup here. That is
/// `LocalizedStringKey` syntax and only inflects when the literal reaches `Text` as a
/// localized key. Building a `String` first and passing it to `Text` selects the verbatim
/// overload, which renders the markup on screen exactly as written.
enum Fmt {

    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        let word = n == 1 ? singular : (plural ?? singular + "s")
        return "\(n.formatted(.number.grouping(.automatic))) \(word)"
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}
