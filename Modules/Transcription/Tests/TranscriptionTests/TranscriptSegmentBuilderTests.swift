//
//  TranscriptSegmentBuilderTests.swift
//  TranscriptionTests
//

import Foundation
import Testing
@testable import Transcription

@Suite struct TranscriptSegmentBuilderTests {

	@Test func wordsBecomeOneSegmentWithTimings() {
		let tokens = [
			token("Hello", 0, 0.4, confidence: 0.9),
			token(" world", 0.5, 0.9),
			token(".", nil, nil)
		]

		let segments = TranscriptSegmentBuilder.segments(from: tokens)

		#expect(segments.count == 1)
		#expect(segments[0].text == "Hello world.")
		#expect(segments[0].startTime == 0)
		#expect(segments[0].endTime == 0.9)
		#expect(segments[0].words.map(\.text) == ["Hello", "world."])
		#expect(segments[0].words[0].confidence == 0.9)
		#expect(segments[0].speaker == nil)
	}

	@Test func longPauseStartsNewSegment() {
		let tokens = [
			token("One", 0, 0.5),
			token(" two", 0.6, 1),
			token(" three", 5, 5.5)
		]

		let segments = TranscriptSegmentBuilder.segments(from: tokens)

		#expect(segments.map(\.text) == ["One two", "three"])
		#expect(segments[1].startTime == 5)
	}

	@Test func sentenceEndAfterPreferredDurationStartsNewSegment() {
		var builder = TranscriptSegmentBuilder(pauseThreshold: 10, preferredSegmentDuration: 5, maximumSegmentDuration: 100)
		builder.append(token("First", 0, 1))
		builder.append(token(" sentence.", 1, 2))
		builder.append(token(" Still", 2, 3))
		builder.append(token(" going,", 3, 6))
		builder.append(token(" then", 6, 7))
		builder.append(token(" “done.”", 7, 8))
		builder.append(token(" Next", 8, 9))

		let segments = builder.finish()

		#expect(segments.map(\.text) == ["First sentence. Still going, then “done.”", "Next"])
	}

	@Test func maximumDurationEndsSegmentMidSentence() {
		var builder = TranscriptSegmentBuilder(pauseThreshold: 10, preferredSegmentDuration: 5, maximumSegmentDuration: 10)
		for index in 0..<12 {
			builder.append(token(index == 0 ? "word" : " word", Double(index), Double(index) + 1))
		}

		let segments = builder.finish()

		#expect(segments.count == 2)
		#expect(segments[0].words.count == 10)
		#expect(segments[1].startTime == 10)
	}

	@Test func untimedTextIsKeptInSegmentText() {
		let tokens = [
			token("“", nil, nil),
			token("Quote", 0, 1),
			token("”", nil, nil),
			token(" ", nil, nil),
			token("said", 1, 2)
		]

		let segments = TranscriptSegmentBuilder.segments(from: tokens)

		#expect(segments.count == 1)
		#expect(segments[0].text == "“Quote” said")
		#expect(segments[0].words.map(\.text) == ["Quote”", "said"])
	}

	@Test func trailingUntimedTextGoesToLastSegment() {
		let tokens = [
			token("Hi", 0, 1),
			token(" there", 5, 6),
			token(" !", nil, nil)
		]

		let segments = TranscriptSegmentBuilder.segments(from: tokens)

		#expect(segments.map(\.text) == ["Hi", "there !"])
	}

	@Test func noTimedWordsMeansNoSegments() {
		#expect(TranscriptSegmentBuilder.segments(from: [token("...", nil, nil)]).isEmpty)
		#expect(TranscriptSegmentBuilder.segments(from: []).isEmpty)
	}

	@Test func endsSentence() {
		#expect(TranscriptSegmentBuilder.endsSentence("done."))
		#expect(TranscriptSegmentBuilder.endsSentence("really?”"))
		#expect(TranscriptSegmentBuilder.endsSentence("wow!)"))
		#expect(!TranscriptSegmentBuilder.endsSentence("and,"))
		#expect(!TranscriptSegmentBuilder.endsSentence("”"))
	}
}

private func token(_ text: String, _ startTime: TimeInterval?, _ endTime: TimeInterval?, confidence: Double? = nil) -> TranscriptToken {
	TranscriptToken(text: text, startTime: startTime, endTime: endTime, confidence: confidence)
}
