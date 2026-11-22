//
//  OfflineDiarization.swift
//  SpeakerDiarization
//

import Foundation

/// The official offline chunk loop, fed audio as it’s decoded.
///
/// Chunks are 340 encoder frames (27.2 s) with 40 frames of look-ahead. A chunk runs as soon as its look-ahead
/// has been decoded, or at the end of the audio, so only about one chunk of features is kept in memory.
final class OfflineDiarization {

	static let chunkLength = 340
	static let rightContext = 40

	private static let mels = LogMelExtractor.numberOfMels
	private static let subsampling = DiarizationModel.subsampling
	private static let speakers = DiarizationModel.numberOfSpeakers

	private let model: DiarizationModel
	private let extractor: LogMelExtractor
	private var cache: SpeakerCache

	/// Log-mel features from mel frame `featuresOffset` on.
	private var features = [Float]()
	private var featuresOffset = 0
	/// Encoder frame where the next chunk starts.
	private var chunkStart = 0
	/// Per mel frame and speaker.
	private var logits = [Float]()

	init(model: DiarizationModel, melFilters: [Float], silenceEmbeds: [Float]) {
		self.model = model
		self.extractor = LogMelExtractor(melFilters: melFilters)
		self.cache = SpeakerCache(silenceEmbeds: silenceEmbeds)
	}

	var sampleCount: Int {
		extractor.sampleCount
	}

	func append(_ samples: UnsafeBufferPointer<Float>) throws {
		extractor.append(samples, to: &features)
		// Before the end of the audio, every frame computed so far is valid: the last (masked) one comes at the end.
		while extractor.frameCount >= (chunkStart + Self.chunkLength + Self.rightContext) * Self.subsampling {
			try runChunk(encoderFrameCount: nil, validMelFrames: nil)
		}
	}

	/// Runs the remaining chunks. Returns logits, `numberOfSpeakers` per mel frame, and the number of valid mel frames.
	func finish() throws -> (logits: [Float], validFrameCount: Int) {
		let validFrames = extractor.finish(features: &features)
		let melFrames = extractor.frameCount
		let encoderFrames = (melFrames + Self.subsampling - 1) / Self.subsampling
		while chunkStart < encoderFrames {
			try runChunk(encoderFrameCount: encoderFrames, validMelFrames: validFrames)
		}
		return (Array(logits.prefix(melFrames * Self.speakers)), validFrames)
	}
}

private extension OfflineDiarization {

	/// `encoderFrameCount` and `validMelFrames` are nil until the end of the audio is known.
	func runChunk(encoderFrameCount: Int?, validMelFrames: Int?) throws {
		try Task.checkCancellation()

		let start = chunkStart
		let end = min(start + Self.chunkLength, encoderFrameCount ?? .max)
		let chunkCount = end - start
		let windowEnd = min(end + Self.rightContext, encoderFrameCount ?? .max)
		let windowCount = windowEnd - start

		// Features are zero-padded past the end, to a whole number of encoder frames.
		let featureStart = (start * Self.subsampling - featuresOffset) * Self.mels
		let featureEnd = min((windowEnd * Self.subsampling - featuresOffset) * Self.mels, features.count)
		// An encoder frame is valid when its first mel frame is.
		let chunkMask = (start..<windowEnd).map { frame -> Float in
			guard let validMelFrames else {
				return 1
			}
			return frame * Self.subsampling < validMelFrames ? 1 : 0
		}

		let prefix = cache.prefixEmbeds
		let prefixCount = prefix.count / DiarizationModel.hiddenSize
		let output = try model.predict(prefix: prefix, features: features[featureStart..<featureEnd], chunkMask: chunkMask)

		let speakers = Self.speakers
		let prefixStart = (DiarizationModel.prefixSlots - prefixCount) * speakers
		let windowStart = DiarizationModel.prefixSlots * speakers
		let stepProbabilities = Array(output.frameProbabilities[prefixStart..<windowStart]) + output.frameProbabilities[windowStart..<(windowStart + windowCount * speakers)]
		cache.update(chunkEmbeds: output.chunkEmbeds[0..<(chunkCount * DiarizationModel.hiddenSize)], stepProbabilities: stepProbabilities)
		logits += output.chunkLogits[0..<(chunkCount * Self.subsampling * speakers)]

		chunkStart = end
		let usedMelFrames = min(chunkStart * Self.subsampling - featuresOffset, features.count / Self.mels)
		features.removeFirst(usedMelFrames * Self.mels)
		featuresOffset += usedMelFrames
	}
}
