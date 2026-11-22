//
//  TranscriptSyncManager.swift
//  NetNewsWire
//

import Foundation
import CloudKit
import os
import RSCore
import Articles
import Transcription

/// Syncs transcripts through iCloud, by episode, so a user’s devices don’t transcribe the same episode twice.
///
/// Transcripts are downloaded only for episodes this device shows: when an article with audio and no transcript
/// is shown, its episode is looked up in iCloud. Other devices’ changes update or remove transcripts already here.
///
/// Sync is off, silently, when the app isn’t signed with the iCloud container entitlement
/// or iCloud isn’t available. Transcripts still work locally.
@MainActor final class TranscriptSyncManager {

	static let shared = TranscriptSyncManager()

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "TranscriptSyncManager")
	/// How long an episode that iCloud didn’t have isn’t looked up again — unless iCloud reports it.
	private static let lookupMissLifetime: TimeInterval = 10 * 60
	private static let maximumMissedLookups = 100

	private let cloudSync: TranscriptCloudSync?
	private var lookupThrottle = TranscriptLookupThrottle(missLifetime: lookupMissLifetime)
	/// Articles waiting on a lookup in flight, by episode.
	private var articlesAwaitingLookup = [EpisodeKey: [Article]]()
	/// Articles whose lookups recently missed, so they can be looked up again if iCloud reports their episode.
	private var articlesWithMissedLookups = [EpisodeKey: [Article]]()

	var isSyncEnabled: Bool {
		cloudSync != nil
	}

	private init() {
		// Set in Info.plist from build settings. Empty or missing turns sync off.
		guard let containerIdentifier = Bundle.main.object(forInfoDictionaryKey: "TranscriptsCloudKitContainer") as? String, !containerIdentifier.isEmpty else {
			Self.logger.info("TranscriptSyncManager: iCloud sync off — no container in Info.plist")
			cloudSync = nil
			return
		}
		cloudSync = TranscriptCloudSync(containerIdentifier: containerIdentifier, store: TranscriptionManager.shared.store, stateFolderURL: AppConfig.dataSubfolder(named: "TranscriptSync")) { changes in
			TranscriptSyncManager.shared.cloudDidChange(changes)
		}
	}

	/// Call once at launch.
	func start() {
		guard cloudSync != nil else {
			return
		}
		NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive(_:)), name: .appDidBecomeActive, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(accountDidChange(_:)), name: .CKAccountChanged, object: nil)
		sync()
	}

	/// Handles a push from the transcripts database subscription. Returns false for other pushes.
	@discardableResult
	func receiveRemoteNotification(userInfo: [AnyHashable: Any]) async -> Bool {
		guard let cloudSync, TranscriptCloudSync.isTranscriptNotification(userInfo) else {
			return false
		}
		await cloudSync.fetchChanges()
		return true
	}

	// MARK: - Looking Up

	/// The episode’s transcript from iCloud, without saving it — or nil when there isn’t one or sync is off.
	/// For checking before downloading audio to transcribe.
	func transcriptFromICloud(episodeKey: EpisodeKey) async -> Transcript? {
		guard let cloudSync else {
			return nil
		}
		let transcript = await cloudSync.fetchTranscript(for: episodeKey)
		if transcript == nil {
			lookupThrottle.recordMiss(episodeKey)
		}
		return transcript
	}

	/// Looks up a shown article’s episode in iCloud, unless a lookup is in flight or recently missed.
	/// A transcript found is given to `TranscriptionManager`, which saves and shows it.
	func lookUpTranscript(for article: Article, episodeKey: EpisodeKey) {
		guard let cloudSync else {
			return
		}
		if lookupThrottle.isInFlight(episodeKey) {
			addArticle(article, to: &articlesAwaitingLookup, episodeKey: episodeKey)
			return
		}
		guard lookupThrottle.begin(episodeKey) else {
			return
		}
		articlesAwaitingLookup[episodeKey] = [article]

		Task {
			let transcript = await cloudSync.fetchTranscript(for: episodeKey)
			lookupThrottle.finish(episodeKey, found: transcript != nil)
			let articles = articlesAwaitingLookup.removeValue(forKey: episodeKey) ?? []
			guard let transcript else {
				rememberMissedLookup(articles, episodeKey: episodeKey)
				return
			}
			articlesWithMissedLookups[episodeKey] = nil
			TranscriptionManager.shared.transcriptWasFoundInICloud(transcript, articles: articles)
		}
	}

	// MARK: - Local Changes

	/// Sends a new transcript — including one replacing an older transcript — to iCloud.
	func transcriptWasSaved(_ transcript: Transcript, episodeKey: EpisodeKey) {
		guard let cloudSync else {
			return
		}
		Task {
			await cloudSync.transcriptWasSaved(transcript, episodeKey: episodeKey)
		}
	}

	/// Deletes the episode’s transcript from iCloud, so the user’s other devices delete theirs.
	/// Only for the user deleting a transcript — not for cleaning up after articles, feeds, and accounts.
	func transcriptWasDeleted(episodeKey: EpisodeKey, enclosureURL: String) {
		guard let cloudSync else {
			return
		}
		// iCloud has the transcript until the deletion is sent, so don’t look it up again in the meantime.
		lookupThrottle.recordMiss(episodeKey)
		articlesWithMissedLookups[episodeKey] = nil
		Task {
			await cloudSync.transcriptWasDeleted(episodeKey: episodeKey, enclosureURL: enclosureURL)
		}
	}
}

private extension TranscriptSyncManager {

	func sync() {
		guard let cloudSync else {
			return
		}
		Task {
			await cloudSync.sync()
		}
	}

	@objc func appDidBecomeActive(_ notification: Notification) {
		sync()
	}

	/// Posted on a background queue.
	@objc nonisolated func accountDidChange(_ notification: Notification) {
		guard let cloudSync else {
			return
		}
		Task {
			await cloudSync.accountDidChange()
		}
	}

	func cloudDidChange(_ changes: TranscriptCloudChanges) {
		if !changes.changedEpisodeKeys.isEmpty {
			TranscriptionManager.shared.episodeTranscriptsDidChange(changes.changedEpisodeKeys)
		}
		// Another device transcribed an episode that was shown here without a transcript.
		for episodeKey in changes.availableEpisodeKeys {
			lookupThrottle.forget(episodeKey)
			for article in articlesWithMissedLookups.removeValue(forKey: episodeKey) ?? [] {
				lookUpTranscript(for: article, episodeKey: episodeKey)
			}
		}
	}

	func addArticle(_ article: Article, to articlesByEpisodeKey: inout [EpisodeKey: [Article]], episodeKey: EpisodeKey) {
		var articles = articlesByEpisodeKey[episodeKey] ?? []
		if !articles.contains(where: { $0.articleID == article.articleID }) {
			articles.append(article)
		}
		articlesByEpisodeKey[episodeKey] = articles
	}

	func rememberMissedLookup(_ articles: [Article], episodeKey: EpisodeKey) {
		for article in articles {
			addArticle(article, to: &articlesWithMissedLookups, episodeKey: episodeKey)
		}
		if articlesWithMissedLookups.count > Self.maximumMissedLookups, let anyEpisodeKey = articlesWithMissedLookups.keys.first(where: { $0 != episodeKey }) {
			articlesWithMissedLookups[anyEpisodeKey] = nil
		}
	}
}
