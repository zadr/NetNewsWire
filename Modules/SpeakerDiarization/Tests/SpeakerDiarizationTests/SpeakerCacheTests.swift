//
//  SpeakerCacheTests.swift
//  SpeakerDiarizationTests
//

import Foundation
import Testing
@testable import SpeakerDiarization

@Suite struct SpeakerCacheTests {

	@Test func topIndicesBreakTiesByLowestIndex() {
		let values: [Float] = [1, 3, 3, -.infinity, 3, .infinity, 2, -.infinity]
		#expect(SpeakerCache.topIndices(values, count: 5) == [5, 1, 2, 4, 6])
		#expect(SpeakerCache.topIndices(values, count: 8) == [5, 1, 2, 4, 6, 0, 3, 7])
	}

	@Test func constantsMatchTheOfficialConfiguration() {
		#expect(SpeakerCache.speakerBudget == 32)
		#expect(SpeakerCache.minimumPositiveScores == 16)
		#expect(SpeakerCache.strongBoostCount == 24)
		#expect(SpeakerCache.weakBoostCount == 48)
	}

	@Test func nonSpeechScoresNegativeInfinity() {
		var probabilities = [Float](repeating: 0.01, count: 8)
		probabilities[2] = 0.9
		let scores = SpeakerCache.scores(probabilities: probabilities)

		#expect(scores[2] > 0)
		#expect(scores.enumerated().allSatisfy { $0.offset == 2 || $0.element == -.infinity })
	}

	/// The first chunk fills the FIFO and pushes 300 frames into the cache, which is compressed to 264,
	/// with a silence frame for each speaker.
	@Test func firstChunkCompressesCacheWithSilenceFrames() {
		let hidden = DiarizationModel.hiddenSize
		let silence = [Float](repeating: -1, count: hidden)
		var cache = SpeakerCache(silenceEmbeds: silence)
		let chunkCount = 340
		let embeds = (0..<(chunkCount * hidden)).map { Float($0 / hidden) }
		// Speaker 0 for the first half, speaker 1 for the second.
		var probabilities = [Float](repeating: 0, count: (chunkCount + 40) * 8)
		for frame in 0..<(chunkCount + 40) {
			probabilities[frame * 8 + (frame < 170 ? 0 : 1)] = 0.9
		}

		cache.update(chunkEmbeds: embeds[...], stepProbabilities: probabilities)

		#expect(cache.fifoFrameCount == 40)
		#expect(cache.fifoEmbeds.first == 300)
		#expect(cache.cacheFrameCount == SpeakerCache.cacheLength)
		let silenceFrames = (0..<cache.cacheFrameCount).filter { cache.cacheEmbeds[$0 * hidden] == -1 }
		#expect(silenceFrames.count == 8)
		let keptFrames = (0..<cache.cacheFrameCount).map { cache.cacheEmbeds[$0 * hidden] }.filter { $0 >= 0 }
		#expect(keptFrames.contains { $0 < 170 } && keptFrames.contains { $0 >= 170 })
	}
}
