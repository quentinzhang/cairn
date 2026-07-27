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

@Test
@MainActor
func languageSelectionPersistsAndCanReturnToTheSystem() throws {
    let suiteName = "app.cairn.tests.language.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = LanguageSettings(defaults: defaults)
    #expect(settings.selection == .system)
    #expect(L10n.preferredLocaleIdentifier(defaults: defaults) == nil)

    settings.select(.japanese)
    #expect(settings.selection == .japanese)
    #expect(defaults.string(forKey: LanguageSettings.preferenceKey) == "ja")
    #expect(LanguageSettings(defaults: defaults).selection == .japanese)
    #expect(L10n.preferredLocaleIdentifier(defaults: defaults) == "ja")
    #expect(L10n.string("language.menu", defaults: defaults) == "言語")

    settings.select(.system)
    #expect(settings.selection == .system)
    #expect(defaults.object(forKey: LanguageSettings.preferenceKey) == nil)
    #expect(L10n.preferredLocaleIdentifier(defaults: defaults) == nil)
}

@Test
@MainActor
func unsupportedSavedLanguageFallsBackToTheSystem() throws {
    let suiteName = "app.cairn.tests.language.invalid.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("ko", forKey: LanguageSettings.preferenceKey)

    #expect(LanguageSettings(defaults: defaults).selection == .system)
    #expect(L10n.preferredLocaleIdentifier(defaults: defaults) == nil)
}

@Test
func languageMenuUsesNativeNamesForExplicitChoices() {
    #expect(AppLanguage.english.displayName == "English")
    #expect(AppLanguage.simplifiedChinese.displayName == "简体中文")
    #expect(AppLanguage.japanese.displayName == "日本語")
}
