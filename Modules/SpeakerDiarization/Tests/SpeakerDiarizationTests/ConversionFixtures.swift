//
//  ConversionFixtures.swift
//  SpeakerDiarizationTests
//

import Foundation
@testable import SpeakerDiarization

/// The output of the latest model build (`Conversion/build-model.sh`): the model resources, and reference outputs
/// that the parity gate computed with the conversion’s Python environment for its reference clip.
///
/// Looked up in `$NNW_MODEL_BUILD_CACHE/current`, by default `~/Library/Caches/NetNewsWire-ModelBuild/current`.
/// Tests that need it are skipped until the app (or `build-model.sh`) has been built once.
struct ConversionFixtures {

	struct Info: Decodable {
		let numFrames: Int
		let numMels: Int
		let numSpeakers: Int
		let maxDER: Double
		let minPearson: Double
		let maxFeatureDiff: Double
	}

	static let folderURL: URL = {
		if let cache = ProcessInfo.processInfo.environment["NNW_MODEL_BUILD_CACHE"] {
			return URL(filePath: cache, directoryHint: .isDirectory).appending(path: "current")
		}
		return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/NetNewsWire-ModelBuild/current")
	}()

	static var isAvailable: Bool {
		FileManager.default.fileExists(atPath: folderURL.appending(path: "fixtures/fixtures.json").path)
	}

	static var resourcesURL: URL {
		folderURL.appending(path: SpeakerDiarizer.resourcesFolderName)
	}

	static var clipURL: URL {
		folderURL.appending(path: "fixtures/reference_clip.wav")
	}

	static func info() throws -> Info {
		try JSONDecoder().decode(Info.self, from: Data(contentsOf: folderURL.appending(path: "fixtures/fixtures.json")))
	}

	/// Little-endian float32 file.
	static func floats(_ name: String) throws -> [Float] {
		let data = try Data(contentsOf: folderURL.appending(path: "fixtures/\(name)"))
		return data.withUnsafeBytes { bytes in
			(0..<(data.count / 4)).map { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
		}
	}

	static func melFilters() throws -> [Float] {
		let data = try Data(contentsOf: resourcesURL.appending(path: "mel_filters_128x257.f32"))
		return data.withUnsafeBytes { bytes in
			(0..<(data.count / 4)).map { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
		}
	}

	static func decodedSamples(_ url: URL) throws -> [Float] {
		var samples = [Float]()
		try AudioDecoder.decode(fileURL: url) { block in
			samples.append(contentsOf: block)
		}
		return samples
	}
}

/// Frame-level diarization error rate between two activity matrices with the same speaker labels: no collar,
/// overlap scored, (missed + false alarm + confusion) / reference speech. As `frame_der` in the conversion scripts.
func frameDER(reference: [Float], hypothesis: [Float], speakers: Int, validFrames: Int) -> Double {
	var total = 0
	var errors = 0
	for frame in 0..<validFrames {
		var referenceCount = 0
		var hypothesisCount = 0
		var correct = 0
		for speaker in 0..<speakers {
			let r = reference[frame * speakers + speaker] > 0.5
			let h = hypothesis[frame * speakers + speaker] > 0.5
			referenceCount += r ? 1 : 0
			hypothesisCount += h ? 1 : 0
			correct += r && h ? 1 : 0
		}
		total += referenceCount
		errors += max(referenceCount - hypothesisCount, 0) + max(hypothesisCount - referenceCount, 0) + (min(referenceCount, hypothesisCount) - correct)
	}
	return Double(errors) / Double(max(total, 1))
}

func pearson(_ a: [Float], _ b: [Float]) -> Double {
	let n = Double(a.count)
	let meanA = a.reduce(0.0) { $0 + Double($1) } / n
	let meanB = b.reduce(0.0) { $0 + Double($1) } / n
	var covariance = 0.0
	var varianceA = 0.0
	var varianceB = 0.0
	for (x, y) in zip(a, b) {
		let dx = Double(x) - meanA
		let dy = Double(y) - meanB
		covariance += dx * dy
		varianceA += dx * dx
		varianceB += dy * dy
	}
	return covariance / (varianceA * varianceB).squareRoot()
}

func sigmoid(_ logits: [Float]) -> [Float] {
	logits.map { Float(1 / (1 + exp(-Double($0)))) }
}
