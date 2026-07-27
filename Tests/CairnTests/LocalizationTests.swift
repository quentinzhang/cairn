import Foundation
import Testing
@testable import Cairn

@Test
func everyLocalizationContainsTheSameKeys() throws {
    var referenceKeys: Set<String>?

    for locale in L10n.supportedLocales {
        let lprojURL = try #require(
            Bundle.module.url(
                forResource: locale.lowercased(),
                withExtension: "lproj"
            )
        )
        let stringsURL = lprojURL.appendingPathComponent("Localizable.strings")
        let data = try Data(contentsOf: stringsURL)
        let values = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: String]
        )
        #expect(!values.isEmpty)

        if let referenceKeys {
            #expect(Set(values.keys) == referenceKeys, "\(locale) has a different key set")
        } else {
            referenceKeys = Set(values.keys)
        }
    }
}

@Test
func everyLocalizationExplainsAppleEventsAccess() throws {
    for locale in L10n.supportedLocales {
        let lprojURL = try #require(
            Bundle.module.url(
                forResource: locale.lowercased(),
                withExtension: "lproj"
            )
        )
        let stringsURL = lprojURL.appendingPathComponent("InfoPlist.strings")
        let data = try Data(contentsOf: stringsURL)
        let values = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: String]
        )
        #expect(
            values["NSAppleEventsUsageDescription"]?.isEmpty == false,
            "\(locale) is missing the Apple Events usage description"
        )
    }
}

@Test
func productLanguagesResolveKnownInterfaceStrings() {
    #expect(
        L10n.string("update.check", localeIdentifier: "en")
            == "Check for Updates…"
    )
    #expect(
        L10n.string("update.check", localeIdentifier: "zh-Hans")
            == "检查更新…"
    )
    #expect(
        L10n.string("update.check", localeIdentifier: "ja")
            == "アップデートを確認…"
    )
}

@Test
func buildVersionUsesTheRequestedLocale() {
    let info = [
        "CFBundleShortVersionString": "0.6.3",
        "CFBundleVersion": "15",
    ]
    #expect(
        CairnBuildInfo.displayVersion(from: info, localeIdentifier: "en")
            == "Version 0.6.3 (15)"
    )
    #expect(
        CairnBuildInfo.displayVersion(from: info, localeIdentifier: "zh-Hans")
            == "版本 0.6.3（15）"
    )
    #expect(
        CairnBuildInfo.displayVersion(from: info, localeIdentifier: "ja")
            == "バージョン 0.6.3（15）"
    )
}
