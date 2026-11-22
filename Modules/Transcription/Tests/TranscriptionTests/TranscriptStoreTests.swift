//
//  TranscriptStoreTests.swift
//  TranscriptionTests
//

import Foundation
import Testing
@testable import Transcription

@Suite struct TranscriptStoreTests {

	@Test func savedTranscriptIsReadBack() throws {
		let store = TranscriptStore(folderURL: temporaryFolderURL())
		defer {
			try? FileManager.default.removeItem(at: store.folderURL)
		}
		let articleID = "https://example.com/episodes/1?id=2#3"
		let transcript = sampleTranscript()

		#expect(store.transcript(forArticleID: articleID) == nil)
		#expect(!store.hasTranscript(forArticleID: articleID))

		try store.save(transcript, record: record(articleID))

		#expect(store.hasTranscript(forArticleID: articleID))
		#expect(store.transcript(forArticleID: articleID) == transcript)
		#expect(store.transcript(forArticleID: "other") == nil)

		store.removeTranscript(forArticleID: articleID)
		#expect(!store.hasTranscript(forArticleID: articleID))
	}

	@Test func fileNamesAreSafeAndDistinct() {
		let first = TranscriptStore.fileName(forArticleID: "https://example.com/a/b")
		let second = TranscriptStore.fileName(forArticleID: "https://example.com/a/c")

		#expect(first != second)
		#expect(first.hasSuffix(".json"))
		#expect(!first.contains("/"))
		#expect(first.count == 64 + ".json".count)
	}

	@Test func corruptFileReadsAsNil() throws {
		let store = TranscriptStore(folderURL: temporaryFolderURL())
		defer {
			try? FileManager.default.removeItem(at: store.folderURL)
		}
		try FileManager.default.createDirectory(at: store.folderURL, withIntermediateDirectories: true)
		try Data("not json".utf8).write(to: store.fileURL(forArticleID: "a"))

		#expect(store.transcript(forArticleID: "a") == nil)
	}

	@Test func transcriptWithoutSpeakersDecodes() throws {
		// Speaker labels are optional, so transcripts saved before speakers existed still decode.
		let json = """
		{"version":1,"audioURL":"https://example.com/a.mp3","localeIdentifier":"en_US","dateCreated":"2026-11-22T12:00:00Z","duration":3,
		"segments":[{"text":"Hi.","startTime":0,"endTime":1,"words":[{"text":"Hi.","startTime":0,"endTime":1}]}]}
		"""
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		let transcript = try decoder.decode(Transcript.self, from: Data(json.utf8))

		#expect(transcript.segments[0].speaker == nil)
		#expect(transcript.segments[0].words[0].speaker == nil)
		#expect(transcript.segments[0].words[0].confidence == nil)
		#expect(transcript.text == "Hi.")
	}

	@Test func speakersRoundTrip() throws {
		let store = TranscriptStore(folderURL: temporaryFolderURL())
		defer {
			try? FileManager.default.removeItem(at: store.folderURL)
		}
		var transcript = sampleTranscript()
		transcript.segments[0].speaker = "Speaker 1"
		transcript.segments[0].words[0].speaker = "Speaker 1"

		try store.save(transcript, record: record("a"))

		let readTranscript = try #require(store.transcript(forArticleID: "a"))
		#expect(readTranscript.segments[0].speaker == "Speaker 1")
		#expect(readTranscript.segments[0].words[0].speaker == "Speaker 1")
	}
}

@Suite struct TranscriptionProgressTests {

	@Test func percentCompleted() {
		#expect(TranscriptionProgress.transcribing(fractionCompleted: 0.426).percentCompleted == 42)
		#expect(TranscriptionProgress.transcribing(fractionCompleted: 1.2).percentCompleted == 100)
		#expect(TranscriptionProgress.downloadingAudio(fractionCompleted: nil).percentCompleted == nil)
	}

	@Test func overallFractionGoesThroughEachStep() {
		let expectations: [(TranscriptionProgress, Double)] = [
			(.downloadingAudio(fractionCompleted: 0), 0),
			(.downloadingAudio(fractionCompleted: 1), 0.3),
			(.installingSpeechModel(fractionCompleted: 0.5), 0.35),
			(.transcribing(fractionCompleted: 0.5), 0.7),
			(.transcribing(fractionCompleted: 2), 1)
		]
		for (progress, expectedFraction) in expectations {
			let fraction = try? #require(progress.overallFractionCompleted)
			#expect(abs((fraction ?? -1) - expectedFraction) < 0.0001, "\(progress)")
		}
		#expect(TranscriptionProgress.transcribing(fractionCompleted: nil).overallFractionCompleted == nil)
	}

	@Test func visibleEquality() {
		#expect(TranscriptionProgress.transcribing(fractionCompleted: 0.421).isVisiblyEqual(to: .transcribing(fractionCompleted: 0.428)))
		#expect(!TranscriptionProgress.transcribing(fractionCompleted: 0.42).isVisiblyEqual(to: .transcribing(fractionCompleted: 0.43)))
		#expect(!TranscriptionProgress.transcribing(fractionCompleted: 0.42).isVisiblyEqual(to: .downloadingAudio(fractionCompleted: 0.42)))
	}
}

@Suite struct AudioDownloaderTests {

	@Test func cachedFileKeepsExtension() {
		let downloader = AudioDownloader(cacheFolderURL: temporaryFolderURL())
		let fileURL = downloader.cachedFileURL(for: URL(string: "https://example.com/episodes/42.MP3?token=abc")!)

		#expect(fileURL.pathExtension == "mp3")
		#expect(fileURL.deletingLastPathComponent() == downloader.cacheFolderURL)
	}

	@Test func cachedFileIgnoresUnlikelyExtension() {
		let downloader = AudioDownloader(cacheFolderURL: temporaryFolderURL())
		let fileURL = downloader.cachedFileURL(for: URL(string: "https://example.com/episode.notanextension")!)

		#expect(fileURL.pathExtension.isEmpty)
	}

	@Test func cachedFileIsUsedWithoutDownloading() async throws {
		let downloader = AudioDownloader(cacheFolderURL: temporaryFolderURL())
		defer {
			try? FileManager.default.removeItem(at: downloader.cacheFolderURL)
		}
		// Nothing’s listening here, so this only passes if the cached file is used.
		let url = URL(string: "http://127.0.0.1:9/episode.m4a")!
		let cachedFileURL = downloader.cachedFileURL(for: url)
		try FileManager.default.createDirectory(at: downloader.cacheFolderURL, withIntermediateDirectories: true)
		try Data([1, 2, 3]).write(to: cachedFileURL)

		let fileURL = try await downloader.download(url) { _ in }

		#expect(fileURL == cachedFileURL)
		downloader.removeCachedFile(for: url)
		#expect(!FileManager.default.fileExists(atPath: cachedFileURL.path))
	}
}

func record(_ articleID: String, accountID: String = "account", feedID: String = "feed") -> TranscriptRecord {
	TranscriptRecord(articleID: articleID, accountID: accountID, feedID: feedID, audioURL: "https://example.com/\(articleID).mp3")
}

func temporaryFolderURL() -> URL {
	FileManager.default.temporaryDirectory.appendingPathComponent("TranscriptionTests-\(UUID().uuidString)", isDirectory: true)
}

func sampleTranscript() -> Transcript {
	let words = [
		TranscriptWord(text: "Hello", startTime: 0.25, endTime: 0.5, confidence: 0.8),
		TranscriptWord(text: "there.", startTime: 0.5, endTime: 1)
	]
	let segments = [
		TranscriptSegment(text: "Hello there.", startTime: 0.25, endTime: 1, words: words),
		TranscriptSegment(text: "Bye.", startTime: 4, endTime: 4.5, words: [TranscriptWord(text: "Bye.", startTime: 4, endTime: 4.5)])
	]
	return Transcript(audioURL: "https://example.com/a.mp3", localeIdentifier: "en_US", dateCreated: Date(timeIntervalSince1970: 1_800_000_000), duration: 5, segments: segments)
}
