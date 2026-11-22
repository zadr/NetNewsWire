//
//  TranscriptionManager.swift
//  NetNewsWire
//

import Foundation
import os
import RSCore
import Articles
import Account
import Transcription

extension Notification.Name {
	/// Posted when an article’s transcription starts, progresses, finishes, fails, or is canceled, or its transcript is deleted.
	/// `userInfo[UserInfoKey.articleID]` is the article’s ID.
	static let transcriptionDidChange = Notification.Name("TranscriptionDidChangeNotification")
}

/// Transcribes podcast episodes — articles with an audio enclosure — and keeps their transcripts.
///
/// Transcripts are removed along with their articles, feeds, and accounts: a cleanup pass runs at launch,
/// after refreshing, and when feeds or accounts are removed.
@MainActor final class TranscriptionManager {

	static let shared = TranscriptionManager()

	enum State {
		case inProgress(TranscriptionProgress)
		case failed(Error)
	}

	enum Command {
		case transcribe
		case cancel
		case retranscribe
		case deleteTranscript

		var title: String {
			switch self {
			case .transcribe:
				return NSLocalizedString("Transcribe Episode", comment: "Command")
			case .cancel:
				return NSLocalizedString("Cancel Transcription", comment: "Command")
			case .retranscribe:
				return NSLocalizedString("Re-transcribe Episode", comment: "Command")
			case .deleteTranscript:
				return NSLocalizedString("Delete Transcript", comment: "Command")
			}
		}
	}

	private struct Job {
		let task: Task<Void, Never>
		let audioURL: URL
		let title: String
	}

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "TranscriptionManager")
	private static let maximumCachedTranscripts = 5
	/// Audio left by a failed transcription is kept this long, so trying again doesn’t download it again.
	private static let cachedAudioLifetime: TimeInterval = 24 * 60 * 60
	/// Waits for feeds and articles to settle after a change before cleaning up.
	private static let cleanupDelay = Duration.seconds(5)

	private let store = TranscriptStore(folderURL: AppConfig.dataSubfolder(named: "Transcripts"))
	private let transcriber = Transcriber(audioCacheFolderURL: AppConfig.cacheSubfolder(named: "TranscriptionAudio"))
	private var states = [String: State]()
	private var jobs = [String: Job]()
	private var cachedTranscripts = [(articleID: String, transcript: Transcript)]()
	private var cleanupTask: Task<Void, Never>?

	private init() {
		NotificationCenter.default.addObserver(self, selector: #selector(transcriptOwnersMayHaveChanged(_:)), name: .UserDidDeleteAccount, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(transcriptOwnersMayHaveChanged(_:)), name: .ChildrenDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(transcriptOwnersMayHaveChanged(_:)), name: .AccountRefreshDidFinish, object: nil)
	}

	/// Call at launch. Starts watching for removed articles, feeds, and accounts, and cleans up after the last run.
	func start() {
		scheduleCleanup()
	}

	var isSupported: Bool {
		Transcriber.isSupported
	}

	/// The audio that a transcript is made from.
	func audioAttachment(for article: Article) -> Attachment? {
		article.attachments?.first { $0.displayMedium == .audio }
	}

	func isTranscribing(_ article: Article) -> Bool {
		isTranscribing(articleID: article.articleID)
	}

	func isTranscribing(articleID: String) -> Bool {
		jobs[articleID] != nil
	}

	func hasTranscript(_ article: Article) -> Bool {
		cachedTranscript(for: article.articleID) != nil || store.hasTranscript(forArticleID: article.articleID)
	}

	func transcript(for article: Article) -> Transcript? {
		let articleID = article.articleID
		if let transcript = cachedTranscript(for: articleID) {
			return transcript
		}
		guard let transcript = store.transcript(forArticleID: articleID) else {
			return nil
		}
		cacheTranscript(transcript, for: articleID)
		return transcript
	}

	func state(for article: Article) -> State? {
		state(forArticleID: article.articleID)
	}

	func state(forArticleID articleID: String) -> State? {
		states[articleID]
	}

	/// The episode’s title, for showing progress outside the app.
	func title(forArticleID articleID: String) -> String? {
		jobs[articleID]?.title
	}

	/// Such as “Transcribing… 42%”.
	static func description(of progress: TranscriptionProgress) -> String {
		let description: String
		switch progress {
		case .downloadingAudio:
			description = NSLocalizedString("Downloading audio for transcript…", comment: "Transcript status in article view")
		case .installingSpeechModel:
			description = NSLocalizedString("Downloading speech recognition model…", comment: "Transcript status in article view")
		case .transcribing:
			description = NSLocalizedString("Transcribing…", comment: "Transcript status in article view")
		}
		guard let fractionCompleted = progress.fractionCompleted else {
			return description
		}
		return description + " " + fractionCompleted.formatted(.percent.precision(.fractionLength(0)))
	}

	// MARK: - Commands

	/// What can be done with the article’s transcript, in menu order. Empty for articles without audio.
	func commands(for article: Article) -> [Command] {
		guard audioAttachment(for: article) != nil else {
			return []
		}
		if isTranscribing(article) {
			return [.cancel]
		}
		let hasTranscript = hasTranscript(article)
		guard isSupported else {
			return hasTranscript ? [.deleteTranscript] : []
		}
		return hasTranscript ? [.retranscribe, .deleteTranscript] : [.transcribe]
	}

	func canPerform(_ command: Command, on article: Article) -> Bool {
		commands(for: article).contains(command)
	}

	func perform(_ command: Command, on article: Article) {
		guard canPerform(command, on: article) else {
			return
		}
		switch command {
		case .transcribe, .retranscribe:
			transcribe(article)
		case .cancel:
			cancelTranscription(articleID: article.articleID)
		case .deleteTranscript:
			deleteTranscript(articleID: article.articleID)
		}
	}

	/// True when the Transcribe Episode command, which becomes Cancel Transcription while transcribing, applies.
	func canToggleTranscription(_ article: Article) -> Bool {
		canPerform(.transcribe, on: article) || canPerform(.cancel, on: article)
	}

	func toggleTranscriptionCommandTitle(_ article: Article?) -> String {
		if let article, isTranscribing(article) {
			return Command.cancel.title
		}
		return Command.transcribe.title
	}

	/// Starts transcribing, or cancels transcribing if it already started.
	func toggleTranscription(_ article: Article) {
		perform(isTranscribing(article) ? .cancel : .transcribe, on: article)
	}

	// MARK: - Transcribing

	/// Transcribes in the feed’s language when it declares one that’s supported, else the device’s.
	/// A new transcript replaces an existing one only once it’s done.
	func transcribe(_ article: Article) {
		guard isSupported, !isTranscribing(article), let attachment = audioAttachment(for: article), let audioURL = URL(string: attachment.url) else {
			return
		}

		let articleID = article.articleID
		let record = TranscriptRecord(articleID: articleID, accountID: article.accountID, feedID: article.feedID, audioURL: attachment.url)
		let locales = TranscriptionLocale.candidates(feedLanguage: article.feed?.language, deviceLocale: .current)
		let title = attachment.title ?? article.title ?? article.feed?.nameForDisplay ?? attachment.url
		let transcriber = transcriber
		let store = store

		states[articleID] = .inProgress(.downloadingAudio(fractionCompleted: nil))
		let task = Task { [weak self] in
			do {
				let transcript = try await transcriber.transcribe(audioURL: audioURL, locales: locales) { progress in
					Task { @MainActor in
						self?.transcriptionDidProgress(progress, articleID: articleID)
					}
				}
				try store.save(transcript, record: record)
				self?.transcriptionDidFinish(articleID: articleID, result: .success(transcript))
			} catch {
				self?.transcriptionDidFinish(articleID: articleID, result: .failure(error))
			}
		}
		jobs[articleID] = Job(task: task, audioURL: audioURL, title: title)
		postTranscriptionDidChange(articleID: articleID)
	}

	/// Stops transcribing and deletes the downloaded audio. With an `error`, the article shows it as the reason —
	/// for when the system, rather than the user, stopped it.
	func cancelTranscription(articleID: String, error: Error? = nil) {
		guard let job = jobs.removeValue(forKey: articleID) else {
			return
		}
		job.task.cancel()
		transcriber.audioDownloader.removeCachedFile(for: job.audioURL)
		if let error {
			states[articleID] = .failed(error)
		} else {
			states[articleID] = nil
		}
		postTranscriptionDidChange(articleID: articleID)
	}

	func deleteTranscript(articleID: String) {
		guard !isTranscribing(articleID: articleID) else {
			return
		}
		removeTranscript(articleID: articleID)
		states[articleID] = nil
		postTranscriptionDidChange(articleID: articleID)
	}
}

// MARK: - Cleanup

private extension TranscriptionManager {

	@objc func transcriptOwnersMayHaveChanged(_ notification: Notification) {
		scheduleCleanup()
	}

	/// Coalesces bursts of changes, such as many feeds refreshing.
	func scheduleCleanup() {
		cleanupTask?.cancel()
		cleanupTask = Task { [weak self] in
			try? await Task.sleep(for: Self.cleanupDelay)
			guard !Task.isCancelled else {
				return
			}
			await self?.removeOrphanedTranscripts()
		}
	}

	/// Removes transcripts whose account, feed, or article is gone, transcript files with no record,
	/// and audio left behind by failed transcriptions.
	func removeOrphanedTranscripts() async {
		let unindexedCount = store.removeUnindexedTranscripts()

		let accounts = AccountManager.shared.accounts
		let feedIDsByAccountID = Dictionary(accounts.map { ($0.accountID, Set($0.flattenedFeeds().map(\.feedID))) }) { first, _ in first }
		let records = store.records.filter { !isTranscribing(articleID: $0.articleID) }
		var orphanedRecords = TranscriptCleanup.recordsWithoutFeeds(records, feedIDsByAccountID: feedIDsByAccountID)

		let recordsWithFeeds = records.filter { !orphanedRecords.contains($0) }
		var existingArticleIDsByAccountID = [String: Set<String>]()
		for (accountID, articleIDs) in TranscriptCleanup.articleIDsByAccountID(recordsWithFeeds) {
			guard let account = AccountManager.shared.existingAccount(accountID: accountID) else {
				continue
			}
			let articles = await account.fetchArticlesAsync(.articleIDs(articleIDs))
			existingArticleIDsByAccountID[accountID] = Set(articles.map(\.articleID))
		}
		orphanedRecords += TranscriptCleanup.recordsWithoutArticles(recordsWithFeeds, existingArticleIDsByAccountID: existingArticleIDsByAccountID)

		// Transcribing may have started again while fetching.
		let removableRecords = orphanedRecords.filter { !isTranscribing(articleID: $0.articleID) }
		for record in removableRecords {
			removeTranscript(articleID: record.articleID)
			states[record.articleID] = nil
			postTranscriptionDidChange(articleID: record.articleID)
		}

		let audioURLsInUse = Set(jobs.values.map(\.audioURL))
		let staleAudioCount = transcriber.audioDownloader.removeCachedFiles(changedBefore: Date().addingTimeInterval(-Self.cachedAudioLifetime), except: audioURLsInUse)

		if unindexedCount + removableRecords.count + staleAudioCount > 0 {
			Self.logger.info("TranscriptionManager: removed \(removableRecords.count) orphaned transcripts, \(unindexedCount) unindexed transcript files, and \(staleAudioCount) cached audio files")
		}
	}

	/// Removes the transcript and any audio downloaded for it.
	func removeTranscript(articleID: String) {
		cachedTranscripts.removeAll { $0.articleID == articleID }
		if let record = store.removeTranscript(forArticleID: articleID), let audioURL = URL(string: record.audioURL) {
			transcriber.audioDownloader.removeCachedFile(for: audioURL)
		}
	}
}

// MARK: - Private

private extension TranscriptionManager {

	func transcriptionDidProgress(_ progress: TranscriptionProgress, articleID: String) {
		guard isTranscribing(articleID: articleID) else {
			return
		}
		if case .inProgress(let currentProgress) = states[articleID], currentProgress.isVisiblyEqual(to: progress) {
			return
		}
		states[articleID] = .inProgress(progress)
		postTranscriptionDidChange(articleID: articleID)
	}

	func transcriptionDidFinish(articleID: String, result: Result<Transcript, Error>) {
		// Nil when canceled.
		guard jobs.removeValue(forKey: articleID) != nil else {
			return
		}

		switch result {
		case .success(let transcript):
			states[articleID] = nil
			cacheTranscript(transcript, for: articleID)
		case .failure(let error):
			Self.logger.error("TranscriptionManager: transcription failed for \(articleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
			states[articleID] = .failed(error)
		}
		postTranscriptionDidChange(articleID: articleID)
	}

	func postTranscriptionDidChange(articleID: String) {
		NotificationCenter.default.post(name: .transcriptionDidChange, object: self, userInfo: [UserInfoKey.articleID: articleID])
	}

	func cachedTranscript(for articleID: String) -> Transcript? {
		cachedTranscripts.first { $0.articleID == articleID }?.transcript
	}

	func cacheTranscript(_ transcript: Transcript, for articleID: String) {
		cachedTranscripts.removeAll { $0.articleID == articleID }
		cachedTranscripts.insert((articleID, transcript), at: 0)
		if cachedTranscripts.count > Self.maximumCachedTranscripts {
			cachedTranscripts.removeLast()
		}
	}
}
