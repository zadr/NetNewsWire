//
//  ArticleRenderer+Transcript.swift
//  NetNewsWire
//

import Foundation
import RSCore
import Articles
import Transcription

/// HTML for a podcast episode’s transcript, added after the enclosures.
extension ArticleRenderer {

	/// Element ID of the transcript section. main.js’s `updateTranscript` replaces its contents as transcription progresses.
	static let transcriptElementID = "nnw-transcript"

	/// Empty for articles without audio. Otherwise a section with the transcript,
	/// transcription progress or failure, or — before transcribing — nothing, ready to be filled in.
	static func transcriptSectionHTML(article: Article) -> String {
		let transcriptionManager = TranscriptionManager.shared
		guard let audioAttachment = transcriptionManager.audioAttachment(for: article) else {
			return ""
		}
		// With iCloud sync, a device that can’t transcribe can still show transcripts from other devices.
		guard transcriptionManager.isSupported || TranscriptSyncManager.shared.isSyncEnabled || transcriptionManager.hasTranscript(article) else {
			return ""
		}
		let articleID = article.articleID.escapingSpecialXMLCharacters
		let audioURL = audioAttachment.url.escapingSpecialXMLCharacters
		return "<section id=\"\(transcriptElementID)\" class=\"nnw-transcript\" data-article-id=\"\(articleID)\" data-audio-url=\"\(audioURL)\">\(transcriptContentHTML(article: article))</section>"
	}

	/// The contents of the transcript section: transcription progress or failure, if any,
	/// then the transcript, if any — which stays while it’s being transcribed again.
	static func transcriptContentHTML(article: Article) -> String {
		let transcriptionManager = TranscriptionManager.shared
		var html = ""

		switch transcriptionManager.state(for: article) {
		case .inProgress(let progress):
			html += statusHTML(TranscriptionManager.description(of: progress))
		case .failed(let error):
			let format = NSLocalizedString("Transcription failed: %@", comment: "Transcript status in article view")
			html += statusHTML(String(format: format, error.localizedDescription))
		case nil:
			break
		}

		if let transcript = transcriptionManager.transcript(for: article) {
			html += transcriptHTML(transcript)
		}
		return html
	}

	/// JavaScript that brings the transcript section up to date in a page showing `article`, without reloading the page.
	static func updateTranscriptJavaScript(article: Article) -> String? {
		let arguments = [article.articleID, transcriptContentHTML(article: article)]
		guard let data = try? JSONSerialization.data(withJSONObject: arguments), let json = String(data: data, encoding: .utf8) else {
			return nil
		}
		return "updateTranscript(...\(json));"
	}
}

private extension ArticleRenderer {

	static func transcriptHTML(_ transcript: Transcript) -> String {
		let title = NSLocalizedString("Transcript", comment: "Transcript heading in article view")
		var html = "<h2 class=\"nnw-transcript-title\">\(title.escapingSpecialXMLCharacters)</h2>\n"
		let speakerNumbers = speakerNumbers(in: transcript)
		var previousSpeakers = [String]()
		for segment in transcript.segments {
			html += "<p class=\"nnw-transcript-segment\">"
			html += "<span class=\"nnw-transcript-time\" data-time=\"\(segment.startTime)\">\(durationString(Int(segment.startTime)))</span> "
			// Label a segment when its speakers differ from the previous segment’s.
			let speakers = speakers(of: segment)
			if !speakers.isEmpty && speakers != previousSpeakers {
				html += "<span class=\"nnw-transcript-speaker\">\(speakerLabel(speakers, numbers: speakerNumbers).escapingSpecialXMLCharacters)</span> "
			}
			previousSpeakers = speakers
			html += segment.text.escapingSpecialXMLCharacters
			html += "</p>\n"
		}
		return html
	}

	/// The segment’s speaker, or everyone speaking when there’s crosstalk, main speaker first.
	static func speakers(of segment: TranscriptSegment) -> [String] {
		if let speakers = segment.speakers, !speakers.isEmpty {
			return speakers
		}
		if let speaker = segment.speaker, !speaker.isEmpty {
			return [speaker]
		}
		return []
	}

	/// Speakers are numbered from 1 in order of first appearance in the transcript.
	static func speakerNumbers(in transcript: Transcript) -> [String: Int] {
		var numbers = [String: Int]()
		for segment in transcript.segments {
			for speaker in speakers(of: segment) where numbers[speaker] == nil {
				numbers[speaker] = numbers.count + 1
			}
		}
		return numbers
	}

	/// “Speaker 1”, or “Speaker 1 and Speaker 2” when they talk over each other.
	static func speakerLabel(_ speakers: [String], numbers: [String: Int]) -> String {
		let format = NSLocalizedString("Speaker %ld", comment: "Speaker label in a podcast transcript; the number is the order in which speakers first appear")
		let names = speakers.compactMap { numbers[$0] }.map { String(format: format, $0) }
		return names.formatted(.list(type: .and))
	}

	static func statusHTML(_ status: String) -> String {
		"<p class=\"nnw-transcript-status\">\(status.escapingSpecialXMLCharacters)</p>"
	}
}
