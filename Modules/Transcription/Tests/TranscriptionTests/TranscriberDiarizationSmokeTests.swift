//
//  TranscriberDiarizationSmokeTests.swift
//  TranscriptionTests
//

import Foundation
import Testing
@testable import Transcription

/// Runs the real Speech framework and the speaker diarization model, so it’s skipped unless
/// `TRANSCRIPTION_SMOKE_TEST_AUDIO` is the path to an English audio file with several speakers and
/// `SPEAKER_DIARIZATION_RESOURCES` is the path to a model build’s `NemotronDiarization` folder.
@Suite struct TranscriberDiarizationSmokeTests {

	private static let audioPath = ProcessInfo.processInfo.environment["TRANSCRIPTION_SMOKE_TEST_AUDIO"]
	private static let resourcesPath = ProcessInfo.processInfo.environment["SPEAKER_DIARIZATION_RESOURCES"]

	@Test(.enabled(if: audioPath != nil && resourcesPath != nil)) func transcribesWithSpeakers() async throws {
		let audioPath = try #require(Self.audioPath)
		let resourcesPath = try #require(Self.resourcesPath)

		let transcriber = Transcriber(audioCacheFolderURL: temporaryFolderURL(), speakerDiarizationResourcesURL: URL(filePath: resourcesPath, directoryHint: .isDirectory))
		let start = Date()
		let transcript = try await transcriber.transcribeFile(URL(filePath: audioPath), locales: [Locale(identifier: "en_US")]) { progress in
			print("Progress: \(progress)")
		}

		print("Transcribed with speakers in \(Date().timeIntervalSince(start)) seconds")
		for segment in transcript.segments {
			print("Segment \(segment.startTime)–\(segment.endTime) speaker \(segment.speaker ?? "-") \(segment.speakers ?? []): \(segment.text)")
		}
		let speakers = Set(transcript.segments.compactMap(\.speaker))
		#expect(speakers.count > 1)
		#expect(transcript.segments.allSatisfy { segment in segment.words.allSatisfy { $0.speaker == nil || $0.speaker == segment.speaker } })
	}
}
