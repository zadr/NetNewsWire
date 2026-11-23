//
//  TranscriptParagraphTests.swift
//  Transcription
//

import Foundation
import Testing
@testable import Transcription

struct TranscriptParagraphTests {

	@Test func briefSegmentByAnotherSpeakerIsAnInterjection() {
		let paragraphs = TranscriptParagraph.paragraphs(from: [
			segment(longText, 0, 12, speaker: "0"),
			segment("Yeah, agreed.", 12.5, 13.4, speaker: "1"),
			segment("It blurs the text field.", 13.5, 16, speaker: "0")
		])
		#expect(paragraphs.count == 2)
		#expect(paragraphs[0].segment.text == longText)
		#expect(paragraphs[0].interjections.map(\.text) == ["Yeah, agreed."])
		#expect(paragraphs[1].segment.text == "It blurs the text field.")
	}

	@Test func consecutiveInterjectionsStayWithTheParagraph() {
		let paragraphs = TranscriptParagraph.paragraphs(from: [
			segment(longText, 0, 12, speaker: "0"),
			segment("Uh-huh.", 12, 12.5, speaker: "1"),
			segment("Oh no.", 12.6, 13, speaker: "2")
		])
		#expect(paragraphs.count == 1)
		#expect(paragraphs[0].interjections.map(\.speaker) == ["1", "2"])
	}

	@Test func longSegmentByAnotherSpeakerStartsAParagraph() {
		let paragraphs = TranscriptParagraph.paragraphs(from: [
			segment(longText, 0, 12, speaker: "0"),
			segment("Before we leave this topic, can I have a request?", 12, 17, speaker: "1")
		])
		#expect(paragraphs.count == 2)
		#expect(paragraphs.allSatisfy { $0.interjections.isEmpty })
	}

	@Test func briefSegmentWithManyWordsStartsAParagraph() {
		let paragraphs = TranscriptParagraph.paragraphs(from: [
			segment(longText, 0, 12, speaker: "0"),
			segment("one two three four five six seven", 12, 14, speaker: "1")
		])
		#expect(paragraphs.count == 2)
	}

	@Test func briefSegmentBySameSpeakerStartsAParagraph() {
		let paragraphs = TranscriptParagraph.paragraphs(from: [
			segment(longText, 0, 12, speaker: "0"),
			segment("Anyway.", 14, 14.5, speaker: "0")
		])
		#expect(paragraphs.count == 2)
	}

	@Test func transcriptWithoutSpeakersHasNoInterjections() {
		let paragraphs = TranscriptParagraph.paragraphs(from: [
			segment(longText, 0, 12, speaker: nil),
			segment("Yeah.", 12, 12.5, speaker: nil)
		])
		#expect(paragraphs.count == 2)
	}

	@Test func firstSegmentIsNeverAnInterjection() {
		let paragraphs = TranscriptParagraph.paragraphs(from: [
			segment("Yeah.", 0, 0.5, speaker: "1"),
			segment(longText, 1, 13, speaker: "0")
		])
		#expect(paragraphs.count == 2)
	}

	@Test func quickBackAndForthStaysSeparate() {
		let paragraphs = TranscriptParagraph.paragraphs(from: [
			segment("Did it work?", 0, 1, speaker: "0"),
			segment("It did.", 1.2, 1.8, speaker: "1"),
			segment("Great.", 2, 2.4, speaker: "0")
		])
		#expect(paragraphs.count == 3)
	}

	private let longText = "So here’s what happened when I moved my main bank account over to the new phone last week."

	private func segment(_ text: String, _ startTime: TimeInterval, _ endTime: TimeInterval, speaker: String?) -> TranscriptSegment {
		let words = text.split(separator: " ").map { TranscriptWord(text: String($0), startTime: startTime, endTime: endTime, speaker: speaker) }
		return TranscriptSegment(text: text, startTime: startTime, endTime: endTime, words: words, speaker: speaker)
	}
}
