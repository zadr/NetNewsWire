//
//  TranscriptSegmentBuilder.swift
//  Transcription
//

import Foundation

/// A piece of recognized text, usually a word, as the recognizer reports it.
/// `text` keeps its surrounding whitespace, since that’s how words are separated.
/// Times are nil for text the recognizer didn’t time, such as some punctuation.
public struct TranscriptToken: Hashable, Sendable {

	public let text: String
	public let startTime: TimeInterval?
	public let endTime: TimeInterval?
	public let confidence: Double?

	public init(text: String, startTime: TimeInterval?, endTime: TimeInterval?, confidence: Double? = nil) {
		self.text = text
		self.startTime = startTime
		self.endTime = endTime
		self.confidence = confidence
	}
}

/// Groups tokens into paragraph-sized segments.
///
/// A segment ends at a long pause, at the end of a sentence once it’s long enough,
/// or — mid-sentence, if it has to — once it reaches the maximum length.
public struct TranscriptSegmentBuilder: Sendable {

	public var pauseThreshold: TimeInterval
	public var preferredSegmentDuration: TimeInterval
	public var maximumSegmentDuration: TimeInterval

	private var segments = [TranscriptSegment]()
	private var text = ""
	private var words = [TranscriptWord]()

	private static let sentenceEndings: Set<Character> = [".", "?", "!", "…", "。", "？", "！"]
	private static let closingPunctuation: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»"]

	public init(pauseThreshold: TimeInterval = 2, preferredSegmentDuration: TimeInterval = 30, maximumSegmentDuration: TimeInterval = 90) {
		self.pauseThreshold = pauseThreshold
		self.preferredSegmentDuration = preferredSegmentDuration
		self.maximumSegmentDuration = maximumSegmentDuration
	}

	public static func segments(from tokens: [TranscriptToken]) -> [TranscriptSegment] {
		var builder = TranscriptSegmentBuilder()
		for token in tokens {
			builder.append(token)
		}
		return builder.finish()
	}

	public mutating func append(_ token: TranscriptToken) {
		let trimmedText = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let startTime = token.startTime, let endTime = token.endTime, !trimmedText.isEmpty else {
			appendUntimedText(token.text, trimmedText: trimmedText)
			return
		}

		if shouldEndSegment(beforeWordStartingAt: startTime) {
			endSegment()
		}

		text += token.text
		words.append(TranscriptWord(text: trimmedText, startTime: startTime, endTime: max(startTime, endTime), confidence: token.confidence))
	}

	/// Ends the last segment and returns all the segments.
	public mutating func finish() -> [TranscriptSegment] {
		if words.isEmpty {
			appendLeftoverTextToLastSegment()
		} else {
			endSegment()
		}
		let finishedSegments = segments
		segments = []
		return finishedSegments
	}
}

private extension TranscriptSegmentBuilder {

	mutating func appendUntimedText(_ rawText: String, trimmedText: String) {
		text += rawText
		// Punctuation attached to the previous word belongs to that word.
		if !trimmedText.isEmpty, let lastIndex = words.indices.last, rawText.first?.isWhitespace == false {
			words[lastIndex].text += trimmedText
		}
	}

	func shouldEndSegment(beforeWordStartingAt startTime: TimeInterval) -> Bool {
		guard let firstWord = words.first, let lastWord = words.last else {
			return false
		}
		if startTime - lastWord.endTime >= pauseThreshold {
			return true
		}
		let duration = lastWord.endTime - firstWord.startTime
		if duration >= maximumSegmentDuration {
			return true
		}
		return duration >= preferredSegmentDuration && Self.endsSentence(lastWord.text)
	}

	mutating func endSegment() {
		guard let firstWord = words.first, let lastWord = words.last else {
			return
		}
		let segmentText = text.trimmingCharacters(in: .whitespacesAndNewlines)
		segments.append(TranscriptSegment(text: segmentText, startTime: firstWord.startTime, endTime: lastWord.endTime, words: words))
		text = ""
		words = []
	}

	/// Text after the last timed word, such as a closing quote, can’t start a segment of its own.
	mutating func appendLeftoverTextToLastSegment() {
		let leftoverText = text.trimmingCharacters(in: .whitespacesAndNewlines)
		let separator = text.first?.isWhitespace == true ? " " : ""
		text = ""
		guard !leftoverText.isEmpty, let lastIndex = segments.indices.last else {
			return
		}
		segments[lastIndex].text += separator + leftoverText
	}
}

extension TranscriptSegmentBuilder {

	static func endsSentence(_ word: String) -> Bool {
		var characters = Substring(word)
		while let last = characters.last, closingPunctuation.contains(last) {
			characters = characters.dropLast()
		}
		guard let last = characters.last else {
			return false
		}
		return sentenceEndings.contains(last)
	}
}
