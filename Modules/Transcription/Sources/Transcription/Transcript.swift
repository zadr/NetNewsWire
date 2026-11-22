//
//  Transcript.swift
//  Transcription
//

import Foundation

/// A transcript of an audio file: timestamped segments (roughly paragraphs), each with word timings.
///
/// Speaker labels are optional at both the segment and word level, so a later pass
/// (such as speaker diarization) can fill them in by time without changing the structure.
public struct Transcript: Codable, Hashable, Sendable {

	public static let currentVersion = 1

	public let version: Int
	/// The URL of the audio the transcript was made from.
	public let audioURL: String
	public let localeIdentifier: String
	public let dateCreated: Date
	/// Length of the audio in seconds, when known.
	public let duration: TimeInterval?
	public var segments: [TranscriptSegment]

	public init(audioURL: String, localeIdentifier: String, dateCreated: Date = Date(), duration: TimeInterval?, segments: [TranscriptSegment]) {
		self.version = Self.currentVersion
		self.audioURL = audioURL
		self.localeIdentifier = localeIdentifier
		self.dateCreated = dateCreated
		self.duration = duration
		self.segments = segments
	}

	public var text: String {
		segments.map(\.text).joined(separator: "\n\n")
	}

	public var isEmpty: Bool {
		segments.isEmpty
	}
}

public struct TranscriptSegment: Codable, Hashable, Sendable {

	public var text: String
	/// Seconds from the start of the audio.
	public var startTime: TimeInterval
	public var endTime: TimeInterval
	public var words: [TranscriptWord]
	/// Who’s speaking. Nil until speakers are assigned.
	public var speaker: String?
	/// Everyone speaking at some point during the segment when others talk over `speaker`, `speaker` first.
	/// Nil when there’s no crosstalk.
	public var speakers: [String]?

	public init(text: String, startTime: TimeInterval, endTime: TimeInterval, words: [TranscriptWord], speaker: String? = nil, speakers: [String]? = nil) {
		self.text = text
		self.startTime = startTime
		self.endTime = endTime
		self.words = words
		self.speaker = speaker
		self.speakers = speakers
	}
}

public struct TranscriptWord: Codable, Hashable, Sendable {

	public var text: String
	/// Seconds from the start of the audio.
	public var startTime: TimeInterval
	public var endTime: TimeInterval
	/// From 0 to 1, when the recognizer reports it.
	public var confidence: Double?
	/// Who’s speaking. Nil until speakers are assigned.
	public var speaker: String?
	/// Everyone speaking during the word when several people talk at once, `speaker` first. Nil otherwise.
	public var speakers: [String]?

	public init(text: String, startTime: TimeInterval, endTime: TimeInterval, confidence: Double? = nil, speaker: String? = nil, speakers: [String]? = nil) {
		self.text = text
		self.startTime = startTime
		self.endTime = endTime
		self.confidence = confidence
		self.speaker = speaker
		self.speakers = speakers
	}
}
