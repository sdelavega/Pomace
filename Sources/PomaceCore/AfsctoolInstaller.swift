import Foundation

/// Installs afsctool on the user's behalf.
///
/// Pomace never bundles or redistributes it (ADR-0003) — the binary belongs to the user's
/// system. The caller must have disclosed what is being installed, from where, and under
/// which license before calling this.
public enum AfsctoolInstaller {

    public enum Result: Sendable {
        case success(String)
        case failure(String)
    }

    static let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    public static var homebrewPath: String? {
        brewPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static var homebrewAvailable: Bool { homebrewPath != nil }

    public static func installViaHomebrew() async -> Result {
        guard let brew = homebrewPath else {
            return .failure("Homebrew isn't installed.")
        }
        return await withCheckedContinuation { continuation in
            Task.detached {
                let out = Subprocess.capture(brew, ["install", "afsctool"])
                if out.succeeded || AfsctoolLocator.locate() != nil {
                    continuation.resume(returning: .success(out.combined))
                } else {
                    let detail = out.combined
                        .split(separator: "\n")
                        .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        .map(String.init) ?? "Homebrew reported an error."
                    continuation.resume(returning: .failure(detail))
                }
            }
        }
    }
}
