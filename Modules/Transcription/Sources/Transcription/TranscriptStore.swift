//
//  TranscriptStore.swift
//  Transcription
//

import Foundation
import CryptoKit
import Synchronization
import os

/// What a stored transcript belongs to, so it can be removed along with its article, feed, or account.
public struct TranscriptRecord: Codable, Hashable, Sendable {

	public let articleID: String
	public let accountID: String
	public let feedID: String
	public let audioURL: String

	public init(articleID: String, accountID: String, feedID: String, audioURL: String) {
		self.articleID = articleID
		self.accountID = accountID
		self.feedID = feedID
		self.audioURL = audioURL
	}
}

/// Transcripts on disk, plus an index of their records.
///
/// A transcript is kept once per episode (see `TranscriptStore+Episodes.swift`), and each article’s record
/// points at it through its audio URL. Transcripts saved before episode keys, and transcripts of audio URLs
/// that can’t be made into an episode key, are kept in one file per article.
public final class TranscriptStore: Sendable {

	public let folderURL: URL

	private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Transcription", category: "TranscriptStore")
	private static let indexFileName = "index.json"

	/// Records by article ID. Nil until read from disk.
	private let index = Mutex<[String: TranscriptRecord]?>(nil)

	public init(folderURL: URL) {
		self.folderURL = folderURL
	}

	public func transcript(forArticleID articleID: String) -> Transcript? {
		guard let fileURL = existingFileURL(forArticleID: articleID), let data = try? Data(contentsOf: fileURL) else {
			return nil
		}
		do {
			return try Self.decoder.decode(Transcript.self, from: data)
		} catch {
			Self.logger.error("TranscriptStore: couldn’t decode transcript at \(fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
			return nil
		}
	}

	public func hasTranscript(forArticleID articleID: String) -> Bool {
		existingFileURL(forArticleID: articleID) != nil
	}

	/// Saves the transcript for the record’s episode, replacing any other transcript of it, so every article for the episode shares it.
	public func save(_ transcript: Transcript, record: TranscriptRecord) throws {
		if let episodeKey = record.episodeKey {
			try save(transcript, forEpisodeKey: episodeKey)
			try? FileManager.default.removeItem(at: fileURL(forArticleID: record.articleID))
		} else {
			try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
			let data = try Self.encoder.encode(transcript)
			try data.write(to: fileURL(forArticleID: record.articleID), options: .atomic)
		}
		try updateIndex { $0[record.articleID] = record }
	}

	/// Adds the record when its episode already has a transcript here — another article’s — so the article shares it.
	/// Returns false when there’s no transcript to share.
	@discardableResult
	public func addRecordForExistingEpisodeTranscript(_ record: TranscriptRecord) -> Bool {
		guard let episodeKey = record.episodeKey, hasTranscript(forEpisodeKey: episodeKey) else {
			return false
		}
		do {
			try updateIndex { $0[record.articleID] = record }
			return true
		} catch {
			Self.logger.error("TranscriptStore: couldn’t save index: \(error.localizedDescription, privacy: .public)")
			return false
		}
	}

	/// Removes the article’s record, and its transcript unless another article’s record shares it.
	/// Returns the removed transcript’s record, if it had one.
	@discardableResult
	public func removeTranscript(forArticleID articleID: String) -> TranscriptRecord? {
		try? FileManager.default.removeItem(at: fileURL(forArticleID: articleID))
		var removedRecord: TranscriptRecord?
		var remainingRecords = [TranscriptRecord]()
		try? updateIndex { index in
			removedRecord = index.removeValue(forKey: articleID)
			remainingRecords = Array(index.values)
		}
		if let removedRecord, let episodeKey = TranscriptCleanup.removableEpisodeKey(afterRemoving: removedRecord, remainingRecords: remainingRecords) {
			removeTranscript(forEpisodeKey: episodeKey)
		}
		return removedRecord
	}

	/// Removes the episode’s transcript and every record that shares it. Returns the removed records.
	@discardableResult
	public func removeTranscripts(forEpisodeKey episodeKey: EpisodeKey) -> [TranscriptRecord] {
		var removedRecords = [TranscriptRecord]()
		try? updateIndex { index in
			removedRecords = index.values.filter { $0.episodeKey == episodeKey }
			for record in removedRecords {
				index[record.articleID] = nil
			}
		}
		for record in removedRecords {
			try? FileManager.default.removeItem(at: fileURL(forArticleID: record.articleID))
		}
		removeTranscript(forEpisodeKey: episodeKey)
		return removedRecords
	}

	/// Records whose transcript is the episode’s.
	public func records(forEpisodeKey episodeKey: EpisodeKey) -> [TranscriptRecord] {
		loadedIndex().values.filter { $0.episodeKey == episodeKey }
	}

	public var records: [TranscriptRecord] {
		Array(loadedIndex().values)
	}

	public func record(forArticleID articleID: String) -> TranscriptRecord? {
		loadedIndex()[articleID]
	}

	/// Removes transcript files that have no record — including episode transcripts no record shares — and records that have no file.
	/// Returns the number of files and records removed.
	@discardableResult
	public func removeUnindexedTranscripts() -> Int {
		let index = loadedIndex()
		let indexedFileNames = Set(index.keys.map(Self.fileName(forArticleID:)))
		var removedCount = 0

		let fileURLs = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? []
		for fileURL in fileURLs where fileURL.pathExtension == "json" && fileURL.lastPathComponent != Self.indexFileName {
			if !indexedFileNames.contains(fileURL.lastPathComponent) {
				try? FileManager.default.removeItem(at: fileURL)
				removedCount += 1
			}
		}

		let episodeFileNames = TranscriptCleanup.referencedEpisodeKeys(Array(index.values)).map { $0.rawValue + ".json" }
		let referencedEpisodeFileNames = Set(episodeFileNames)
		let episodeFileURLs = (try? FileManager.default.contentsOfDirectory(at: episodesFolderURL, includingPropertiesForKeys: nil)) ?? []
		for fileURL in episodeFileURLs where fileURL.pathExtension == "json" && !referencedEpisodeFileNames.contains(fileURL.lastPathComponent) {
			try? FileManager.default.removeItem(at: fileURL)
			removedCount += 1
		}

		let articleIDsWithoutFiles = index.keys.filter { !hasTranscript(forArticleID: $0) }
		if !articleIDsWithoutFiles.isEmpty {
			try? updateIndex { index in
				for articleID in articleIDsWithoutFiles {
					index[articleID] = nil
				}
			}
			removedCount += articleIDsWithoutFiles.count
		}

		return removedCount
	}

	/// Article IDs can be any string, including URLs, so file names are a hash of the ID.
	public func fileURL(forArticleID articleID: String) -> URL {
		folderURL.appendingPathComponent(Self.fileName(forArticleID: articleID), isDirectory: false)
	}

	static func fileName(forArticleID articleID: String) -> String {
		SHA256.hash(data: Data(articleID.utf8)).hexString + ".json"
	}

	/// The article’s own file, for transcripts saved before episode keys, else its episode’s file. Nil when neither exists.
	func existingFileURL(forArticleID articleID: String) -> URL? {
		let articleFileURL = fileURL(forArticleID: articleID)
		if FileManager.default.fileExists(atPath: articleFileURL.path) {
			return articleFileURL
		}
		guard let episodeKey = loadedIndex()[articleID]?.episodeKey else {
			return nil
		}
		let episodeFileURL = fileURL(forEpisodeKey: episodeKey)
		return FileManager.default.fileExists(atPath: episodeFileURL.path) ? episodeFileURL : nil
	}
}

private extension TranscriptStore {

	static let encoder: JSONEncoder = {
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		return encoder
	}()

	static let decoder: JSONDecoder = {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return decoder
	}()

	var indexFileURL: URL {
		folderURL.appendingPathComponent(Self.indexFileName, isDirectory: false)
	}

	func loadedIndex() -> [String: TranscriptRecord] {
		index.withLock { index in
			if index == nil {
				index = readIndex()
			}
			return index ?? [:]
		}
	}

	func readIndex() -> [String: TranscriptRecord] {
		guard let data = try? Data(contentsOf: indexFileURL) else {
			return [:]
		}
		do {
			let records = try Self.decoder.decode([TranscriptRecord].self, from: data)
			return Dictionary(records.map { ($0.articleID, $0) }) { _, last in last }
		} catch {
			Self.logger.error("TranscriptStore: couldn’t decode index: \(error.localizedDescription, privacy: .public)")
			return [:]
		}
	}

	func updateIndex(_ update: (inout [String: TranscriptRecord]) -> Void) throws {
		try index.withLock { index in
			var updatedIndex = index ?? readIndex()
			update(&updatedIndex)
			index = updatedIndex
			try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
			let data = try Self.encoder.encode(updatedIndex.values.sorted { $0.articleID < $1.articleID })
			try data.write(to: indexFileURL, options: .atomic)
		}
	}
}

extension Sequence where Element == UInt8 {

	var hexString: String {
		map { String(format: "%02x", $0) }.joined()
	}
}
