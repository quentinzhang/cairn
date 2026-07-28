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
func languageSelectionPersists() throws {
    let suiteName = "app.cairn.tests.language.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    // Nothing chosen yet: Cairn opens in whatever this Mac asked for.
    let settings = LanguageSettings(defaults: defaults)
    #expect(settings.selection == AppLanguage.matchingSystem())
    #expect(defaults.object(forKey: LanguageSettings.preferenceKey) == nil)

    settings.select(.japanese)
    #expect(settings.selection == .japanese)
    #expect(defaults.string(forKey: LanguageSettings.preferenceKey) == "ja")
    #expect(LanguageSettings(defaults: defaults).selection == .japanese)
    #expect(L10n.preferredLocaleIdentifier(defaults: defaults) == "ja")
    #expect(L10n.string("language.menu", defaults: defaults) == "言語")

    settings.select(.english)
    #expect(settings.selection == .english)
    #expect(L10n.preferredLocaleIdentifier(defaults: defaults) == "en")
}

/// Choosing the language Cairn already inherited has to stick, or changing the
/// Mac's language later would silently move the app too.
@Test
@MainActor
func choosingTheInheritedLanguageStillPersistsIt() throws {
    let suiteName = "app.cairn.tests.language.inherited.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = LanguageSettings(defaults: defaults)
    settings.select(settings.selection)
    #expect(
        defaults.string(forKey: LanguageSettings.preferenceKey)
            == settings.selection.rawValue
    )
}

@Test
@MainActor
func unsupportedSavedLanguageFallsBackToTheSystemMatch() throws {
    let suiteName = "app.cairn.tests.language.invalid.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("ko", forKey: LanguageSettings.preferenceKey)

    #expect(LanguageSettings(defaults: defaults).selection == AppLanguage.matchingSystem())
}

/// The menu has no "follow the system" entry, so the first launch has to land
/// on the right language by itself.
@Test
func theSystemLanguageResolvesToOneCairnSpeaks() {
    #expect(AppLanguage.matchingSystem(preferences: ["zh-Hans-CN"]) == .simplifiedChinese)
    #expect(AppLanguage.matchingSystem(preferences: ["ja-JP"]) == .japanese)
    #expect(AppLanguage.matchingSystem(preferences: ["en-GB"]) == .english)
    // A language Cairn does not speak still has to open in something.
    #expect(AppLanguage.allCases.contains(AppLanguage.matchingSystem(preferences: ["ko-KR"])))
    #expect(!AppLanguage.allCases.map(\.rawValue).contains("system"))
}

@Test
func languageMenuUsesNativeNamesForExplicitChoices() {
    #expect(AppLanguage.english.displayName == "English")
    #expect(AppLanguage.simplifiedChinese.displayName == "简体中文")
    #expect(AppLanguage.japanese.displayName == "日本語")
}
