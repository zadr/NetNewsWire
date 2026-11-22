//
//  SpeechTranscriptionEngine.swift
//  Transcription
//

import Foundation
import AVFoundation
import CoreMedia
import Speech

/// Runs `SpeechTranscriber` on an audio file, entirely on device.
@available(macOS 26, iOS 26, *)
enum SpeechTranscriptionEngine {

	struct Output: Sendable {
		let tokens: [TranscriptToken]
		let localeIdentifier: String
		let duration: TimeInterval?
	}

	private static let modelInstallationProgressInterval = Duration.milliseconds(500)
	private static let modelDownloadPollingInterval = Duration.seconds(1)

	/// Transcribes in the first of `locales` that `SpeechTranscriber` supports.
	static func transcribe(fileURL: URL, locales: [Locale], progressHandler: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> Output {
		guard SpeechTranscriber.isAvailable else {
			throw TranscriptionError.speechTranscriberUnavailable
		}
		let supportedLocale = await TranscriptionLocale.firstSupported(locales) { locale in
			await SpeechTranscriber.supportedLocale(equivalentTo: locale)
		}
		guard let supportedLocale else {
			throw TranscriptionError.unsupportedLocale(locales.first?.identifier ?? Locale.current.identifier)
		}

		let transcriber = SpeechTranscriber(locale: supportedLocale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
		try await installSpeechModelIfNeeded(for: transcriber, locale: supportedLocale, progressHandler: progressHandler)

		progressHandler(.transcribing(fractionCompleted: 0))

		let audioFile = try AVAudioFile(forReading: fileURL)
		let sampleRate = audioFile.processingFormat.sampleRate
		let duration: TimeInterval? = sampleRate > 0 && audioFile.length > 0 ? Double(audioFile.length) / sampleRate : nil

		let analyzer = SpeechAnalyzer(modules: [transcriber])
		async let tokens = collectTokens(from: transcriber, duration: duration, progressHandler: progressHandler)

		try await withTaskCancellationHandler {
			do {
				if let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) {
					try await analyzer.finalizeAndFinish(through: lastSampleTime)
				} else {
					await analyzer.cancelAndFinishNow()
				}
			} catch {
				// Ends the results sequence, so collecting tokens finishes too.
				await analyzer.cancelAndFinishNow()
				throw error
			}
		} onCancel: {
			Task {
				await analyzer.cancelAndFinishNow()
			}
		}

		let output = Output(tokens: try await tokens, localeIdentifier: supportedLocale.identifier, duration: duration)
		try Task.checkCancellation()
		return output
	}
}

@available(macOS 26, iOS 26, *)
private extension SpeechTranscriptionEngine {

	/// Installs the model for the transcriber’s locale, unless it’s already installed.
	///
	/// Installing reserves the locale for the app. Apps get a limited number of reservations,
	/// so when they’re all taken by other locales, one is released first.
	static func installSpeechModelIfNeeded(for transcriber: SpeechTranscriber, locale: Locale, progressHandler: @escaping @Sendable (TranscriptionProgress) -> Void) async throws {
		switch await AssetInventory.status(forModules: [transcriber]) {
		case .installed:
			return
		case .unsupported:
			throw TranscriptionError.unsupportedLocale(locale.identifier)
		case .supported, .downloading:
			break
		@unknown default:
			break
		}

		progressHandler(.installingSpeechModel(fractionCompleted: nil))
		await releaseReservationIfNeeded(for: locale)

		if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
			let progress = request.progress
			let reportingTask = Task {
				while !Task.isCancelled {
					progressHandler(.installingSpeechModel(fractionCompleted: progress.fractionCompleted))
					try? await Task.sleep(for: modelInstallationProgressInterval)
				}
			}
			defer {
				reportingTask.cancel()
			}
			try await request.downloadAndInstall()
		}

		// No request means the assets are installed, or already downloading (for another app, say), so wait for that.
		var status = await AssetInventory.status(forModules: [transcriber])
		while status == .downloading {
			try await Task.sleep(for: modelDownloadPollingInterval)
			status = await AssetInventory.status(forModules: [transcriber])
		}
		guard status == .installed else {
			throw TranscriptionError.speechModelUnavailable(locale.identifier)
		}
	}

	static func releaseReservationIfNeeded(for locale: Locale) async {
		let reservedLocales = await AssetInventory.reservedLocales
		let identifier = locale.identifier(.bcp47)
		guard !reservedLocales.contains(where: { $0.identifier(.bcp47) == identifier }), reservedLocales.count >= AssetInventory.maximumReservedLocales else {
			return
		}
		// This app reserves locales only for transcription, and only needs one at a time.
		if let reservedLocale = reservedLocales.first {
			await AssetInventory.release(reservedLocale: reservedLocale)
		}
	}

	static func collectTokens(from transcriber: SpeechTranscriber, duration: TimeInterval?, progressHandler: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> [TranscriptToken] {
		var tokens = [TranscriptToken]()
		for try await result in transcriber.results {
			guard result.isFinal else {
				continue
			}

			var resultTokens = Self.tokens(from: result.text)
			// Results don’t always start with a space, so make sure the last result’s last word and this one’s first word don’t run together.
			if let first = resultTokens.first, let previous = tokens.last, previous.text.last?.isWhitespace == false, first.text.first?.isWhitespace == false {
				resultTokens[0] = TranscriptToken(text: " " + first.text, startTime: first.startTime, endTime: first.endTime, confidence: first.confidence)
			}
			tokens += resultTokens

			if let duration, duration > 0 {
				let endTime = result.range.end.seconds
				if endTime.isFinite {
					progressHandler(.transcribing(fractionCompleted: min(1, endTime / duration)))
				}
			}
		}
		return tokens
	}

	static func tokens(from text: AttributedString) -> [TranscriptToken] {
		text.runs.map { run in
			let runText = String(text[run.range].characters)
			let confidence = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self]
			guard let timeRange = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self], timeRange.isValid else {
				return TranscriptToken(text: runText, startTime: nil, endTime: nil, confidence: confidence)
			}
			let startTime = timeRange.start.seconds
			let endTime = timeRange.end.seconds
			guard startTime.isFinite, endTime.isFinite else {
				return TranscriptToken(text: runText, startTime: nil, endTime: nil, confidence: confidence)
			}
			return TranscriptToken(text: runText, startTime: startTime, endTime: endTime, confidence: confidence)
		}
	}
}
