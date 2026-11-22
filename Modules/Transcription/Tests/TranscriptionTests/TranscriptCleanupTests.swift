//
//  TranscriptCleanupTests.swift
//  TranscriptionTests
//

import Foundation
import Testing
@testable import Transcription

@Suite struct TranscriptCleanupTests {

	@Test func recordsForRemovedAccountsAndFeedsAreOrphaned() {
		let kept = record("1", accountID: "local", feedID: "podcast")
		let removedFeed = record("2", accountID: "local", feedID: "gone")
		let removedAccount = record("3", accountID: "deleted", feedID: "podcast")
		let feedIDsByAccountID = ["local": Set(["podcast", "other"]), "empty": Set<String>()]

		let orphaned = TranscriptCleanup.recordsWithoutFeeds([kept, removedFeed, removedAccount], feedIDsByAccountID: feedIDsByAccountID)

		#expect(Set(orphaned) == [removedFeed, removedAccount])
	}

	@Test func recordsForRemovedArticlesAreOrphaned() {
		let kept = record("1", accountID: "a")
		let removedArticle = record("2", accountID: "a")
		let sameIDOtherAccount = record("1", accountID: "b")

		let orphaned = TranscriptCleanup.recordsWithoutArticles([kept, removedArticle, sameIDOtherAccount], existingArticleIDsByAccountID: ["a": ["1"]])

		#expect(Set(orphaned) == [removedArticle, sameIDOtherAccount])
	}

	@Test func articleIDsAreGroupedByAccount() {
		let records = [record("1", accountID: "a"), record("2", accountID: "a"), record("3", accountID: "b")]

		#expect(TranscriptCleanup.articleIDsByAccountID(records) == ["a": ["1", "2"], "b": ["3"]])
	}

	@Test func storeIndexTracksRecords() throws {
		let store = TranscriptStore(folderURL: temporaryFolderURL())
		defer {
			try? FileManager.default.removeItem(at: store.folderURL)
		}
		let first = record("https://example.com/1", accountID: "a", feedID: "f")
		let second = record("https://example.com/2", accountID: "b", feedID: "g")

		try store.save(sampleTranscript(), record: first)
		try store.save(sampleTranscript(), record: second)
		#expect(Set(store.records) == [first, second])

		// A new store reads the index from disk.
		let reopenedStore = TranscriptStore(folderURL: store.folderURL)
		#expect(Set(reopenedStore.records) == [first, second])
		#expect(reopenedStore.record(forArticleID: first.articleID) == first)

		#expect(reopenedStore.removeTranscript(forArticleID: first.articleID) == first)
		#expect(reopenedStore.records == [second])
		#expect(!reopenedStore.hasTranscript(forArticleID: first.articleID))
		#expect(reopenedStore.removeTranscript(forArticleID: first.articleID) == nil)
	}

	@Test func unindexedTranscriptsAreRemoved() throws {
		let store = TranscriptStore(folderURL: temporaryFolderURL())
		defer {
			try? FileManager.default.removeItem(at: store.folderURL)
		}
		let indexed = record("indexed")
		let missingFile = record("missing file")
		try store.save(sampleTranscript(), record: indexed)
		try store.save(sampleTranscript(), record: missingFile)
		try FileManager.default.removeItem(at: store.fileURL(forArticleID: missingFile.articleID))
		let strayFileURL = store.fileURL(forArticleID: "never indexed")
		try Data("{}".utf8).write(to: strayFileURL)

		#expect(store.removeUnindexedTranscripts() == 2)

		#expect(store.records == [indexed])
		#expect(store.hasTranscript(forArticleID: indexed.articleID))
		#expect(!FileManager.default.fileExists(atPath: strayFileURL.path))
		#expect(store.transcript(forArticleID: indexed.articleID) != nil)
	}

	@Test func staleCachedAudioIsRemoved() throws {
		let downloader = AudioDownloader(cacheFolderURL: temporaryFolderURL())
		defer {
			try? FileManager.default.removeItem(at: downloader.cacheFolderURL)
		}
		try FileManager.default.createDirectory(at: downloader.cacheFolderURL, withIntermediateDirectories: true)
		let now = Date()
		let oldDate = now.addingTimeInterval(-3 * 24 * 60 * 60)

		let staleURL = URL(string: "https://example.com/stale.mp3")!
		let staleInUseURL = URL(string: "https://example.com/in-use.mp3")!
		let recentURL = URL(string: "https://example.com/recent.mp3")!
		for url in [staleURL, staleInUseURL, recentURL] {
			let fileURL = downloader.cachedFileURL(for: url)
			try Data([1]).write(to: fileURL)
			let modificationDate = url == recentURL ? now : oldDate
			try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: fileURL.path)
		}

		let removedCount = downloader.removeCachedFiles(changedBefore: now.addingTimeInterval(-24 * 60 * 60), except: [staleInUseURL])

		#expect(removedCount == 1)
		#expect(!FileManager.default.fileExists(atPath: downloader.cachedFileURL(for: staleURL).path))
		#expect(FileManager.default.fileExists(atPath: downloader.cachedFileURL(for: staleInUseURL).path))
		#expect(FileManager.default.fileExists(atPath: downloader.cachedFileURL(for: recentURL).path))

		#expect(downloader.removeCachedFiles(changedBefore: .distantFuture) == 2)
	}
}
