import Foundation
import Testing
@testable import OhMyOpenClawInput

struct DictationLanguageTests {
    @Test func japaneseInterfaceSelectsJapaneseRecognition() {
        // Locale.current or an unlocalized bundle's English development region
        // must not select the recognition language of this Japanese interface.
        #expect(DictationLanguage.recognitionLocale.identifier == "ja-JP")
    }

    @Test(arguments: ["en", "en-US", "en_JP", "de-DE"])
    func rejectsRecognitionFallbackToAnotherLanguage(_ identifier: String) {
        // Speech can fall back to keyboard dictation when the requested
        // language is unsupported. Do not silently transcribe Japanese as it.
        #expect(!DictationLanguage.acceptsRecognizerLocale(Locale(identifier: identifier)))
    }

    @Test(arguments: ["ja", "ja-JP", "ja_JP", "ja_US"])
    func acceptsJapaneseRegardlessOfRegionOrIdentifierStyle(_ identifier: String) {
        #expect(DictationLanguage.acceptsRecognizerLocale(Locale(identifier: identifier)))
    }
}
