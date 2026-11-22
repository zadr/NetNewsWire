//
//  TranscriberSmokeTests.swift
//  TranscriptionTests
//

import Foundation
import Testing
@testable import Transcription

/// Runs the real Speech framework, so it’s skipped unless `TRANSCRIPTION_SMOKE_TEST_AUDIO` is the path to an audio file,
/// or `TRANSCRIPTION_SMOKE_TEST_URL` is the URL of one. `TRANSCRIPTION_SMOKE_TEST_LANGUAGE` is its language (default “en-us”).
/// May download the speech model for the locale.
@Suite struct TranscriberSmokeTests {

	private static let audioPath = ProcessInfo.processInfo.environment["TRANSCRIPTION_SMOKE_TEST_AUDIO"]
	private static let audioURLString = ProcessInfo.processInfo.environment["TRANSCRIPTION_SMOKE_TEST_URL"]
	/// The feed language to use, as in a feed. Defaults to English.
	private static let locales = TranscriptionLocale.candidates(feedLanguage: ProcessInfo.processInfo.environment["TRANSCRIPTION_SMOKE_TEST_LANGUAGE"] ?? "en-us", deviceLocale: .current)

	@Test(.enabled(if: audioURLString != nil)) func downloadsAndTranscribesAudio() async throws {
		let audioURL = try #require(URL(string: Self.audioURLString ?? ""))
		let transcriber = Transcriber(audioCacheFolderURL: temporaryFolderURL())
		defer {
			try? FileManager.default.removeItem(at: transcriber.audioDownloader.cacheFolderURL)
		}

		let transcript = try await transcriber.transcribe(audioURL: audioURL, locales: Self.locales) { progress in
			print("Progress: \(progress)")
		}

		for segment in transcript.segments {
			print("Segment \(segment.startTime)–\(segment.endTime): \(segment.text)")
		}
		#expect(transcript.audioURL == audioURL.absoluteString)
		#expect(!transcript.segments.isEmpty)
		#expect(!FileManager.default.fileExists(atPath: transcriber.audioDownloader.cachedFileURL(for: audioURL).path))
	}

	@Test(.enabled(if: audioPath != nil)) func transcribesAudioFile() async throws {
		let audioPath = try #require(Self.audioPath)
		print("SpeechTranscriber supported: \(Transcriber.isSupported)")

		let transcriber = Transcriber(audioCacheFolderURL: temporaryFolderURL())
		let start = Date()
		let transcript = try await transcriber.transcribeFile(URL(fileURLWithPath: audioPath), locales: Self.locales) { progress in
			print("Progress: \(progress)")
		}

		print("Transcribed in \(Date().timeIntervalSince(start)) seconds, locale \(transcript.localeIdentifier), duration \(transcript.duration ?? 0)")
		for segment in transcript.segments {
			print("Segment \(segment.startTime)–\(segment.endTime): \(segment.text)")
			print("  words: \(segment.words.prefix(5).map { "\($0.text)@\($0.startTime)" })")
		}

		#expect(!transcript.segments.isEmpty)
		#expect(transcript.segments.allSatisfy { !$0.words.isEmpty && $0.startTime <= $0.endTime })
	}
}
