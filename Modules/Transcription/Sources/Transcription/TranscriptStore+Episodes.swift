//
//  TranscriptStore+Episodes.swift
//  Transcription
//

import Foundation
import os

/// Transcripts keyed by episode rather than by article, so every article for an episode shares one file.
/// They’re kept in an Episodes subfolder. Articles’ records point at them — see `save(_:record:)`.
public extension TranscriptStore {

	var episodesFolderURL: URL {
		folderURL.appendingPathComponent("Episodes", isDirectory: true)
	}

	func transcript(forEpisodeKey episodeKey: EpisodeKey) -> Transcript? {
		let fileURL = fileURL(forEpisodeKey: episodeKey)
		guard let data = try? Data(contentsOf: fileURL) else {
			return nil
		}
		do {
			return try Transcript(jsonData: data)
		} catch {
			episodesLogger.error("TranscriptStore: couldn’t decode transcript at \(fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
			return nil
		}
	}

	func hasTranscript(forEpisodeKey episodeKey: EpisodeKey) -> Bool {
		FileManager.default.fileExists(atPath: fileURL(forEpisodeKey: episodeKey).path)
	}

	func save(_ transcript: Transcript, forEpisodeKey episodeKey: EpisodeKey) throws {
		try FileManager.default.createDirectory(at: episodesFolderURL, withIntermediateDirectories: true)
		try transcript.jsonData().write(to: fileURL(forEpisodeKey: episodeKey), options: .atomic)
	}

	func removeTranscript(forEpisodeKey episodeKey: EpisodeKey) {
		try? FileManager.default.removeItem(at: fileURL(forEpisodeKey: episodeKey))
	}

	func fileURL(forEpisodeKey episodeKey: EpisodeKey) -> URL {
		episodesFolderURL.appendingPathComponent(episodeKey.rawValue + ".json", isDirectory: false)
	}
}

public extension TranscriptRecord {

	/// The episode whose transcript the record’s article shares. Nil for audio URLs that can’t be keyed.
	var episodeKey: EpisodeKey? {
		EpisodeKey(enclosureURL: audioURL)
	}
}

public extension Transcript {

	/// The same JSON that `TranscriptStore` writes.
	func jsonData() throws -> Data {
		try transcriptJSONEncoder.encode(self)
	}

	init(jsonData: Data) throws {
		self = try transcriptJSONDecoder.decode(Transcript.self, from: jsonData)
	}
}

private let episodesLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Transcription", category: "TranscriptStore")

private let transcriptJSONEncoder: JSONEncoder = {
	let encoder = JSONEncoder()
	encoder.dateEncodingStrategy = .iso8601
	return encoder
}()

private let transcriptJSONDecoder: JSONDecoder = {
	let decoder = JSONDecoder()
	decoder.dateDecodingStrategy = .iso8601
	return decoder
}()
