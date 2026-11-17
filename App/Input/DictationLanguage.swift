import Foundation

enum DictationLanguage {
    // The current interface is Japanese. Device region, calendar preferences,
    // and the bundle's development localization do not choose speech language.
    static let recognitionLocale = Locale(identifier: "ja-JP")

    static func acceptsRecognizerLocale(_ locale: Locale) -> Bool {
        // Speech may fall back to keyboard dictation for an unsupported locale.
        // Keep that fallback from silently recognizing Japanese as English.
        locale.language.languageCode == recognitionLocale.language.languageCode
    }
}
