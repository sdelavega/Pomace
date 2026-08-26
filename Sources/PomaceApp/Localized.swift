import Foundation

enum AppStrings {
    static let onboardingTitle = text(
        "onboarding.title",
        defaultValue: "Pomace",
        comment: "First-run window title."
    )

    static let onboardingBody = text(
        "onboarding.body",
        defaultValue: "Pomace keeps selected folders smaller using macOS transparent compression. Files still open normally, with no archive to manage. Writing a compressed file expands it again, so Pomace can periodically recheck watched folders. Every compression is verified, and you can decompress files whenever you need to.",
        comment: "First-run explanation of transparent compression and its write behavior."
    )

    static let onboardingGetStarted = text(
        "onboarding.get_started",
        defaultValue: "Get Started",
        comment: "Confirms the first-run explanation."
    )

    private static func text(_ key: String, defaultValue: String, comment: String) -> String {
        NSLocalizedString(
            key,
            tableName: "Localizable",
            bundle: .module,
            value: defaultValue,
            comment: comment
        )
    }
}
