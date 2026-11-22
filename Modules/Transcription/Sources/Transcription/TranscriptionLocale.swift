//
//  TranscriptionLocale.swift
//  Transcription
//

import Foundation

/// Chooses the locale to transcribe in: the feed’s declared language when the transcriber supports it, else the device’s.
public enum TranscriptionLocale {

	/// Locales to try, best first.
	///
	/// The feed’s language comes first. When it has no region and the device uses the same language,
	/// the device’s locale stands in for it, so an “en” feed on an en-GB device uses en-GB.
	/// Otherwise a missing region is the language’s likeliest one, so a “de” feed uses de-DE.
	/// The device’s locale is always last, as the fallback.
	/// A language that isn’t an ISO language code, such as “English”, is ignored.
	public static func candidates(feedLanguage: String?, deviceLocale: Locale) -> [Locale] {
		var candidates = [Locale]()
		if let feedLanguage = language(from: feedLanguage), let languageCode = feedLanguage.languageCode {
			if feedLanguage.script == nil, feedLanguage.region == nil, deviceLocale.language.languageCode == languageCode {
				candidates.append(deviceLocale)
			} else {
				// Without a region, the transcriber picks an arbitrary one (“de” can become de-AT), so use the language’s likeliest region.
				let region = feedLanguage.region ?? likeliestRegion(languageCode: languageCode, script: feedLanguage.script)
				candidates.append(Locale(languageCode: languageCode, script: feedLanguage.script, languageRegion: region))
			}
		}
		candidates.append(deviceLocale)

		var identifiers = Set<String>()
		return candidates.filter { identifiers.insert($0.identifier(.bcp47)).inserted }
	}

	/// The first candidate that `supportedLocale` returns a locale for, as that locale. Nil when none are supported.
	public static func firstSupported(_ candidates: [Locale], supportedLocale: (Locale) async -> Locale?) async -> Locale? {
		for candidate in candidates {
			if let locale = await supportedLocale(candidate) {
				return locale
			}
		}
		return nil
	}
}

extension TranscriptionLocale {

	/// Feeds write languages as in “en-us”, “en_US”, or “EN”.
	/// Components, rather than `Locale.Language`, since they have only the script and region the feed gives.
	static func language(from string: String?) -> Locale.Language.Components? {
		guard let string = string?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else {
			return nil
		}
		let language = Locale.Language.Components(identifier: string.replacingOccurrences(of: "_", with: "-"))
		guard let languageCode = language.languageCode, languageCode.isISOLanguage else {
			return nil
		}
		return language
	}

	static func likeliestRegion(languageCode: Locale.LanguageCode, script: Locale.Script?) -> Locale.Region? {
		let language = Locale.Language(languageCode: languageCode, script: script)
		return Locale.Language(identifier: language.maximalIdentifier).region
	}
}
