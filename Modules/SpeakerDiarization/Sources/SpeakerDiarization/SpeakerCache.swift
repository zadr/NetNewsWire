//
//  SpeakerCache.swift
//  SpeakerDiarization
//

import Foundation

/// The offline Arrival-Order Speaker Cache and FIFO: the encoder frames each chunk attends to before its own.
///
/// New chunk frames go through the FIFO into the cache. When the cache grows past 264 frames it’s compressed to
/// the frames that best represent each speaker, scored from their probabilities, plus a silence frame per speaker.
/// Ties in the top-k selections are broken by lowest index, so results are deterministic.
struct SpeakerCache {

	static let fifoLength = 40
	static let updatePeriod = 300
	static let cacheLength = 264
	static let silenceFrames = 1
	static let scoreThreshold: Float = 0.25
	static let latestFrameBoost: Float = 0.05
	static let speakerBudget = cacheLength / DiarizationModel.numberOfSpeakers - silenceFrames
	static let minimumPositiveScores = Int((Double(speakerBudget) * 0.5).rounded(.down))
	static let strongBoostCount = Int((Double(speakerBudget) * 0.75).rounded(.down))
	static let weakBoostCount = Int((Double(speakerBudget) * 1.5).rounded(.down))

	private static let hidden = DiarizationModel.hiddenSize
	private static let speakers = DiarizationModel.numberOfSpeakers
	private static let logHalf = Float(log(0.5))
	private static let strongBoost = Float(-2.0 * log(0.5))
	private static let weakBoost = Float(-log(0.5))

	private let silenceEmbeds: [Float]

	/// Row-major, `hiddenSize` floats per frame.
	private(set) var cacheEmbeds = [Float]()
	/// Row-major, `numberOfSpeakers` floats per frame.
	private(set) var cacheProbabilities = [Float]()
	private(set) var fifoEmbeds = [Float]()
	private var isCompressed = false

	init(silenceEmbeds: [Float]) {
		precondition(silenceEmbeds.count == Self.hidden)
		self.silenceEmbeds = silenceEmbeds
	}

	var cacheFrameCount: Int {
		cacheEmbeds.count / Self.hidden
	}

	var fifoFrameCount: Int {
		fifoEmbeds.count / Self.hidden
	}

	/// Cache then FIFO: the prefix of the next chunk’s window.
	var prefixEmbeds: [Float] {
		cacheEmbeds + fifoEmbeds
	}

	/// - Parameters:
	///   - chunkEmbeds: encoder inputs of the chunk’s frames, without its look-ahead.
	///   - stepProbabilities: pooled probabilities of this step’s valid window frames: prefix (cache, FIFO), then chunk.
	mutating func update(chunkEmbeds: ArraySlice<Float>, stepProbabilities: [Float]) {
		let cacheCount = cacheFrameCount
		let fifoCount = fifoFrameCount
		let chunkCount = chunkEmbeds.count / Self.hidden
		var fifo = fifoEmbeds + chunkEmbeds
		let count = fifo.count / Self.hidden
		let popped = count > Self.fifoLength ? min(max(Self.updatePeriod, count - Self.fifoLength), count) : 0

		if popped > 0 {
			let speakers = Self.speakers
			let chunkStart = cacheCount + fifoCount
			let fifoProbabilities = Array(stepProbabilities[(cacheCount * speakers)..<(chunkStart * speakers)]) + stepProbabilities[(chunkStart * speakers)..<((chunkStart + chunkCount) * speakers)]
			let storedProbabilities = isCompressed ? cacheProbabilities : Array(stepProbabilities[0..<(cacheCount * speakers)])
			var embeds = cacheEmbeds + fifo[0..<(popped * Self.hidden)]
			var probabilities = storedProbabilities + fifoProbabilities[0..<(popped * speakers)]
			fifo.removeFirst(popped * Self.hidden)
			if embeds.count / Self.hidden > Self.cacheLength {
				(embeds, probabilities) = compress(embeds: embeds, probabilities: probabilities)
				isCompressed = true
			}
			cacheEmbeds = embeds
			cacheProbabilities = probabilities
		}
		fifoEmbeds = fifo
	}
}

extension SpeakerCache {

	/// Per frame and speaker: how well the frame represents the speaker, or −∞ when it shouldn’t be kept for them.
	static func scores(probabilities: [Float]) -> [Float] {
		let frameCount = probabilities.count / speakers
		var scores = [Float](repeating: 0, count: probabilities.count)
		var isSpeech = [Bool](repeating: false, count: probabilities.count)
		var positiveCounts = [Int](repeating: 0, count: speakers)
		var logComplements = [Float](repeating: 0, count: speakers)

		for frame in 0..<frameCount {
			let row = frame * speakers
			for speaker in 0..<speakers {
				logComplements[speaker] = log(max(1 - probabilities[row + speaker], scoreThreshold))
			}
			// Summed in NumPy’s pairwise order for eight values.
			let complementSum = ((logComplements[0] + logComplements[1]) + (logComplements[2] + logComplements[3])) + ((logComplements[4] + logComplements[5]) + (logComplements[6] + logComplements[7]))
			for speaker in 0..<speakers {
				let probability = probabilities[row + speaker]
				let score = ((log(max(probability, scoreThreshold)) - logComplements[speaker]) + complementSum) - logHalf
				let speech = probability > 0.5
				isSpeech[row + speaker] = speech
				scores[row + speaker] = speech ? score : -.infinity
				if scores[row + speaker] > 0 {
					positiveCounts[speaker] += 1
				}
			}
		}

		// For a speaker with enough positive frames, drop the weak ones.
		for frame in 0..<frameCount {
			for speaker in 0..<speakers where positiveCounts[speaker] >= minimumPositiveScores {
				let i = frame * speakers + speaker
				if !(scores[i] > 0) && isSpeech[i] {
					scores[i] = -.infinity
				}
			}
		}
		return scores
	}

	/// Indices of the `k` largest values, ties broken by lowest index.
	static func topIndices(_ values: [Float], count k: Int) -> [Int] {
		let sorted = values.indices.sorted { a, b in
			values[a] > values[b] || (values[a] == values[b] && a < b)
		}
		return Array(sorted.prefix(k))
	}
}

private extension SpeakerCache {

	func compress(embeds: [Float], probabilities: [Float]) -> ([Float], [Float]) {
		let speakers = Self.speakers
		let frameCount = probabilities.count / speakers
		var scores = Self.scores(probabilities: probabilities)
		for i in (Self.cacheLength * speakers)..<scores.count {
			scores[i] += Self.latestFrameBoost
		}
		Self.boost(&scores, frameCount: frameCount, count: Self.strongBoostCount, by: Self.strongBoost)
		Self.boost(&scores, frameCount: frameCount, count: Self.weakBoostCount, by: Self.weakBoost)

		// Speaker-major, with a silence frame (always picked) after each speaker’s frames.
		let scoredCount = frameCount + Self.silenceFrames
		var flat = [Float](repeating: 0, count: scoredCount * speakers)
		for speaker in 0..<speakers {
			for frame in 0..<frameCount {
				flat[speaker * scoredCount + frame] = scores[frame * speakers + speaker]
			}
			flat[speaker * scoredCount + frameCount] = .infinity
		}

		let sentinel = scoredCount * speakers
		let picks = Self.topIndices(flat, count: Self.cacheLength).map { flat[$0] == -.infinity ? sentinel : $0 }.sorted()

		var selectedEmbeds = [Float]()
		selectedEmbeds.reserveCapacity(Self.cacheLength * Self.hidden)
		var selectedProbabilities = [Float]()
		selectedProbabilities.reserveCapacity(Self.cacheLength * speakers)
		for pick in picks {
			let frame = pick == sentinel ? frameCount : min(pick % scoredCount, frameCount)
			if frame == frameCount {
				selectedEmbeds += silenceEmbeds
				selectedProbabilities += repeatElement(0, count: speakers)
			} else {
				selectedEmbeds += embeds[(frame * Self.hidden)..<((frame + 1) * Self.hidden)]
				selectedProbabilities += probabilities[(frame * speakers)..<((frame + 1) * speakers)]
			}
		}
		return (selectedEmbeds, selectedProbabilities)
	}

	/// Adds `boost` to each speaker’s `count` best frames.
	static func boost(_ scores: inout [Float], frameCount: Int, count: Int, by boost: Float) {
		for speaker in 0..<speakers {
			let column = (0..<frameCount).map { scores[$0 * speakers + speaker] }
			for frame in topIndices(column, count: count) {
				scores[frame * speakers + speaker] += boost
			}
		}
	}
}
