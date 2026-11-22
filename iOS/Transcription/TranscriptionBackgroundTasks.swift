//
//  TranscriptionBackgroundTasks.swift
//  NetNewsWire-iOS
//

import Foundation
import BackgroundTasks
import os
import RSCore
import Transcription

/// Keeps transcriptions running when the app is in the background, using continued processing tasks,
/// which show each transcription’s progress in the system’s UI. When the system or the user stops one,
/// the transcription is canceled.
@available(iOS 26, *)
@MainActor final class TranscriptionBackgroundTasks {

	static let shared = TranscriptionBackgroundTasks()

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "TranscriptionBackgroundTasks")
	private static let progressUnitCount: Int64 = 1000
	private static let submissionQueue = DispatchQueue(label: "TranscriptionBackgroundTasks")

	/// Must match the wildcard identifier in Info.plist’s BGTaskSchedulerPermittedIdentifiers.
	private static var identifierPrefix: String {
		(Bundle.main.bundleIdentifier ?? "com.ranchero.NetNewsWire") + ".transcription."
	}

	/// Task identifiers of submitted requests, by article ID.
	private var identifiers = [String: String]()
	/// Running tasks, by article ID.
	private var tasks = [String: BGContinuedProcessingTask]()
	private var isStarted = false

	/// Call at launch.
	func start() {
		guard !isStarted else {
			return
		}
		isStarted = true
		NotificationCenter.default.addObserver(self, selector: #selector(transcriptionDidChange(_:)), name: .transcriptionDidChange, object: nil)
	}

	@objc func transcriptionDidChange(_ notification: Notification) {
		guard let articleID = notification.userInfo?[UserInfoKey.articleID] as? String else {
			return
		}
		let transcriptionManager = TranscriptionManager.shared
		if transcriptionManager.isTranscribing(articleID: articleID) {
			guard !transcriptionManager.isCheckingICloud(articleID: articleID) else {
				// Waits to see whether iCloud has the transcript, which needs no background processing.
				return
			}
			if identifiers[articleID] == nil {
				submitRequest(articleID: articleID)
			} else {
				updateTask(articleID: articleID)
			}
		} else if identifiers[articleID] != nil {
			let succeeded = transcriptionManager.state(forArticleID: articleID) == nil
			finishTask(articleID: articleID, success: succeeded)
		}
	}
}

@available(iOS 26, *)
private extension TranscriptionBackgroundTasks {

	func submitRequest(articleID: String) {
		let identifier = Self.identifierPrefix + UUID().uuidString
		let title = TranscriptionManager.shared.title(forArticleID: articleID) ?? NSLocalizedString("Transcribe Episode", comment: "Command")
		let subtitle = NSLocalizedString("Transcribing…", comment: "Transcript status in article view")

		// Continued processing task identifiers may be registered after launch. Each is used once.
		let isRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
			MainActor.assumeIsolated {
				guard let task = task as? BGContinuedProcessingTask else {
					task.setTaskCompleted(success: false)
					return
				}
				self.taskDidLaunch(task, articleID: articleID, identifier: identifier)
			}
		}
		guard isRegistered else {
			Self.logger.error("TranscriptionBackgroundTasks: couldn’t register \(identifier, privacy: .public) — is it permitted in Info.plist?")
			return
		}
		identifiers[articleID] = identifier

		// Off the main thread, since submitting can hang. (See AppDelegate.scheduleBackgroundFeedRefresh.)
		Self.submissionQueue.async {
			let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
			// If it can’t run now, transcribing goes on while the app is in the foreground. A queued request would start too late to help.
			request.strategy = .fail
			do {
				try BGTaskScheduler.shared.submit(request)
			} catch {
				Self.logger.info("TranscriptionBackgroundTasks: couldn’t submit continued processing task: \(error.localizedDescription, privacy: .public)")
				Task { @MainActor in
					self.submissionDidFail(articleID: articleID, identifier: identifier)
				}
			}
		}
	}

	func submissionDidFail(articleID: String, identifier: String) {
		if identifiers[articleID] == identifier {
			identifiers[articleID] = nil
		}
	}

	func taskDidLaunch(_ task: BGContinuedProcessingTask, articleID: String, identifier: String) {
		// Transcribing may have finished, or been canceled, before the task launched.
		guard identifiers[articleID] == identifier, TranscriptionManager.shared.isTranscribing(articleID: articleID) else {
			task.setTaskCompleted(success: TranscriptionManager.shared.state(forArticleID: articleID) == nil)
			return
		}

		tasks[articleID] = task
		task.progress.totalUnitCount = Self.progressUnitCount
		task.expirationHandler = { [weak self] in
			Task { @MainActor in
				self?.taskDidExpire(articleID: articleID)
			}
		}
		updateTask(articleID: articleID)
	}

	func updateTask(articleID: String) {
		guard let task = tasks[articleID], case .inProgress(let progress) = TranscriptionManager.shared.state(forArticleID: articleID) else {
			return
		}
		if let overallFractionCompleted = progress.overallFractionCompleted {
			task.progress.completedUnitCount = Int64(overallFractionCompleted * Double(Self.progressUnitCount))
		}
		task.updateTitle(task.title, subtitle: TranscriptionManager.description(of: progress))
	}

	/// The system needs the resources back, or the user stopped the task.
	func taskDidExpire(articleID: String) {
		Self.logger.info("TranscriptionBackgroundTasks: continued processing task expired")
		TranscriptionManager.shared.cancelTranscription(articleID: articleID, error: TranscriptionStoppedError())
		// Canceling posts transcriptionDidChange, which finishes the task. This makes sure, as an expired task must be completed.
		finishTask(articleID: articleID, success: false)
	}

	func finishTask(articleID: String, success: Bool) {
		guard let identifier = identifiers.removeValue(forKey: articleID) else {
			return
		}
		guard let task = tasks.removeValue(forKey: articleID) else {
			// Not launched yet.
			BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
			return
		}
		if success {
			task.progress.completedUnitCount = task.progress.totalUnitCount
		}
		task.setTaskCompleted(success: success)
	}
}

private struct TranscriptionStoppedError: LocalizedError {

	var errorDescription: String? {
		NSLocalizedString("Transcription was stopped before it finished.", comment: "Transcription error")
	}
}
