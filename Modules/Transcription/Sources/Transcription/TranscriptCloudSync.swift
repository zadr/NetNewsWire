//
//  TranscriptCloudSync.swift
//  Transcription
//

import Foundation
import CloudKit
import os

/// Syncs episode transcripts through a custom zone in the user’s CloudKit private database,
/// so a user’s devices don’t transcribe the same episode twice.
///
/// Transcripts are downloaded lazily: `fetchTranscript(for:)` looks up one episode when it’s needed.
/// Other devices’ changes arrive by fetching zone changes since a saved server change token —
/// call `fetchChanges()` on launch, on becoming active, and on a push for `subscriptionID` — but they
/// only update or remove episode transcripts already on this device.
/// Local changes are queued and sent when CloudKit is reachable; the most recently modified side wins.
///
/// Only the episode files in `TranscriptStore` are touched here — never its per-article records.
///
/// Turns itself off when iCloud isn’t available — see `init`.
public actor TranscriptCloudSync {

	public typealias ChangeHandler = @MainActor @Sendable (TranscriptCloudChanges) -> Void

	public static let zoneName = "Transcripts"
	public static let subscriptionID = "TranscriptsDatabaseSubscription"

	private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Transcription", category: "TranscriptCloudSync")
	private static let fetchRecordTimeout: TimeInterval = 20

	private let container: CKContainer
	private let database: CKDatabase
	private let zoneID: CKRecordZone.ID
	private let store: TranscriptStore
	private let stateFileURL: URL
	private let outgoingFolderURL: URL
	private let changeHandler: ChangeHandler

	private var state: SyncState
	private var preparationTask: Task<Preparation, Never>?
	private var isFetchingChanges = false
	private var needsFetchChanges = false
	private var isSendingChanges = false
	private var didLogUnavailable = false

	/// Nil when the app isn’t entitled to the container, such as in builds signed without iCloud.
	/// Other reasons sync can’t run — not signed in to iCloud, for instance — are found later, and turn it off silently.
	///
	/// `changeHandler` is called with other devices’ changes.
	public init?(containerIdentifier: String, store: TranscriptStore, stateFolderURL: URL, changeHandler: @escaping ChangeHandler) {
		guard CloudKitEntitlements.isEntitled(toContainer: containerIdentifier) else {
			Self.logger.info("TranscriptCloudSync: off — not entitled to \(containerIdentifier, privacy: .public)")
			return nil
		}

		self.container = CKContainer(identifier: containerIdentifier)
		self.database = container.privateCloudDatabase
		self.zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
		self.store = store
		self.stateFileURL = stateFolderURL.appendingPathComponent("CloudKitSyncState.json", isDirectory: false)
		self.outgoingFolderURL = stateFolderURL.appendingPathComponent("Outgoing", isDirectory: true)
		self.changeHandler = changeHandler
		self.state = SyncState.read(from: stateFileURL)
	}

	/// True for a push from this sync’s database subscription.
	public nonisolated static func isTranscriptNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
		CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID == subscriptionID
	}

	/// Fetches other devices’ changes, then sends this device’s pending changes.
	public func sync() async {
		await fetchChanges()
		await sendPendingChanges()
	}

	/// Call when the iCloud account changes (`CKAccountChanged`), so availability is checked again.
	public func accountDidChange() async {
		preparationTask = nil
		didLogUnavailable = false
		await sync()
	}

	/// The episode’s transcript from CloudKit — or nil when CloudKit doesn’t have it, it was deleted
	/// (including by a deletion here that hasn’t been sent yet), or sync is off. Doesn’t save it.
	public func fetchTranscript(for episodeKey: EpisodeKey) async -> Transcript? {
		guard await prepare() else {
			return nil
		}

		do {
			guard let record = try await fetchRecord(episodeKey), let remote = TranscriptCloudRecord(record: record), !remote.isDeleted, remote.isReadable else {
				return nil
			}
			if let pendingChange = state.pendingChanges[episodeKey.rawValue], pendingChange.isDeletion,
			   TranscriptSyncResolution.resolve(local: pendingChange.syncVersion, remote: remote.syncVersion) != .takeRemote {
				return nil
			}
			return try TranscriptCloudRecord.transcript(from: record)
		} catch {
			Self.logger.error("TranscriptCloudSync: couldn’t fetch \(episodeKey.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
			return nil
		}
	}

	/// Call after saving a transcript locally, including when re-transcribing replaces one.
	public func transcriptWasSaved(_ transcript: Transcript, episodeKey: EpisodeKey) async {
		state.pendingChanges[episodeKey.rawValue] = PendingChange(isDeletion: false, modified: transcript.dateCreated, enclosureURL: transcript.audioURL)
		saveState()
		await sendPendingChanges()
	}

	/// Call after deleting a transcript locally, so other devices delete theirs.
	public func transcriptWasDeleted(episodeKey: EpisodeKey, enclosureURL: String) async {
		state.pendingChanges[episodeKey.rawValue] = PendingChange(isDeletion: true, modified: Date(), enclosureURL: enclosureURL)
		saveState()
		await sendPendingChanges()
	}

	public func fetchChanges() async {
		guard await prepare() else {
			return
		}
		guard !isFetchingChanges else {
			needsFetchChanges = true
			return
		}
		isFetchingChanges = true
		defer {
			isFetchingChanges = false
		}

		repeat {
			needsFetchChanges = false
			do {
				let changes = try await fetchZoneChanges()
				if !changes.isEmpty {
					await changeHandler(changes)
				}
			} catch {
				handleError(error, operation: "fetch changes")
				return
			}
		} while needsFetchChanges
	}
}

// MARK: - Private

private extension TranscriptCloudSync {

	enum Preparation {
		case ready
		/// Not signed in to iCloud, or iCloud is restricted — until the account changes.
		case unavailable
		/// Couldn’t reach CloudKit; try again next time.
		case failed
	}

	/// Checks the account and sets up the zone and subscription, once.
	func prepare() async -> Bool {
		if let preparationTask {
			return await preparationTask.value == .ready
		}

		let task = Task {
			await makeReady()
		}
		preparationTask = task
		let preparation = await task.value
		if preparation == .failed {
			preparationTask = nil
		}
		return preparation == .ready
	}

	func makeReady() async -> Preparation {
		do {
			let accountStatus = try await container.accountStatus()
			guard accountStatus == .available else {
				logUnavailable("account status \(accountStatus.rawValue)")
				return .unavailable
			}

			let userRecordName = try await container.userRecordID().recordName
			if state.userRecordName != userRecordName {
				// A different iCloud account: start over with its zone. Pending changes go to the new account.
				state.userRecordName = userRecordName
				state.changeTokenData = nil
				state.isZoneCreated = false
				state.isSubscriptionSaved = false
				saveState()
			}

			if !state.isZoneCreated {
				_ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
				state.isZoneCreated = true
				saveState()
			}

			if !state.isSubscriptionSaved {
				await saveSubscription()
			}

			return .ready
		} catch let error as CKError where error.code == .notAuthenticated {
			logUnavailable("not authenticated")
			return .unavailable
		} catch {
			Self.logger.error("TranscriptCloudSync: couldn’t prepare: \(error.localizedDescription, privacy: .public)")
			return .failed
		}
	}

	func saveSubscription() async {
		let subscription = CKDatabaseSubscription(subscriptionID: Self.subscriptionID)
		let notificationInfo = CKSubscription.NotificationInfo()
		notificationInfo.shouldSendContentAvailable = true
		subscription.notificationInfo = notificationInfo

		do {
			_ = try await database.modifySubscriptions(saving: [subscription], deleting: [])
			state.isSubscriptionSaved = true
			saveState()
		} catch {
			// Not fatal: changes are still fetched on launch and on becoming active.
			Self.logger.error("TranscriptCloudSync: couldn’t save subscription: \(error.localizedDescription, privacy: .public)")
		}
	}

	func logUnavailable(_ reason: String) {
		guard !didLogUnavailable else {
			return
		}
		didLogUnavailable = true
		Self.logger.info("TranscriptCloudSync: off — iCloud unavailable (\(reason, privacy: .public))")
	}

	// MARK: Fetching

	typealias ZoneChanges = (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>], deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)

	/// Fetches every change since the saved change token.
	func fetchZoneChanges() async throws -> TranscriptCloudChanges {
		var cloudChanges = TranscriptCloudChanges()
		var moreComing = true

		while moreComing {
			let changes: ZoneChanges
			do {
				changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: state.changeToken, desiredKeys: TranscriptCloudRecord.metadataKeys)
			} catch let error as CKError where error.code == .changeTokenExpired {
				state.changeToken = nil
				saveState()
				continue
			}

			for result in changes.modificationResultsByID.values {
				guard let remote = (try? result.get()).flatMap({ TranscriptCloudRecord(record: $0.record) }) else {
					continue
				}
				if !remote.isDeleted && !store.hasTranscript(forEpisodeKey: remote.episodeKey) {
					cloudChanges.availableEpisodeKeys.append(remote.episodeKey)
				}
				// Throws if downloading a newer transcript fails, so the change token isn’t advanced past it.
				if try await applyRemoteChange(remote) {
					cloudChanges.changedEpisodeKeys.append(remote.episodeKey)
				}
			}

			for deletion in changes.deletions where deletion.recordType == TranscriptCloudRecord.recordType {
				if applyRemoteDeletion(deletion.recordID), let episodeKey = EpisodeKey(rawValue: deletion.recordID.recordName) {
					cloudChanges.changedEpisodeKeys.append(episodeKey)
				}
			}

			state.changeToken = changes.changeToken
			saveState()
			moreComing = changes.moreComing
		}

		return cloudChanges
	}

	/// Nil when there’s no record for the episode. With `desiredKeys`, only those fields are fetched.
	func fetchRecord(_ episodeKey: EpisodeKey, desiredKeys: [CKRecord.FieldKey]? = nil) async throws -> CKRecord? {
		let configuration = CKOperation.Configuration()
		configuration.timeoutIntervalForRequest = Self.fetchRecordTimeout
		let recordID = TranscriptCloudRecord.recordID(for: episodeKey, zoneID: zoneID)
		do {
			let results = try await database.configuredWith(configuration: configuration) { database in
				try await database.records(for: [recordID], desiredKeys: desiredKeys)
			}
			return try results[recordID]?.get()
		} catch let error as CKError where error.code == .unknownItem {
			return nil
		}
	}

	/// Replaces or removes the local episode transcript if the remote record is newer.
	/// Episodes without a local transcript are left alone — they’re looked up when shown.
	/// `fullRecord` is the record with its transcript, if already fetched.
	/// Returns true when the local transcript changed.
	func applyRemoteChange(_ remote: TranscriptCloudRecord, fullRecord: CKRecord? = nil) async throws -> Bool {
		let episodeKey = remote.episodeKey
		let pendingChange = state.pendingChanges[episodeKey.rawValue]

		switch TranscriptSyncResolution.resolve(local: localVersion(for: episodeKey), remote: remote.syncVersion) {
		case .takeRemote:
			guard store.hasTranscript(forEpisodeKey: episodeKey) else {
				// Only a deletion not yet sent, which the newer remote change overrides.
				clearPendingChange(pendingChange, for: episodeKey)
				return false
			}
			if remote.isDeleted {
				store.removeTranscript(forEpisodeKey: episodeKey)
				clearPendingChange(pendingChange, for: episodeKey)
				return true
			}
			guard remote.isReadable else {
				return false
			}
			let record = try await fullRecordIfNeeded(fullRecord, episodeKey: episodeKey)
			guard let record, let fullRemote = TranscriptCloudRecord(record: record), !fullRemote.isDeleted,
				  let transcript = try TranscriptCloudRecord.transcript(from: record) else {
				return false
			}
			// The local transcript may have been removed or replaced while downloading.
			guard store.hasTranscript(forEpisodeKey: episodeKey),
				  TranscriptSyncResolution.resolve(local: localVersion(for: episodeKey), remote: fullRemote.syncVersion) == .takeRemote else {
				return false
			}
			try store.save(transcript, forEpisodeKey: episodeKey)
			clearPendingChange(state.pendingChanges[episodeKey.rawValue], for: episodeKey)
			return true
		case .inSync:
			clearPendingChange(pendingChange, for: episodeKey)
			return false
		case .keepLocal:
			if pendingChange == nil, let transcript = store.transcript(forEpisodeKey: episodeKey) {
				state.pendingChanges[episodeKey.rawValue] = PendingChange(isDeletion: false, modified: transcript.dateCreated, enclosureURL: transcript.audioURL)
				saveState()
			}
			return false
		}
	}

	func fullRecordIfNeeded(_ fullRecord: CKRecord?, episodeKey: EpisodeKey) async throws -> CKRecord? {
		if let fullRecord {
			return fullRecord
		}
		return try await fetchRecord(episodeKey)
	}

	/// This app never deletes records — it saves tombstones — but if a record is deleted some other way,
	/// drop the local copy too, unless it has changes still to send.
	func applyRemoteDeletion(_ recordID: CKRecord.ID) -> Bool {
		guard let episodeKey = EpisodeKey(rawValue: recordID.recordName), state.pendingChanges[episodeKey.rawValue] == nil, store.hasTranscript(forEpisodeKey: episodeKey) else {
			return false
		}
		store.removeTranscript(forEpisodeKey: episodeKey)
		return true
	}

	func localVersion(for episodeKey: EpisodeKey) -> TranscriptSyncVersion? {
		if let pendingChange = state.pendingChanges[episodeKey.rawValue], pendingChange.isDeletion {
			return pendingChange.syncVersion
		}
		guard let transcript = store.transcript(forEpisodeKey: episodeKey) else {
			return nil
		}
		return TranscriptSyncVersion(modified: transcript.dateCreated, isDeleted: false)
	}

	// MARK: Sending

	func sendPendingChanges() async {
		guard !state.pendingChanges.isEmpty, await prepare(), !isSendingChanges else {
			return
		}
		isSendingChanges = true
		defer {
			isSendingChanges = false
		}

		for (rawEpisodeKey, pendingChange) in state.pendingChanges {
			guard let episodeKey = EpisodeKey(rawValue: rawEpisodeKey) else {
				state.pendingChanges[rawEpisodeKey] = nil
				saveState()
				continue
			}
			do {
				try await send(pendingChange, for: episodeKey)
			} catch {
				handleError(error, operation: "send \(rawEpisodeKey)")
				if !Self.isRecordSpecific(error) {
					// Offline, throttled, out of quota, and so on: keep the rest for next time.
					return
				}
			}
		}
	}

	func send(_ pendingChange: PendingChange, for episodeKey: EpisodeKey) async throws {
		let localRecord: TranscriptCloudRecord
		var transcriptFileURL: URL?
		if pendingChange.isDeletion {
			localRecord = .tombstone(episodeKey: episodeKey, enclosureURL: pendingChange.enclosureURL, modified: pendingChange.modified)
		} else {
			guard let transcript = store.transcript(forEpisodeKey: episodeKey) else {
				clearPendingChange(pendingChange, for: episodeKey)
				return
			}
			localRecord = TranscriptCloudRecord(transcript: transcript, episodeKey: episodeKey, engineVersion: Transcriber.engineVersion)
			// Upload a copy, so re-transcribing during the upload can’t change the file under CloudKit.
			try FileManager.default.createDirectory(at: outgoingFolderURL, withIntermediateDirectories: true)
			let fileURL = outgoingFolderURL.appendingPathComponent(episodeKey.rawValue + ".json", isDirectory: false)
			try transcript.jsonData().write(to: fileURL, options: .atomic)
			transcriptFileURL = fileURL
		}
		defer {
			if let transcriptFileURL {
				try? FileManager.default.removeItem(at: transcriptFileURL)
			}
		}

		let recordID = TranscriptCloudRecord.recordID(for: episodeKey, zoneID: zoneID)
		for _ in 0..<3 {
			// Without the transcript asset: saving a partial record changes only the fields that are set.
			let serverRecord = try await fetchRecord(episodeKey, desiredKeys: TranscriptCloudRecord.metadataKeys)
			let remote = serverRecord.flatMap(TranscriptCloudRecord.init(record:))

			switch TranscriptSyncResolution.resolve(local: localRecord.syncVersion, remote: remote?.syncVersion) {
			case .takeRemote:
				if let remote, try await applyRemoteChange(remote) {
					await changeHandler(TranscriptCloudChanges(changedEpisodeKeys: [episodeKey]))
				}
				clearPendingChange(pendingChange, for: episodeKey)
				return
			case .inSync:
				clearPendingChange(pendingChange, for: episodeKey)
				return
			case .keepLocal:
				let record = serverRecord ?? CKRecord(recordType: TranscriptCloudRecord.recordType, recordID: recordID)
				localRecord.apply(to: record, transcriptFileURL: transcriptFileURL)
				do {
					let results = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
					_ = try results.saveResults[recordID]?.get()
					clearPendingChange(pendingChange, for: episodeKey)
					return
				} catch let error as CKError where error.code == .serverRecordChanged {
					// Another device saved first. Fetch its record and compare again.
					continue
				}
			}
		}
	}

	/// Clears the pending change if it’s still the one that was handled — a newer one may have been queued during an await.
	func clearPendingChange(_ pendingChange: PendingChange?, for episodeKey: EpisodeKey) {
		guard let pendingChange, state.pendingChanges[episodeKey.rawValue] == pendingChange else {
			return
		}
		state.pendingChanges[episodeKey.rawValue] = nil
		saveState()
	}

	// MARK: Errors

	func handleError(_ error: Error, operation: String) {
		if let ckError = error as? CKError {
			switch ckError.code {
			case .zoneNotFound, .userDeletedZone:
				// Make the zone again next time. Other devices’ transcripts were in it, so fetch from the start.
				state.isZoneCreated = false
				state.changeToken = nil
				saveState()
				preparationTask = nil
			case .notAuthenticated:
				preparationTask = nil
			default:
				break
			}
		}
		Self.logger.error("TranscriptCloudSync: couldn’t \(operation, privacy: .public): \(error.localizedDescription, privacy: .public)")
	}

	static func isRecordSpecific(_ error: Error) -> Bool {
		guard let ckError = error as? CKError else {
			// Local file errors, for instance.
			return true
		}
		switch ckError.code {
		case .invalidArguments, .unknownItem, .serverRejectedRequest, .assetFileNotFound, .assetFileModified, .limitExceeded, .batchRequestFailed, .constraintViolation:
			return true
		default:
			return false
		}
	}

	func saveState() {
		state.write(to: stateFileURL)
	}
}

/// Other devices’ changes, from fetching changes.
public struct TranscriptCloudChanges: Sendable {

	/// Episodes whose transcripts on this device were replaced or removed.
	public var changedEpisodeKeys = [EpisodeKey]()
	/// Episodes with a new or updated transcript in iCloud that isn’t on this device — not downloaded.
	public var availableEpisodeKeys = [EpisodeKey]()

	public init(changedEpisodeKeys: [EpisodeKey] = [], availableEpisodeKeys: [EpisodeKey] = []) {
		self.changedEpisodeKeys = changedEpisodeKeys
		self.availableEpisodeKeys = availableEpisodeKeys
	}

	var isEmpty: Bool {
		changedEpisodeKeys.isEmpty && availableEpisodeKeys.isEmpty
	}
}

// MARK: - State

private struct PendingChange: Codable, Equatable {
	var isDeletion: Bool
	/// For a deletion, when it was deleted. Otherwise, the transcript’s creation date.
	var modified: Date
	var enclosureURL: String

	var syncVersion: TranscriptSyncVersion {
		TranscriptSyncVersion(modified: modified, isDeleted: isDeletion)
	}
}

/// Kept in a JSON file. Small: it holds only episode keys, not transcripts.
private struct SyncState: Codable {

	var userRecordName: String?
	var changeTokenData: Data?
	var isZoneCreated = false
	var isSubscriptionSaved = false
	/// Keyed by episode key.
	var pendingChanges = [String: PendingChange]()

	var changeToken: CKServerChangeToken? {
		get {
			guard let changeTokenData else {
				return nil
			}
			return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: changeTokenData)
		}
		set {
			changeTokenData = newValue.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
		}
	}

	static func read(from fileURL: URL) -> SyncState {
		guard let data = try? Data(contentsOf: fileURL), let state = try? JSONDecoder().decode(SyncState.self, from: data) else {
			return SyncState()
		}
		return state
	}

	func write(to fileURL: URL) {
		do {
			try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
			try JSONEncoder().encode(self).write(to: fileURL, options: .atomic)
		} catch {
			Logger(subsystem: Bundle.main.bundleIdentifier ?? "Transcription", category: "TranscriptCloudSync").error("TranscriptCloudSync: couldn’t save state: \(error.localizedDescription, privacy: .public)")
		}
	}
}

public extension Transcriber {

	/// Recorded with synced transcripts, so a later version can tell what made a transcript.
	static var engineVersion: String {
		let version = ProcessInfo.processInfo.operatingSystemVersion
		#if os(macOS)
		let system = "macOS"
		#else
		let system = "iOS"
		#endif
		return "SpeechTranscriber \(system) \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
	}
}
