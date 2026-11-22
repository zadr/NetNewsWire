//
//  TranscriptionProgress.swift
//  Transcription
//

import Foundation

public enum TranscriptionProgress: Equatable, Sendable {

	/// Fractions are from 0 to 1, or nil when not known.
	case downloadingAudio(fractionCompleted: Double?)
	case installingSpeechModel(fractionCompleted: Double?)
	case transcribing(fractionCompleted: Double?)

	public var fractionCompleted: Double? {
		switch self {
		case .downloadingAudio(let fractionCompleted), .installingSpeechModel(let fractionCompleted), .transcribing(let fractionCompleted):
			return fractionCompleted
		}
	}

	/// Progress through all the steps, from 0 to 1, for a single progress bar.
	/// Transcribing gets most of the bar, since it usually takes longest. Nil when the step’s progress isn’t known.
	public var overallFractionCompleted: Double? {
		guard let fractionCompleted else {
			return nil
		}
		let clampedFraction = min(max(fractionCompleted, 0), 1)
		switch self {
		case .downloadingAudio:
			return clampedFraction * 0.3
		case .installingSpeechModel:
			return 0.3 + clampedFraction * 0.1
		case .transcribing:
			return 0.4 + clampedFraction * 0.6
		}
	}

	/// Whole percent, for deciding whether progress changed enough to show.
	public var percentCompleted: Int? {
		guard let fractionCompleted else {
			return nil
		}
		return Int((min(max(fractionCompleted, 0), 1) * 100).rounded(.down))
	}

	/// Equal when the step and whole percent are the same.
	public func isVisiblyEqual(to other: TranscriptionProgress) -> Bool {
		switch (self, other) {
		case (.downloadingAudio, .downloadingAudio), (.installingSpeechModel, .installingSpeechModel), (.transcribing, .transcribing):
			return percentCompleted == other.percentCompleted
		default:
			return false
		}
	}
}

public enum TranscriptionError: LocalizedError, Equatable, Sendable {

	case unsupportedOperatingSystem
	case speechTranscriberUnavailable
	case unsupportedLocale(String)
	case speechModelUnavailable(String)
	case downloadFailed(statusCode: Int)
	case noSpeechFound

	public var errorDescription: String? {
		switch self {
		case .unsupportedOperatingSystem:
			return NSLocalizedString("Transcription requires macOS 26 or iOS 26 or later.", comment: "Transcription error")
		case .speechTranscriberUnavailable:
			return NSLocalizedString("Speech transcription isn’t available on this device.", comment: "Transcription error")
		case .unsupportedLocale(let localeIdentifier):
			let format = NSLocalizedString("Speech transcription doesn’t support the language “%@”.", comment: "Transcription error")
			return String(format: format, localeIdentifier)
		case .speechModelUnavailable(let localeIdentifier):
			let format = NSLocalizedString("The speech recognition model for “%@” couldn’t be installed.", comment: "Transcription error")
			return String(format: format, localeIdentifier)
		case .downloadFailed(let statusCode):
			let format = NSLocalizedString("The audio couldn’t be downloaded (HTTP status %ld).", comment: "Transcription error")
			return String(format: format, statusCode)
		case .noSpeechFound:
			return NSLocalizedString("No speech was found in the audio.", comment: "Transcription error")
		}
	}
}
