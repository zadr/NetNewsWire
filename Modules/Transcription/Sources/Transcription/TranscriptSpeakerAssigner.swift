//
//  TranscriptSpeakerAssigner.swift
//  Transcription
//

import Foundation
import SpeakerDiarization

/// Labels a transcript’s words with who said them, from speaker diarization of the same audio,
/// and splits segments where the speaker changes.
///
/// A word’s speaker is the one active for most of its time span. When several speakers are each active for at least
/// half of it (crosstalk), all of them are recorded in `speakers`, the main one first. A word during which nobody
/// was detected speaking keeps a nil speaker and stays with the words around it.
///
/// Labels are the diarizer’s speaker numbers as strings: "0", "1", and so on, in order of first arrival.
/// They’re stable within a transcript; display names are up to the UI.
public enum TranscriptSpeakerAssigner {

	public static func assigningSpeakers(to transcript: Transcript, from activity: SpeakerActivity) -> Transcript {
		var transcript = transcript
		transcript.segments = transcript.segments.flatMap { segment in
			splitBySpeaker(labeled(segment, activity: activity))
		}
		return transcript
	}
}

extension TranscriptSpeakerAssigner {

	static func label(for speaker: Int) -> String {
		String(speaker)
	}

	static func labeled(_ segment: TranscriptSegment, activity: SpeakerActivity) -> TranscriptSegment {
		var segment = segment
		for index in segment.words.indices {
			let word = segment.words[index]
			let (speaker, speakers) = speakers(from: word.startTime, to: word.endTime, activity: activity)
			segment.words[index].speaker = speaker
			segment.words[index].speakers = speakers
		}
		return segment
	}

	/// The main speaker over a time span, and — when more than one speaker is active for at least half of it — all of those.
	static func speakers(from startTime: TimeInterval, to endTime: TimeInterval, activity: SpeakerActivity) -> (speaker: String?, speakers: [String]?) {
		let counts = activity.activeFrameCounts(from: startTime, to: endTime)
		let ranked = counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }
		guard let main = ranked.first else {
			return (nil, nil)
		}
		let frameCount = max(1, Int((endTime / SpeakerActivity.frameDuration).rounded(.up)) - Int((startTime / SpeakerActivity.frameDuration).rounded(.down)))
		let overlapping = ranked.filter { $0.key == main.key || $0.value * 2 >= frameCount }
		let speakers = overlapping.count > 1 ? overlapping.map { label(for: $0.key) } : nil
		return (label(for: main.key), speakers)
	}

	/// Splits a segment into runs of words with the same speaker.
	static func splitBySpeaker(_ segment: TranscriptSegment) -> [TranscriptSegment] {
		var runs = [[TranscriptWord]]()
		var runSpeaker: String?
		for word in segment.words {
			if let speaker = word.speaker, let currentSpeaker = runSpeaker, speaker != currentSpeaker {
				runs.append([word])
				runSpeaker = speaker
				continue
			}
			if let lastIndex = runs.indices.last {
				runs[lastIndex].append(word)
			} else {
				runs.append([word])
			}
			runSpeaker = runSpeaker ?? word.speaker
		}
		guard runs.count > 1 else {
			var segment = segment
			segment.speaker = firstSpeaker(in: segment.words)
			segment.speakers = overlappingSpeakers(in: segment.words, speaker: segment.speaker)
			return [segment]
		}

		let texts = splitText(segment.text, runs: runs)
		return zip(runs, texts).compactMap { words, text in
			guard let first = words.first, let last = words.last else {
				return nil
			}
			let speaker = firstSpeaker(in: words)
			return TranscriptSegment(text: text, startTime: first.startTime, endTime: last.endTime, words: words, speaker: speaker, speakers: overlappingSpeakers(in: words, speaker: speaker))
		}
	}

	static func firstSpeaker(in words: [TranscriptWord]) -> String? {
		words.first { $0.speaker != nil }?.speaker
	}

	/// Everyone who talks over the segment’s speaker in some word, the segment’s speaker first; nil without crosstalk.
	static func overlappingSpeakers(in words: [TranscriptWord], speaker: String?) -> [String]? {
		var speakers = speaker.map { [$0] } ?? []
		for word in words {
			for wordSpeaker in word.speakers ?? [] where !speakers.contains(wordSpeaker) {
				speakers.append(wordSpeaker)
			}
		}
		return speakers.count > 1 ? speakers : nil
	}

	/// Splits a segment’s text before the first word of each run, keeping its punctuation and spacing.
	/// Words are found in the text in order; if one can’t be, the runs’ words are joined with spaces instead.
	static func splitText(_ text: String, runs: [[TranscriptWord]]) -> [String] {
		var boundaries = [String.Index]()
		var searchStart = text.startIndex
		for (runIndex, run) in runs.enumerated() {
			for (wordIndex, word) in run.enumerated() {
				guard let range = text.range(of: word.text, range: searchStart..<text.endIndex) else {
					return runs.map { $0.map(\.text).joined(separator: " ") }
				}
				if wordIndex == 0 && runIndex > 0 {
					boundaries.append(range.lowerBound)
				}
				searchStart = range.upperBound
			}
		}
		var pieces = [String]()
		var start = text.startIndex
		for boundary in boundaries {
			pieces.append(text[start..<boundary].trimmingCharacters(in: .whitespacesAndNewlines))
			start = boundary
		}
		pieces.append(text[start...].trimmingCharacters(in: .whitespacesAndNewlines))
		return pieces
	}
}
