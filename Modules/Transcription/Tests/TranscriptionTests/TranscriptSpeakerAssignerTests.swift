//
//  TranscriptSpeakerAssignerTests.swift
//  TranscriptionTests
//

import Foundation
import Testing
import SpeakerDiarization
@testable import Transcription

@Suite struct TranscriptSpeakerAssignerTests {

	@Test func splitsSegmentWhereSpeakerChanges() {
		// Speaker 0 from 0 to 2 s, speaker 1 from 2 to 4 s.
		let activity = makeActivity(duration: 4, spans: [(0, 0, 2), (1, 2, 4)])
		let segment = makeSegment("Hello there, friend. Hi! How are you?", times: [(0.1, 0.5), (0.6, 1.0), (1.1, 1.8), (2.1, 2.4), (2.6, 2.9), (3.0, 3.2), (3.3, 3.8)])

		let segments = TranscriptSpeakerAssigner.assigningSpeakers(to: makeTranscript([segment]), from: activity).segments

		#expect(segments.map(\.text) == ["Hello there, friend.", "Hi! How are you?"])
		#expect(segments.map(\.speaker) == ["0", "1"])
		#expect(segments.map(\.startTime) == [0.1, 2.1])
		#expect(segments.map(\.endTime) == [1.8, 3.8])
		#expect(segments[0].words.allSatisfy { $0.speaker == "0" })
		#expect(segments[1].words.allSatisfy { $0.speaker == "1" })
		#expect(segments.allSatisfy { $0.speakers == nil })
	}

	@Test func majorityOverlapWins() {
		// The word spans 1.8–2.6 s: 0.2 s of speaker 0, 0.6 s of speaker 1.
		let activity = makeActivity(duration: 4, spans: [(0, 0, 2), (1, 2, 4)])
		let segment = makeSegment("word", times: [(1.8, 2.6)])

		let word = TranscriptSpeakerAssigner.assigningSpeakers(to: makeTranscript([segment]), from: activity).segments[0].words[0]

		#expect(word.speaker == "1")
		#expect(word.speakers == nil)
	}

	@Test func crosstalkRecordsEverySpeaker() {
		// Speaker 1 talks over speaker 0 from 1 to 2 s.
		let activity = makeActivity(duration: 3, spans: [(0, 0, 2), (1, 1, 3)])
		let segment = makeSegment("one two three", times: [(0.2, 0.8), (1.2, 1.7), (2.2, 2.8)])

		let segments = TranscriptSpeakerAssigner.assigningSpeakers(to: makeTranscript([segment]), from: activity).segments

		#expect(segments.map(\.text) == ["one two", "three"])
		#expect(segments[0].words[1].speaker == "0")
		#expect(segments[0].words[1].speakers == ["0", "1"])
		#expect(segments[0].speakers == ["0", "1"])
		#expect(segments[1].speaker == "1")
	}

	@Test func wordsWithoutSpeakerStayWithTheirNeighbors() {
		// Nobody detected from 1 to 2 s.
		let activity = makeActivity(duration: 3, spans: [(0, 0, 1), (0, 2, 3)])
		let segment = makeSegment("a b c", times: [(0.2, 0.8), (1.2, 1.8), (2.2, 2.8)])

		let segments = TranscriptSpeakerAssigner.assigningSpeakers(to: makeTranscript([segment]), from: activity).segments

		#expect(segments.count == 1)
		#expect(segments[0].speaker == "0")
		#expect(segments[0].words.map(\.speaker) == ["0", nil, "0"])
	}

	@Test func repeatedWordsSplitAtTheRightPlace() {
		let activity = makeActivity(duration: 4, spans: [(0, 0, 2), (1, 2, 4)])
		let segment = makeSegment("the end the end", times: [(0.2, 0.5), (0.6, 1.0), (2.2, 2.5), (2.6, 3.0)])

		let segments = TranscriptSpeakerAssigner.assigningSpeakers(to: makeTranscript([segment]), from: activity).segments

		#expect(segments.map(\.text) == ["the end", "the end"])
	}

	@Test func noSpeechLeavesSpeakersNil() {
		let activity = makeActivity(duration: 2, spans: [])
		let segment = makeSegment("quiet words", times: [(0.2, 0.8), (1.2, 1.8)])

		let segments = TranscriptSpeakerAssigner.assigningSpeakers(to: makeTranscript([segment]), from: activity).segments

		#expect(segments.count == 1)
		#expect(segments[0].speaker == nil)
		#expect(segments[0].text == "quiet words")
	}

	@Test func transcriptsWithoutSpeakerFieldsStillDecode() throws {
		let json = """
		{"version":1,"audioURL":"https://example.com/a.mp3","localeIdentifier":"en_US","dateCreated":"2026-11-01T12:00:00Z","duration":3,
		"segments":[{"text":"Hi","startTime":0,"endTime":1,"words":[{"text":"Hi","startTime":0,"endTime":1}]}]}
		"""
		let transcript = try decoder().decode(Transcript.self, from: Data(json.utf8))

		#expect(transcript.segments[0].speaker == nil)
		#expect(transcript.segments[0].speakers == nil)
		#expect(transcript.segments[0].words[0].speakers == nil)
	}

	@Test func speakersRoundTrip() throws {
		let activity = makeActivity(duration: 3, spans: [(0, 0, 2), (1, 1, 3)])
		let transcript = TranscriptSpeakerAssigner.assigningSpeakers(to: makeTranscript([makeSegment("one two three", times: [(0.2, 0.8), (1.2, 1.7), (2.2, 2.8)])]), from: activity)

		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		let data = try encoder.encode(transcript)

		#expect(try decoder().decode(Transcript.self, from: data).segments == transcript.segments)
	}
}

private extension TranscriptSpeakerAssignerTests {

	func decoder() -> JSONDecoder {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return decoder
	}

	/// `spans`: (speaker, start, end) in seconds.
	func makeActivity(duration: TimeInterval, spans: [(Int, TimeInterval, TimeInterval)]) -> SpeakerActivity {
		var frames = [UInt8](repeating: 0, count: Int(duration * 100))
		for (speaker, start, end) in spans {
			for frame in Int(start * 100)..<Int(end * 100) {
				frames[frame] |= 1 << speaker
			}
		}
		return SpeakerActivity(frames: frames)
	}

	/// Words are the text split at spaces.
	func makeSegment(_ text: String, times: [(TimeInterval, TimeInterval)]) -> TranscriptSegment {
		let words = zip(text.split(separator: " "), times).map { TranscriptWord(text: String($0), startTime: $1.0, endTime: $1.1) }
		return TranscriptSegment(text: text, startTime: times[0].0, endTime: times[times.count - 1].1, words: words)
	}

	func makeTranscript(_ segments: [TranscriptSegment]) -> Transcript {
		Transcript(audioURL: "https://example.com/a.mp3", localeIdentifier: "en_US", duration: nil, segments: segments)
	}
}
