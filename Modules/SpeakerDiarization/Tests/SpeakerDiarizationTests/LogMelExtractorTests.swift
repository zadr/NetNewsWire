//
//  LogMelExtractorTests.swift
//  SpeakerDiarizationTests
//

import Foundation
import Testing
@testable import SpeakerDiarization

@Suite struct LogMelExtractorTests {

	@Test func frameCountAndLastFrameMask() {
		let samples = testSignal(count: 16_000 + 77)
		let (features, validFrames) = extract(samples, pieceSizes: [samples.count])

		#expect(features.count == (samples.count / 160 + 1) * 128)
		#expect(validFrames == samples.count / 160)
		#expect(features.suffix(128).allSatisfy { $0 == 0 })
		#expect(features[(validFrames - 1) * 128..<validFrames * 128].contains { $0 != 0 })
	}

	/// Up to rounding: the mel matrix product is done in batches of frames, which can round differently.
	@Test func piecesGiveTheSameFeaturesAsWholeAudio() {
		let samples = testSignal(count: 40_000)
		let whole = extract(samples, pieceSizes: [samples.count])
		let pieces = extract(samples, pieceSizes: [1, 159, 513, 4_000, 77, 70_000])

		#expect(whole.features.count == pieces.features.count)
		let maximumDifference = zip(whole.features, pieces.features).map { abs($0 - $1) }.max() ?? 0
		#expect(maximumDifference < 1e-5)
		#expect(whole.validFrames == pieces.validFrames)
	}

	/// The vDSP spectrum against a direct DFT, through an identity "filter bank" over the first 128 bins.
	@Test func powerSpectrumMatchesDirectDFT() {
		var identity = [Float](repeating: 0, count: 128 * 257)
		for bin in 0..<128 {
			identity[bin * 257 + bin] = 1
		}
		let samples = testSignal(count: 2_000)
		let (features, _) = extract(samples, pieceSizes: [samples.count], melFilters: identity)

		let frame = 5
		var emphasized = [Double](repeating: 0, count: samples.count)
		for i in samples.indices {
			emphasized[i] = Double(samples[i]) - (i > 0 ? 0.97 * Double(samples[i - 1]) : 0)
		}
		for bin in [0, 1, 17, 64, 127] {
			var real = 0.0
			var imaginary = 0.0
			for n in 0..<512 {
				let index = frame * 160 + n - 256
				guard (56..<456).contains(n), emphasized.indices.contains(index) else {
					continue
				}
				let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(n - 56) / 399)
				let angle = -2 * Double.pi * Double(bin * n) / 512
				real += emphasized[index] * window * cos(angle)
				imaginary += emphasized[index] * window * sin(angle)
			}
			let expected = log(real * real + imaginary * imaginary + pow(2, -24))
			#expect(abs(Double(features[frame * 128 + bin]) - expected) < 1e-3, "bin \(bin)")
		}
	}

	/// Swift against the conversion’s NumPy front-end (itself checked against NVIDIA’s processor) on the reference clip.
	@Test(.enabled(if: ConversionFixtures.isAvailable, "Needs a model build; run Conversion/build-model.sh"))
	func matchesPythonFrontEndOnReferenceClip() throws {
		let info = try ConversionFixtures.info()
		let expected = try ConversionFixtures.floats("log_mel.f32")
		let expectedMask = try ConversionFixtures.floats("mel_mask.f32")
		let samples = try ConversionFixtures.decodedSamples(ConversionFixtures.clipURL)
		let (features, validFrames) = extract(samples, pieceSizes: [65_536], melFilters: try ConversionFixtures.melFilters())

		#expect(features.count == info.numFrames * info.numMels)
		#expect(validFrames == expectedMask.count { $0 > 0 })
		let differences = zip(features, expected).map { abs(Double($0) - Double($1)) }
		let maximum = differences.max() ?? .infinity
		let mean = differences.reduce(0, +) / Double(differences.count)
		print("log-mel vs Python: max |diff| \(maximum), mean |diff| \(mean)")
		#expect(maximum <= info.maxFeatureDiff)
	}
}

private extension LogMelExtractorTests {

	func testSignal(count: Int) -> [Float] {
		(0..<count).map { i in
			let t = Float(i) / 16_000
			return 0.3 * sin(2 * .pi * 440 * t) + 0.1 * sin(2 * .pi * 1_234 * t + 0.5) + 0.05 * sin(Float(i % 97))
		}
	}

	func extract(_ samples: [Float], pieceSizes: [Int], melFilters: [Float]? = nil) -> (features: [Float], validFrames: Int) {
		let filters = melFilters ?? (0..<(128 * 257)).map { Float(($0 * 7919) % 101) / 1_000 }
		let extractor = LogMelExtractor(melFilters: filters)
		var features = [Float]()
		var offset = 0
		var pieceIndex = 0
		while offset < samples.count {
			let size = min(pieceSizes[pieceIndex % pieceSizes.count], samples.count - offset)
			samples[offset..<(offset + size)].withUnsafeBufferPointer { extractor.append($0, to: &features) }
			offset += size
			pieceIndex += 1
		}
		let validFrames = extractor.finish(features: &features)
		return (features, validFrames)
	}
}
