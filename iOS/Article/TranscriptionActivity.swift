//
//  TranscriptionActivity.swift
//  NetNewsWire-iOS
//

import UIKit
import Articles

/// A transcription command — such as Transcribe Episode or Delete Transcript — in the share sheet.
final class TranscriptionActivity: UIActivity {

	private let command: TranscriptionManager.Command
	private let article: Article
	private let image: UIImage?

	@MainActor init(command: TranscriptionManager.Command, article: Article) {
		self.command = command
		self.article = article
		self.image = command.image.applyingSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 20, weight: .regular))
		super.init()
	}

	/// One for each command that applies to the article.
	@MainActor static func activities(for article: Article) -> [TranscriptionActivity] {
		TranscriptionManager.shared.commands(for: article).map { TranscriptionActivity(command: $0, article: article) }
	}

	override var activityTitle: String? {
		command.title
	}

	override var activityType: UIActivity.ActivityType? {
		UIActivity.ActivityType(rawValue: "com.ranchero.NetNewsWire.transcription.\(command)")
	}

	override var activityImage: UIImage? {
		image
	}

	override static var activityCategory: UIActivity.Category {
		.action
	}

	override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
		true
	}

	override func prepare(withActivityItems activityItems: [Any]) {

	}

	override func perform() {
		let command = command
		let article = article
		Task { @MainActor in
			TranscriptionManager.shared.perform(command, on: article)
		}
		activityDidFinish(true)
	}
}

extension TranscriptionManager.Command {

	@MainActor var image: UIImage {
		switch self {
		case .transcribe:
			return Assets.Images.transcribe
		case .cancel:
			return Assets.Images.cancelTranscription
		case .retranscribe:
			return Assets.Images.retranscribe
		case .deleteTranscript:
			return Assets.Images.trash
		}
	}
}

extension TranscriptionManager {

	/// Context menu actions for each command that applies to the article.
	func actions(for article: Article) -> [UIAction] {
		commands(for: article).map { command in
			let attributes: UIMenuElement.Attributes = command == .deleteTranscript ? .destructive : []
			return UIAction(title: command.title, image: command.image, attributes: attributes) { _ in
				TranscriptionManager.shared.perform(command, on: article)
			}
		}
	}
}
