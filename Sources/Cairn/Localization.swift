import Combine
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case japanese = "ja"

    var id: String { rawValue }

    var localeIdentifier: String { rawValue }

    var displayName: String {
        switch self {
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .japanese: "日本語"
        }
    }

    /// What Cairn opens in before anyone has chosen — the Mac's own preference,
    /// resolved to one of the three languages Cairn actually speaks.
    ///
    /// There is no "follow the system" entry in the menu because there is
    /// nothing for it to do: this *is* following the system, and the moment a
    /// person picks a language they have said what they want instead.
    static func matchingSystem(preferences: [String]? = nil) -> AppLanguage {
        let best = Bundle.preferredLocalizations(
            from: L10n.supportedLocales,
            forPreferences: preferences
        ).first
        return best.flatMap(AppLanguage.init(rawValue:)) ?? .english
    }
}

@MainActor
final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()
    nonisolated static let preferenceKey = "cairn.interfaceLanguage"

    @Published private(set) var selection: AppLanguage

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = Self.savedLanguage(in: defaults)
    }

    func select(_ language: AppLanguage) {
        // Written even when it matches what is already on screen: until now the
        // choice may only have been inherited from the system, and picking it
        // deliberately is what makes it stick.
        defaults.set(language.rawValue, forKey: Self.preferenceKey)
        guard selection != language else { return }

        selection = language
        NotificationCenter.default.post(name: .cairnLanguageDidChange, object: language)
    }

    nonisolated static func savedLanguage(in defaults: UserDefaults) -> AppLanguage {
        guard let rawValue = defaults.string(forKey: preferenceKey),
              let language = AppLanguage(rawValue: rawValue) else {
            return .matchingSystem()
        }
        return language
    }
}

extension Notification.Name {
    static let cairnLanguageDidChange = Notification.Name("app.cairn.languageDidChange")
    /// The first agent is connected and the connect window has closed. The
    /// desktop control answers this by introducing itself.
    static let cairnOnboardingDidFinish = Notification.Name("app.cairn.onboardingDidFinish")
    /// The app may show its surfaces without any introduction — an upgrade
    /// arrived already connected, so there was no first run to finish.
    static let cairnAppShouldStart = Notification.Name("app.cairn.appShouldStart")
    /// A newer release was found by the automatic check, and this version has
    /// not announced itself before. The desktop control answers by drawing a
    /// panel beside the stones. Carries the `AppUpdate` under
    /// `CairnUpdateAnnouncement.updateKey`.
    static let cairnUpdateDidArrive = Notification.Name("app.cairn.updateDidArrive")
}

/// Where every packaged resource is read from — strings, agent icons, anything
/// else the package ships.
///
/// SwiftPM's generated `Bundle.module` accessor expects its resource bundle
/// beside `Bundle.main`. A conventional macOS app keeps resources under
/// `Contents/Resources`, so prefer that packaged location and fall back to
/// SwiftPM's build/test location during development.
enum CairnResources {
    static var bundle: Bundle { packaged ?? .module }

    private static var packaged: Bundle? {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("Cairn_Cairn.bundle") else {
            return nil
        }
        return Bundle(url: url)
    }
}

/// One localization boundary for both SwiftUI and AppKit-created windows.
///
/// Cairn is a Swift package that is later assembled into a hand-built `.app`,
/// so its strings live in the package resource bundle rather than implicitly
/// in `Bundle.main`. Tests can also address one localization directly without
/// changing the Mac's preferred languages.
enum L10n {
    static let supportedLocales = ["en", "zh-Hans", "ja"]

    static func string(_ key: String) -> String {
        string(key, defaults: .standard)
    }

    static func string(_ key: String, defaults: UserDefaults) -> String {
        localizedBundle(localeIdentifier: preferredLocaleIdentifier(defaults: defaults))
            .localizedString(forKey: key, value: key, table: nil)
    }

    static func string(_ key: String, localeIdentifier: String) -> String {
        localizedBundle(localeIdentifier: localeIdentifier)
            .localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: string(key),
            locale: Locale(identifier: preferredLocaleIdentifier()),
            arguments: arguments
        )
    }

    static func format(
        _ key: String,
        localeIdentifier: String,
        arguments: [CVarArg]
    ) -> String {
        String(
            format: string(key, localeIdentifier: localeIdentifier),
            locale: Locale(identifier: localeIdentifier),
            arguments: arguments
        )
    }

    private static func localizedBundle(localeIdentifier: String? = nil) -> Bundle {
        let resources = CairnResources.bundle
        guard let localeIdentifier,
              let path = resources.path(
                forResource: localeIdentifier.lowercased(),
                ofType: "lproj"
              ),
              let bundle = Bundle(path: path) else {
            return resources
        }
        return bundle
    }

    static func preferredLocaleIdentifier(
        defaults: UserDefaults = .standard
    ) -> String {
        LanguageSettings.savedLanguage(in: defaults).localeIdentifier
    }

}
