//
//  Transcriber.swift
//  Transcription
//

import Foundation
import os
import Speech
import RSCore
import SpeakerDiarization

/// Transcribes podcast audio on device with the Speech framework.
/// Callable on any OS version — it throws `unsupportedOperatingSystem` where `SpeechTranscriber` isn’t available.
public struct Transcriber: Sendable {

	public let audioDownloader: AudioDownloader
	/// The speaker diarization model’s folder. When nil, or when diarization fails, transcripts have no speakers.
	public let speakerDiarizationResourcesURL: URL?

	public init(audioCacheFolderURL: URL, speakerDiarizationResourcesURL: URL? = SpeakerDiarizer.bundledResourcesURL()) {
		self.audioDownloader = AudioDownloader(cacheFolderURL: audioCacheFolderURL)
		self.speakerDiarizationResourcesURL = speakerDiarizationResourcesURL
	}

	/// True when this OS and device can transcribe. Says nothing about whether a given language is supported.
	public static var isSupported: Bool {
		if #available(macOS 26, iOS 26, *) {
			return SpeechTranscriber.isAvailable
		}
		return false
	}

	/// Downloads the audio, transcribes it in the first of `locales` that’s supported, then deletes the downloaded audio.
	/// If transcription fails, the audio stays in the cache, so trying again doesn’t download it again.
	/// See `TranscriptionLocale.candidates` for choosing `locales`.
	@concurrent public func transcribe(audioURL: URL, locales: [Locale], progressHandler: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> Transcript {
		guard Self.isSupported else {
			throw Self.unsupportedError
		}

		progressHandler(.downloadingAudio(fractionCompleted: nil))
		let fileURL = try await audioDownloader.download(audioURL) { fractionCompleted in
			progressHandler(.downloadingAudio(fractionCompleted: fractionCompleted))
		}
		try Task.checkCancellation()

		let transcript = try await transcribeFile(fileURL, audioURL: audioURL.absoluteString, locales: locales, progressHandler: progressHandler)
		audioDownloader.removeCachedFile(for: audioURL)
		return transcript
	}

	/// Transcribes a local audio file. `audioURL` is recorded in the transcript; it defaults to the file’s URL.
	@concurrent public func transcribeFile(_ fileURL: URL, audioURL: String? = nil, locales: [Locale], progressHandler: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> Transcript {
		guard #available(macOS 26, iOS 26, *) else {
			throw TranscriptionError.unsupportedOperatingSystem
		}

		let output = try await SpeechTranscriptionEngine.transcribe(fileURL: fileURL, locales: locales, progressHandler: progressHandler)
		let segments = TranscriptSegmentBuilder.segments(from: output.tokens)
		guard !segments.isEmpty else {
			throw TranscriptionError.noSpeechFound
		}
		let transcript = Transcript(audioURL: audioURL ?? fileURL.absoluteString, localeIdentifier: output.localeIdentifier, duration: output.duration, segments: segments)
		guard let speakerDiarizationResourcesURL else {
			return transcript
		}
		progressHandler(.identifyingSpeakers)
		return try await Self.addingSpeakers(to: transcript, fileURL: fileURL, resourcesURL: speakerDiarizationResourcesURL)
	}
}

private extension Transcriber {

	static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "Transcriber")

	/// Transcripts are useful without speakers, so a diarization failure leaves the transcript as it is.
	static func addingSpeakers(to transcript: Transcript, fileURL: URL, resourcesURL: URL) async throws -> Transcript {
		do {
			let diarizer = try SpeakerDiarizer(resourcesURL: resourcesURL)
			let activity = try await diarizer.diarize(fileURL: fileURL)
			return TranscriptSpeakerAssigner.assigningSpeakers(to: transcript, from: activity)
		} catch is CancellationError {
			throw CancellationError()
		} catch {
			logger.error("Transcriber: speaker diarization failed: \(String(describing: error), privacy: .public)")
			return transcript
		}
	}

	static var unsupportedError: TranscriptionError {
		if #available(macOS 26, iOS 26, *) {
			return .speechTranscriberUnavailable
		}
		return .unsupportedOperatingSystem
	}
}
