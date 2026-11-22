//
//  TranscriptLookupTests.swift
//  TranscriptionTests
//

import Foundation
import Testing
@testable import Transcription

@Suite struct TranscriptLookupTests {

	@Test func transcribingChecksICloudButRetranscribingDoesNot() {
		#expect(TranscriptLookup.checksICloudBeforeTranscribing(isRetranscribing: false, isSyncEnabled: true))
		// iCloud would have the old transcript, which re-transcribing replaces.
		#expect(!TranscriptLookup.checksICloudBeforeTranscribing(isRetranscribing: true, isSyncEnabled: true))
		#expect(!TranscriptLookup.checksICloudBeforeTranscribing(isRetranscribing: false, isSyncEnabled: false))
	}

	@Test func shownEpisodesAreLookedUpOnlyWithoutATranscript() {
		#expect(TranscriptLookup.looksUpWhenShown(hasLocalTranscript: false, isTranscribing: false, isSyncEnabled: true))
		#expect(!TranscriptLookup.looksUpWhenShown(hasLocalTranscript: true, isTranscribing: false, isSyncEnabled: true))
		#expect(!TranscriptLookup.looksUpWhenShown(hasLocalTranscript: false, isTranscribing: true, isSyncEnabled: true))
		#expect(!TranscriptLookup.looksUpWhenShown(hasLocalTranscript: false, isTranscribing: false, isSyncEnabled: false))
	}

	@Test func lookupsAreCoalesced() throws {
		var throttle = TranscriptLookupThrottle(missLifetime: 60)
		var started: Bool
		let key = try #require(EpisodeKey(enclosureURL: "https://example.com/a.mp3"))
		let otherKey = try #require(EpisodeKey(enclosureURL: "https://example.com/b.mp3"))

		started = throttle.begin(key)
		#expect(started)
		#expect(throttle.isInFlight(key))
		started = throttle.begin(key)
		#expect(!started)
		started = throttle.begin(otherKey)
		#expect(started)

		throttle.finish(key, found: true)
		#expect(!throttle.isInFlight(key))
		started = throttle.begin(key)
		#expect(started)
	}

	@Test func missesAreRememberedBriefly() throws {
		var throttle = TranscriptLookupThrottle(missLifetime: 60)
		var started: Bool
		let key = try #require(EpisodeKey(enclosureURL: "https://example.com/a.mp3"))
		let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

		started = throttle.begin(key, now: start)
		#expect(started)
		throttle.finish(key, found: false, now: start)
		started = throttle.begin(key, now: start.addingTimeInterval(59))
		#expect(!started)
		started = throttle.begin(key, now: start.addingTimeInterval(60))
		#expect(started)

		throttle.finish(key, found: false, now: start)
		throttle.forget(key)
		started = throttle.begin(key, now: start)
		#expect(started)

		throttle.finish(key, found: true, now: start)
		throttle.recordMiss(key, now: start)
		started = throttle.begin(key, now: start.addingTimeInterval(1))
		#expect(!started)
	}
}

@Suite struct EpisodeTranscriptSharingTests {

	func record(_ articleID: String, audioURL: String = "https://example.com/shared.mp3") -> TranscriptRecord {
		TranscriptRecord(articleID: articleID, accountID: "account", feedID: "feed", audioURL: audioURL)
	}

	@Test func articlesForAnEpisodeShareOneFile() throws {
		let store = TranscriptStore(folderURL: temporaryFolderURL())
		defer {
			try? FileManager.default.removeItem(at: store.folderURL)
		}
		let first = record("first")
		let second = record("second", audioURL: "http://EXAMPLE.com/shared.mp3")
		let episodeKey = try #require(first.episodeKey)
		#expect(second.episodeKey == episodeKey)

		try store.save(sampleTranscript(), record: first)
		#expect(store.hasTranscript(forEpisodeKey: episodeKey))
		// Not stored again per article.
		#expect(!FileManager.default.fileExists(atPath: store.fileURL(forArticleID: first.articleID).path))

		#expect(!store.hasTranscript(forArticleID: second.articleID))
		#expect(store.addRecordForExistingEpisodeTranscript(second))
		#expect(store.transcript(forArticleID: second.articleID) == sampleTranscript())
		#expect(Set(store.records(forEpisodeKey: episodeKey).map(\.articleID)) == ["first", "second"])

		#expect(!store.addRecordForExistingEpisodeTranscript(record("other", audioURL: "https://example.com/other.mp3")))
	}

	@Test func episodeFileStaysWhileAnotherRecordSharesIt() throws {
		let store = TranscriptStore(folderURL: temporaryFolderURL())
		defer {
			try? FileManager.default.removeItem(at: store.folderURL)
		}
		let first = record("first")
		let second = record("second")
		let episodeKey = try #require(first.episodeKey)
		try store.save(sampleTranscript(), record: first)
		store.addRecordForExistingEpisodeTranscript(second)

		// Cleaning up one article leaves the other’s transcript.
		#expect(store.removeTranscript(forArticleID: first.articleID) == first)
		#expect(store.hasTranscript(forEpisodeKey: episodeKey))
		#expect(store.hasTranscript(forArticleID: second.articleID))

		store.removeTranscript(forArticleID: second.articleID)
		#expect(!store.hasTranscript(forEpisodeKey: episodeKey))
	}

	@Test func removableEpisodeKey() throws {
		let first = record("first")
		let second = record("second")
		let other = record("other", audioURL: "https://example.com/other.mp3")
		let unkeyable = record("unkeyable", audioURL: "not a url")

		#expect(TranscriptCleanup.removableEpisodeKey(afterRemoving: first, remainingRecords: [second, other]) == nil)
		#expect(TranscriptCleanup.removableEpisodeKey(afterRemoving: first, remainingRecords: [other]) == first.episodeKey)
		#expect(TranscriptCleanup.removableEpisodeKey(afterRemoving: first, remainingRecords: []) == first.episodeKey)
		#expect(TranscriptCleanup.removableEpisodeKey(afterRemoving: unkeyable, remainingRecords: []) == nil)
	}

	@Test func deletingAnEpisodeRemovesEveryRecord() throws {
		let store = TranscriptStore(folderURL: temporaryFolderURL())
		defer {
			try? FileManager.default.removeItem(at: store.folderURL)
		}
		let first = record("first")
		let second = record("second")
		let other = record("other", audioURL: "https://example.com/other.mp3")
		let episodeKey = try #require(first.episodeKey)
		try store.save(sampleTranscript(), record: first)
		store.addRecordForExistingEpisodeTranscript(second)
		try store.save(sampleTranscript(), record: other)

		#expect(Set(store.removeTranscripts(forEpisodeKey: episodeKey).map(\.articleID)) == ["first", "second"])
		#expect(!store.hasTranscript(forEpisodeKey: episodeKey))
		#expect(!store.hasTranscript(forArticleID: second.articleID))
		#expect(store.records == [other])
	}

	@Test func unreferencedEpisodeFilesAreRemoved() throws {
		let store = TranscriptStore(folderURL: temporaryFolderURL())
		defer {
			try? FileManager.default.removeItem(at: store.folderURL)
		}
		let indexed = record("indexed")
		try store.save(sampleTranscript(), record: indexed)
		let strayKey = try #require(EpisodeKey(enclosureURL: "https://example.com/stray.mp3"))
		try store.save(sampleTranscript(), forEpisodeKey: strayKey)

		#expect(store.removeUnindexedTranscripts() == 1)
		#expect(!store.hasTranscript(forEpisodeKey: strayKey))
		#expect(store.hasTranscript(forArticleID: indexed.articleID))
	}

	@Test func perArticleTranscriptsStillRead() throws {
		// Saved before episode keys: the article’s own file is used, and wins over an episode file.
		let store = TranscriptStore(folderURL: temporaryFolderURL())
		defer {
			try? FileManager.default.removeItem(at: store.folderURL)
		}
		let legacy = record("legacy")
		try store.save(sampleTranscript(), record: legacy)
		var olderTranscript = sampleTranscript()
		olderTranscript.segments.removeLast()
		try olderTranscript.jsonData().write(to: store.fileURL(forArticleID: legacy.articleID))

		#expect(store.transcript(forArticleID: legacy.articleID) == olderTranscript)

		// An audio URL that can’t be keyed is kept per article.
		let unkeyable = record("unkeyable", audioURL: "not a url")
		try store.save(sampleTranscript(), record: unkeyable)
		#expect(FileManager.default.fileExists(atPath: store.fileURL(forArticleID: unkeyable.articleID).path))
		#expect(store.transcript(forArticleID: unkeyable.articleID) == sampleTranscript())
	}
}
