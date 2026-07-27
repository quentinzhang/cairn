import Combine
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case japanese = "ja"

    var id: String { rawValue }

    var localeIdentifier: String? {
        self == .system ? nil : rawValue
    }

    var displayName: String {
        switch self {
        case .system:
            L10n.string("language.follow_system")
        case .english:
            "English"
        case .simplifiedChinese:
            "简体中文"
        case .japanese:
            "日本語"
        }
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
        guard selection != language else { return }

        if language == .system {
            defaults.removeObject(forKey: Self.preferenceKey)
        } else {
            defaults.set(language.rawValue, forKey: Self.preferenceKey)
        }
        selection = language
        NotificationCenter.default.post(name: .cairnLanguageDidChange, object: language)
    }

    nonisolated static func savedLanguage(in defaults: UserDefaults) -> AppLanguage {
        guard let rawValue = defaults.string(forKey: preferenceKey),
              let language = AppLanguage(rawValue: rawValue),
              language != .system else {
            return .system
        }
        return language
    }
}

extension Notification.Name {
    static let cairnLanguageDidChange = Notification.Name("app.cairn.languageDidChange")
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
        let localeIdentifier = preferredLocaleIdentifier()
        return String(
            format: string(key),
            locale: localeIdentifier.map(Locale.init(identifier:)) ?? Locale.current,
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
        let resources = packagedResourcesBundle ?? .module
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
    ) -> String? {
        LanguageSettings.savedLanguage(in: defaults).localeIdentifier
    }

    /// SwiftPM's generated `Bundle.module` accessor expects its resource bundle
    /// beside `Bundle.main`. A conventional macOS app keeps resources under
    /// `Contents/Resources`, so prefer that packaged location and fall back to
    /// SwiftPM's build/test location during development.
    private static var packagedResourcesBundle: Bundle? {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("Cairn_Cairn.bundle") else {
            return nil
        }
        return Bundle(url: url)
    }
}
