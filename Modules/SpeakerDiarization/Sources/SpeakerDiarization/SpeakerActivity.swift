//
//  SpeakerActivity.swift
//  SpeakerDiarization
//

import Foundation

/// Who speaks when, every 10 ms. Speakers are numbered from 0 in order of first arrival; several can speak at once.
public struct SpeakerActivity: Hashable, Sendable {

	public static let frameDuration: TimeInterval = 0.01
	public static let maximumNumberOfSpeakers = DiarizationModel.numberOfSpeakers

	/// One bit per speaker (bit `n` for speaker `n`) for each 10 ms frame; frame `t` starts at `t · frameDuration`.
	public let frames: [UInt8]

	public init(frames: [UInt8]) {
		self.frames = frames
	}

	/// A speaker is active where its probability is over 0.5 (its logit over 0), in valid frames.
	init(logits: [Float], validFrameCount: Int) {
		let speakers = Self.maximumNumberOfSpeakers
		var frames = [UInt8](repeating: 0, count: logits.count / speakers)
		for frame in 0..<min(validFrameCount, frames.count) {
			var bits: UInt8 = 0
			for speaker in 0..<speakers where logits[frame * speakers + speaker] > 0 {
				bits |= 1 << speaker
			}
			frames[frame] = bits
		}
		self.frames = frames
	}

	public var duration: TimeInterval {
		Double(frames.count) * Self.frameDuration
	}

	/// Speakers who speak at all, in order of first arrival.
	public var speakers: [Int] {
		let all = frames.reduce(UInt8(0)) { $0 | $1 }
		return (0..<Self.maximumNumberOfSpeakers).filter { all & (1 << $0) != 0 }
	}

	/// Each speaker’s stretches of speech, sorted by start time. Stretches of different speakers can overlap.
	public var segments: [SpeakerSegment] {
		var segments = [SpeakerSegment]()
		for speaker in 0..<Self.maximumNumberOfSpeakers {
			let bit = UInt8(1) << speaker
			var start: Int?
			for (frame, bits) in frames.enumerated() {
				if bits & bit != 0 {
					if start == nil {
						start = frame
					}
				} else if let segmentStart = start {
					segments.append(SpeakerSegment(speaker: speaker, startFrame: segmentStart, endFrame: frame))
					start = nil
				}
			}
			if let segmentStart = start {
				segments.append(SpeakerSegment(speaker: speaker, startFrame: segmentStart, endFrame: frames.count))
			}
		}
		return segments.sorted { ($0.startTime, $0.endTime, $0.speaker) < ($1.startTime, $1.endTime, $1.speaker) }
	}

	/// For each speaker active between `startTime` and `endTime`, the number of 10 ms frames they’re active in.
	/// A span shorter than a frame counts the frame it falls in.
	public func activeFrameCounts(from startTime: TimeInterval, to endTime: TimeInterval) -> [Int: Int] {
		guard !frames.isEmpty else {
			return [:]
		}
		var first = Int((startTime / Self.frameDuration).rounded(.down))
		var last = Int((endTime / Self.frameDuration).rounded(.up))
		first = min(max(first, 0), frames.count - 1)
		last = min(max(last, first + 1), frames.count)

		var counts = [Int: Int]()
		for bits in frames[first..<last] where bits != 0 {
			for speaker in 0..<Self.maximumNumberOfSpeakers where bits & (1 << speaker) != 0 {
				counts[speaker, default: 0] += 1
			}
		}
		return counts
	}
}

public struct SpeakerSegment: Hashable, Sendable {

	public let speaker: Int
	public let startTime: TimeInterval
	public let endTime: TimeInterval

	public init(speaker: Int, startTime: TimeInterval, endTime: TimeInterval) {
		self.speaker = speaker
		self.startTime = startTime
		self.endTime = endTime
	}

	init(speaker: Int, startFrame: Int, endFrame: Int) {
		self.init(speaker: speaker, startTime: Double(startFrame) * SpeakerActivity.frameDuration, endTime: Double(endFrame) * SpeakerActivity.frameDuration)
	}
}
