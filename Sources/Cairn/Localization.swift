import Foundation

/// One localization boundary for both SwiftUI and AppKit-created windows.
///
/// Cairn is a Swift package that is later assembled into a hand-built `.app`,
/// so its strings live in the package resource bundle rather than implicitly
/// in `Bundle.main`. Tests can also address one localization directly without
/// changing the Mac's preferred languages.
enum L10n {
    static let supportedLocales = ["en", "zh-Hans", "ja"]

    static func string(_ key: String) -> String {
        localizedBundle().localizedString(forKey: key, value: key, table: nil)
    }

    static func string(_ key: String, localeIdentifier: String) -> String {
        localizedBundle(localeIdentifier: localeIdentifier)
            .localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: string(key),
            locale: Locale.current,
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
