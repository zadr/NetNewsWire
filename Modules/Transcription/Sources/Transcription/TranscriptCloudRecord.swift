//
//  TranscriptCloudRecord.swift
//  Transcription
//

import Foundation
import CloudKit

/// An episode’s transcript as stored in CloudKit: one record per episode, named by its episode key.
///
/// Deleting a transcript turns its record into a tombstone (no transcript asset, `deleted` set)
/// rather than deleting the record, so its modification date can be compared with other devices’ changes.
public struct TranscriptCloudRecord: Equatable, Sendable {

	public static let recordType = "EpisodeTranscript"

	enum Field {
		static let episodeKey = "episodeKey"
		static let enclosureURL = "enclosureURL"
		static let localeIdentifier = "localeIdentifier"
		static let formatVersion = "formatVersion"
		static let engineVersion = "engineVersion"
		static let modified = "modified"
		static let deleted = "deleted"
		static let transcript = "transcript"
	}

	public let episodeKey: EpisodeKey
	public var enclosureURL: String
	public var localeIdentifier: String?
	/// `Transcript.version` of the transcript JSON.
	public var formatVersion: Int
	/// What made the transcript — see `Transcriber.engineVersion`.
	public var engineVersion: String?
	public var modified: Date
	public var isDeleted: Bool

	public var syncVersion: TranscriptSyncVersion {
		TranscriptSyncVersion(modified: modified, isDeleted: isDeleted)
	}

	/// A transcript’s modification date is the date it was created: re-transcribing makes a new transcript.
	public init(transcript: Transcript, episodeKey: EpisodeKey, engineVersion: String?) {
		self.episodeKey = episodeKey
		self.enclosureURL = transcript.audioURL
		self.localeIdentifier = transcript.localeIdentifier
		self.formatVersion = transcript.version
		self.engineVersion = engineVersion
		self.modified = transcript.dateCreated
		self.isDeleted = false
	}

	public static func tombstone(episodeKey: EpisodeKey, enclosureURL: String, modified: Date) -> TranscriptCloudRecord {
		TranscriptCloudRecord(episodeKey: episodeKey, enclosureURL: enclosureURL, localeIdentifier: nil, formatVersion: Transcript.currentVersion, engineVersion: nil, modified: modified, isDeleted: true)
	}

	init(episodeKey: EpisodeKey, enclosureURL: String, localeIdentifier: String?, formatVersion: Int, engineVersion: String?, modified: Date, isDeleted: Bool) {
		self.episodeKey = episodeKey
		self.enclosureURL = enclosureURL
		self.localeIdentifier = localeIdentifier
		self.formatVersion = formatVersion
		self.engineVersion = engineVersion
		self.modified = modified
		self.isDeleted = isDeleted
	}

	/// Every field but the transcript, for fetching changes without downloading transcripts.
	public static let metadataKeys = [Field.episodeKey, Field.enclosureURL, Field.localeIdentifier, Field.formatVersion, Field.engineVersion, Field.modified, Field.deleted]

	/// Nil when the record isn’t a transcript record or is missing required fields.
	/// The record may have been fetched with only `metadataKeys`.
	public init?(record: CKRecord) {
		guard record.recordType == Self.recordType,
			  let episodeKey = EpisodeKey(rawValue: record.recordID.recordName),
			  let modified = record[Field.modified] as? Date else {
			return nil
		}
		let isDeleted = (record[Field.deleted] as? Int ?? 0) != 0
		self.episodeKey = episodeKey
		self.enclosureURL = record[Field.enclosureURL] as? String ?? ""
		self.localeIdentifier = record[Field.localeIdentifier] as? String
		self.formatVersion = record[Field.formatVersion] as? Int ?? Transcript.currentVersion
		self.engineVersion = record[Field.engineVersion] as? String
		self.modified = modified
		self.isDeleted = isDeleted
	}

	public static func recordID(for episodeKey: EpisodeKey, zoneID: CKRecordZone.ID) -> CKRecord.ID {
		CKRecord.ID(recordName: episodeKey.rawValue, zoneID: zoneID)
	}

	/// Sets the record’s fields, replacing what was there. `transcriptFileURL` is the transcript JSON to upload;
	/// it’s ignored for a tombstone, which has no transcript.
	public func apply(to record: CKRecord, transcriptFileURL: URL?) {
		record[Field.episodeKey] = episodeKey.rawValue
		record[Field.enclosureURL] = enclosureURL
		record[Field.localeIdentifier] = localeIdentifier
		record[Field.formatVersion] = formatVersion
		record[Field.engineVersion] = engineVersion
		record[Field.modified] = modified
		record[Field.deleted] = isDeleted ? 1 : 0
		if !isDeleted, let transcriptFileURL {
			record[Field.transcript] = CKAsset(fileURL: transcriptFileURL)
		} else {
			record[Field.transcript] = nil
		}
	}

	/// True when this app can read the record’s transcript JSON.
	public var isReadable: Bool {
		formatVersion <= Transcript.currentVersion
	}

	/// The record’s transcript, read from its downloaded asset. Nil for a tombstone.
	public static func transcript(from record: CKRecord) throws -> Transcript? {
		guard let asset = record[Field.transcript] as? CKAsset, let fileURL = asset.fileURL else {
			return nil
		}
		return try Transcript(jsonData: Data(contentsOf: fileURL))
	}
}

/// The state of an episode’s transcript on one side of a sync — local or CloudKit.
public struct TranscriptSyncVersion: Equatable, Sendable {

	public var modified: Date
	public var isDeleted: Bool

	public init(modified: Date, isDeleted: Bool) {
		self.modified = modified
		self.isDeleted = isDeleted
	}
}

public enum TranscriptSyncResolution: Equatable, Sendable {
	/// Local is newer: send it to CloudKit.
	case keepLocal
	/// CloudKit is newer: save its transcript locally, or delete the local one for a tombstone.
	case takeRemote
	/// Nothing to do.
	case inSync

	/// The most recently modified side wins. A deletion counts as a modification at the time of deletion,
	/// so a delete beats an older transcript and a newer transcript beats an older delete.
	///
	/// Dates within a second are treated as equal, since transcript JSON stores whole seconds.
	/// For equal dates, a deletion wins, so that a delete is never undone by a copy of the transcript it deleted.
	public static func resolve(local: TranscriptSyncVersion?, remote: TranscriptSyncVersion?) -> TranscriptSyncResolution {
		switch (local, remote) {
		case (nil, nil):
			return .inSync
		case (nil, let remote?):
			return remote.isDeleted ? .inSync : .takeRemote
		case (let local?, nil):
			return local.isDeleted ? .inSync : .keepLocal
		case (let local?, let remote?):
			if local.isDeleted && remote.isDeleted {
				return .inSync
			}
			let interval = local.modified.timeIntervalSince(remote.modified)
			if abs(interval) < 1 {
				if local.isDeleted == remote.isDeleted {
					return .inSync
				}
				return local.isDeleted ? .keepLocal : .takeRemote
			}
			return interval > 0 ? .keepLocal : .takeRemote
		}
	}
}
