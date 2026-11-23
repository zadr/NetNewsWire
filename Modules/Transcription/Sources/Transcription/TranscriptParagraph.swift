//
//  TranscriptParagraph.swift
//  Transcription
//

import Foundation

/// A transcript segment for display, with brief interjections from other speakers — “Yeah.”, “Right.” —
/// kept inline rather than starting paragraphs of their own.
public struct TranscriptParagraph: Hashable, Sendable {

	public let segment: TranscriptSegment
	/// Short segments by other speakers that came right after this one, in order.
	public internal(set) var interjections: [TranscriptSegment]

	/// An interjection is at most this long…
	static let maximumInterjectionDuration: TimeInterval = 3
	/// …and has at most this many words.
	static let maximumInterjectionWordCount = 6

	init(segment: TranscriptSegment, interjections: [TranscriptSegment] = []) {
		self.segment = segment
		self.interjections = interjections
	}

	/// Groups segments into paragraphs. A segment is an interjection when it’s brief, its speaker differs from
	/// the speaker of the paragraph it follows, and that paragraph isn’t brief itself — so a quick back-and-forth
	/// stays as separate paragraphs. Transcripts without speakers get one paragraph per segment.
	public static func paragraphs(from segments: [TranscriptSegment]) -> [TranscriptParagraph] {
		var paragraphs = [TranscriptParagraph]()
		for segment in segments {
			if let lastIndex = paragraphs.indices.last, isInterjection(segment, after: paragraphs[lastIndex].segment) {
				paragraphs[lastIndex].interjections.append(segment)
			} else {
				paragraphs.append(TranscriptParagraph(segment: segment))
			}
		}
		return paragraphs
	}

	static func isInterjection(_ segment: TranscriptSegment, after paragraphSegment: TranscriptSegment) -> Bool {
		guard let speaker = segment.speaker, let paragraphSpeaker = paragraphSegment.speaker, speaker != paragraphSpeaker else {
			return false
		}
		return isBrief(segment) && !isBrief(paragraphSegment)
	}

	static func isBrief(_ segment: TranscriptSegment) -> Bool {
		segment.endTime - segment.startTime <= maximumInterjectionDuration && segment.words.count <= maximumInterjectionWordCount
	}
}
