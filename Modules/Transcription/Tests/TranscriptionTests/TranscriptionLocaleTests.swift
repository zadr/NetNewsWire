//
//  TranscriptionLocaleTests.swift
//  TranscriptionTests
//

import Foundation
import Testing
@testable import Transcription

@Suite struct TranscriptionLocaleTests {

	private let unitedStatesEnglish = Locale(identifier: "en_US")

	@Test func feedLanguageComesBeforeDeviceLocale() {
		let candidates = TranscriptionLocale.candidates(feedLanguage: "de-DE", deviceLocale: unitedStatesEnglish)

		#expect(identifiers(candidates) == ["de-DE", "en-US"])
	}

	@Test func feedLanguagesAreWrittenManyWays() {
		for feedLanguage in ["fr-ca", "fr_CA", " FR-CA ", "fr-CA"] {
			let candidates = TranscriptionLocale.candidates(feedLanguage: feedLanguage, deviceLocale: unitedStatesEnglish)
			#expect(identifiers(candidates) == ["fr-CA", "en-US"], "\(feedLanguage)")
		}
	}

	@Test func languageWithoutRegionUsesDeviceRegionForSameLanguage() {
		let britishEnglish = Locale(identifier: "en_GB")

		#expect(identifiers(TranscriptionLocale.candidates(feedLanguage: "en", deviceLocale: britishEnglish)) == ["en-GB"])
		#expect(identifiers(TranscriptionLocale.candidates(feedLanguage: "es", deviceLocale: britishEnglish)) == ["es-ES", "en-GB"])
		#expect(identifiers(TranscriptionLocale.candidates(feedLanguage: "de", deviceLocale: britishEnglish)) == ["de-DE", "en-GB"])
		#expect(identifiers(TranscriptionLocale.candidates(feedLanguage: "zh-Hant", deviceLocale: britishEnglish)) == ["zh-Hant-TW", "en-GB"])
	}

	@Test func sameLanguageAsDeviceIsNotRepeated() {
		#expect(identifiers(TranscriptionLocale.candidates(feedLanguage: "en-US", deviceLocale: unitedStatesEnglish)) == ["en-US"])
	}

	@Test func missingOrUnrecognizedLanguageFallsBackToDevice() {
		for feedLanguage in [nil, "", "   ", "English", "zz-top", "12"] {
			#expect(identifiers(TranscriptionLocale.candidates(feedLanguage: feedLanguage, deviceLocale: unitedStatesEnglish)) == ["en-US"], "\(String(describing: feedLanguage))")
		}
	}

	@Test func firstSupportedSkipsUnsupportedLocales() async {
		let candidates = [Locale(identifier: "tlh"), unitedStatesEnglish]
		var asked = [String]()

		let locale = await TranscriptionLocale.firstSupported(candidates) { locale in
			asked.append(locale.identifier(.bcp47))
			return locale.language.languageCode == "en" ? Locale(identifier: "en_US") : nil
		}

		#expect(asked == ["tlh", "en-US"])
		#expect(locale?.identifier(.bcp47) == "en-US")
	}

	@Test func firstSupportedReturnsTheSupportedEquivalent() async {
		let locale = await TranscriptionLocale.firstSupported([Locale(identifier: "de")]) { _ in
			Locale(identifier: "de_DE")
		}

		#expect(locale?.identifier(.bcp47) == "de-DE")
	}

	@Test func nothingSupportedIsNil() async {
		let locale = await TranscriptionLocale.firstSupported([unitedStatesEnglish]) { _ in nil }

		#expect(locale == nil)
	}

	private func identifiers(_ locales: [Locale]) -> [String] {
		locales.map { $0.identifier(.bcp47) }
	}
}
