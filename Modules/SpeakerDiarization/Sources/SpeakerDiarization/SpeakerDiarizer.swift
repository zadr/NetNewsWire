//
//  SpeakerDiarizer.swift
//  SpeakerDiarization
//

import Foundation
import CoreML

/// Finds who speaks when in an audio file, on device, with a Core ML conversion of
/// NVIDIA’s Nemotron 3 Diarization (up to 8 speakers, overlapping speech included).
///
/// The model and its data files are made at build time (see `Conversion/README.md`) and live in a
/// `NemotronDiarization` folder: `NemotronDiarizer.mlmodelc`, `mel_filters_128x257.f32`,
/// `silence_embeds_512.f32` and `NemotronDiarization.json`, which records the upstream revision.
public final class SpeakerDiarizer: Sendable {

	public static let resourcesFolderName = "NemotronDiarization"

	/// Where the model came from, from `NemotronDiarization.json`.
	public struct ModelInfo: Codable, Hashable, Sendable {
		public let repository: String
		/// The Hugging Face commit the model was converted from.
		public let revision: String
		public let modelSHA256: String
		public let convertedAt: String
	}

	public let modelInfo: ModelInfo

	private let model: SendableModel
	private let melFilters: [Float]
	private let silenceEmbeds: [Float]

	/// Loads the model, which can take several seconds the first time on the Neural Engine. Call it off the main thread.
	public init(resourcesURL: URL, computeUnits: MLComputeUnits = .all) throws {
		modelInfo = try JSONDecoder().decode(ModelInfo.self, from: Self.data(of: "\(Self.resourcesFolderName).json", in: resourcesURL))
		melFilters = try Self.floats(of: "mel_filters_128x257.f32", in: resourcesURL, count: LogMelExtractor.numberOfMels * LogMelExtractor.numberOfBins)
		silenceEmbeds = try Self.floats(of: "silence_embeds_512.f32", in: resourcesURL, count: DiarizationModel.hiddenSize)

		let configuration = MLModelConfiguration()
		configuration.computeUnits = computeUnits
		let modelURL = resourcesURL.appending(path: "\(DiarizationModel.modelName).mlmodelc", directoryHint: .isDirectory)
		do {
			model = SendableModel(try MLModel(contentsOf: modelURL, configuration: configuration))
		} catch {
			throw SpeakerDiarizationError.modelLoadingFailed(error)
		}
	}

	/// The resources folder in `bundle`, if the build put it there.
	public static func bundledResourcesURL(in bundle: Bundle = .main) -> URL? {
		guard let url = bundle.url(forResource: resourcesFolderName, withExtension: nil),
			  FileManager.default.fileExists(atPath: url.appending(path: "\(DiarizationModel.modelName).mlmodelc").path) else {
			return nil
		}
		return url
	}

	/// Decodes the file (any format AVFoundation reads), resampling to 16 kHz mono, and diarizes it.
	@concurrent public func diarize(fileURL: URL) async throws -> SpeakerActivity {
		let diarization = try makeDiarization()
		try AudioDecoder.decode(fileURL: fileURL) { samples in
			try diarization.append(samples)
		}
		guard diarization.sampleCount > 0 else {
			throw SpeakerDiarizationError.noAudio
		}
		let (logits, validFrameCount) = try diarization.finish()
		return SpeakerActivity(logits: logits, validFrameCount: validFrameCount)
	}
}

extension SpeakerDiarizer {

	/// Logits per 10 ms frame and speaker for 16 kHz mono samples, and the number of valid frames.
	func logits(samples: [Float]) throws -> (logits: [Float], validFrameCount: Int) {
		let diarization = try makeDiarization()
		try samples.withUnsafeBufferPointer { pointer in
			try diarization.append(pointer)
		}
		return try diarization.finish()
	}

	func makeDiarization() throws -> OfflineDiarization {
		OfflineDiarization(model: try DiarizationModel(model: model.model), melFilters: melFilters, silenceEmbeds: silenceEmbeds)
	}
}

public enum SpeakerDiarizationError: Error, CustomStringConvertible {

	case missingResource(String)
	case invalidResource(String)
	case modelLoadingFailed(Error)
	case unexpectedModelOutput(String)
	case unreadableAudio(Error?)
	case noAudio

	public var description: String {
		switch self {
		case .missingResource(let name):
			return "Speaker diarization resource missing: \(name)"
		case .invalidResource(let name):
			return "Speaker diarization resource invalid: \(name)"
		case .modelLoadingFailed(let error):
			return "Speaker diarization model failed to load: \(error)"
		case .unexpectedModelOutput(let name):
			return "Speaker diarization model output unexpected: \(name)"
		case .unreadableAudio(let error):
			return "Audio unreadable for speaker diarization: \(error.map { "\($0)" } ?? "unsupported format")"
		case .noAudio:
			return "No audio to diarize"
		}
	}
}

private extension SpeakerDiarizer {

	static func data(of name: String, in folderURL: URL) throws -> Data {
		do {
			return try Data(contentsOf: folderURL.appending(path: name))
		} catch {
			throw SpeakerDiarizationError.missingResource(name)
		}
	}

	/// Little-endian float32 values.
	static func floats(of name: String, in folderURL: URL, count: Int) throws -> [Float] {
		let data = try data(of: name, in: folderURL)
		guard data.count == count * MemoryLayout<Float>.size else {
			throw SpeakerDiarizationError.invalidResource(name)
		}
		return data.withUnsafeBytes { bytes in
			(0..<count).map { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
		}
	}
}

/// `MLModel` predictions are thread-safe; each diarization makes its own input buffers.
private struct SendableModel: @unchecked Sendable {

	let model: MLModel

	init(_ model: MLModel) {
		self.model = model
	}
}
