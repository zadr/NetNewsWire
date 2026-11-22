//
//  Transcriber.swift
//  Transcription
//

import Foundation
import Speech

/// Transcribes podcast audio on device with the Speech framework.
/// Callable on any OS version — it throws `unsupportedOperatingSystem` where `SpeechTranscriber` isn’t available.
public struct Transcriber: Sendable {

	public let audioDownloader: AudioDownloader

	public init(audioCacheFolderURL: URL) {
		self.audioDownloader = AudioDownloader(cacheFolderURL: audioCacheFolderURL)
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
		return Transcript(audioURL: audioURL ?? fileURL.absoluteString, localeIdentifier: output.localeIdentifier, duration: output.duration, segments: segments)
	}
}

private extension Transcriber {

	static var unsupportedError: TranscriptionError {
		if #available(macOS 26, iOS 26, *) {
			return .speechTranscriberUnavailable
		}
		return .unsupportedOperatingSystem
	}
}
