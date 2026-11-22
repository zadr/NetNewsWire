//
//  DiarizationModel.swift
//  SpeakerDiarization
//

import Foundation
import CoreML

/// One chunk step of the converted Nemotron 3 Diarization model, with fixed shapes.
///
/// Inputs: `prefix_embeds` (1, 304, 512) speaker cache then FIFO, right-aligned; `chunk_features` (1, 3040, 128)
/// log-mel of the chunk and its look-ahead, left-aligned; `mask` and `window_mask` (1, 684), 1 for valid slots.
/// Outputs: `chunk_embeds` (1, 380, 512), `frame_probs` (1, 684, 8) and `chunk_logits` (1, 3040, 8).
final class DiarizationModel {

	static let modelName = "NemotronDiarizer"
	static let prefixSlots = 304
	static let chunkSlots = 380
	static let slots = prefixSlots + chunkSlots
	static let hiddenSize = 512
	static let numberOfSpeakers = 8
	static let subsampling = 8
	static let numberOfMels = LogMelExtractor.numberOfMels

	struct Output {
		/// `chunkSlots` × `hiddenSize`.
		var chunkEmbeds: [Float]
		/// `slots` × `numberOfSpeakers`.
		var frameProbabilities: [Float]
		/// `chunkSlots · subsampling` × `numberOfSpeakers`.
		var chunkLogits: [Float]
	}

	private let model: MLModel
	private let prefixEmbeds: MLMultiArray
	private let chunkFeatures: MLMultiArray
	private let mask: MLMultiArray
	private let windowMask: MLMultiArray
	private let inputs: MLDictionaryFeatureProvider

	init(model: MLModel) throws {
		self.model = model
		prefixEmbeds = try MLMultiArray(shape: [1, Self.prefixSlots, Self.hiddenSize] as [NSNumber], dataType: .float32)
		chunkFeatures = try MLMultiArray(shape: [1, Self.chunkSlots * Self.subsampling, Self.numberOfMels] as [NSNumber], dataType: .float32)
		mask = try MLMultiArray(shape: [1, Self.slots] as [NSNumber], dataType: .float32)
		windowMask = try MLMultiArray(shape: [1, Self.slots] as [NSNumber], dataType: .float32)
		inputs = try MLDictionaryFeatureProvider(dictionary: [
			"prefix_embeds": MLFeatureValue(multiArray: prefixEmbeds),
			"chunk_features": MLFeatureValue(multiArray: chunkFeatures),
			"mask": MLFeatureValue(multiArray: mask),
			"window_mask": MLFeatureValue(multiArray: windowMask)
		])
	}

	/// - Parameters:
	///   - prefix: cache then FIFO embeddings, at most `prefixSlots` frames.
	///   - features: log-mel frames of the chunk and its look-ahead, at most `chunkSlots · subsampling` frames.
	///   - chunkMask: for each encoder frame of the chunk and look-ahead: 1 when valid, 0 when masked.
	func predict(prefix: [Float], features: ArraySlice<Float>, chunkMask: [Float]) throws -> Output {
		let prefixCount = prefix.count / Self.hiddenSize
		let windowCount = chunkMask.count
		precondition(prefixCount <= Self.prefixSlots && windowCount <= Self.chunkSlots)
		precondition(features.count <= Self.chunkSlots * Self.subsampling * Self.numberOfMels)

		Self.fill(prefixEmbeds) { values in
			values.update(repeating: 0)
			let start = (Self.prefixSlots - prefixCount) * Self.hiddenSize
			_ = UnsafeMutableBufferPointer(rebasing: values[start...]).update(fromContentsOf: prefix)
		}
		Self.fill(chunkFeatures) { values in
			values.update(repeating: 0)
			_ = values.update(fromContentsOf: features)
		}
		Self.fill(mask) { values in
			values.update(repeating: 0)
			for slot in (Self.prefixSlots - prefixCount)..<Self.prefixSlots {
				values[slot] = 1
			}
			for (i, value) in chunkMask.enumerated() {
				values[Self.prefixSlots + i] = value
			}
		}
		Self.fill(windowMask) { values in
			values.update(repeating: 0)
			for slot in (Self.prefixSlots - prefixCount)..<(Self.prefixSlots + windowCount) {
				values[slot] = 1
			}
		}

		let output = try model.prediction(from: inputs)
		return Output(
			chunkEmbeds: try Self.values(of: "chunk_embeds", in: output, rows: Self.chunkSlots, columns: Self.hiddenSize),
			frameProbabilities: try Self.values(of: "frame_probs", in: output, rows: Self.slots, columns: Self.numberOfSpeakers),
			chunkLogits: try Self.values(of: "chunk_logits", in: output, rows: Self.chunkSlots * Self.subsampling, columns: Self.numberOfSpeakers)
		)
	}
}

private extension DiarizationModel {

	/// Inputs are created contiguous, so they can be filled as flat buffers.
	static func fill(_ array: MLMultiArray, _ body: (UnsafeMutableBufferPointer<Float>) -> Void) {
		array.withUnsafeMutableBufferPointer(ofType: Float.self) { pointer, _ in
			body(pointer)
		}
	}

	/// A (1, rows, columns) float32 output as a row-major array, whatever its strides.
	static func values(of name: String, in output: MLFeatureProvider, rows: Int, columns: Int) throws -> [Float] {
		guard let array = output.featureValue(for: name)?.multiArrayValue, array.dataType == .float32, array.shape.count == 3, array.shape[1].intValue == rows, array.shape[2].intValue == columns else {
			throw SpeakerDiarizationError.unexpectedModelOutput(name)
		}
		let rowStride = array.strides[1].intValue
		let columnStride = array.strides[2].intValue
		var values = [Float](repeating: 0, count: rows * columns)
		array.withUnsafeBufferPointer(ofType: Float.self) { pointer in
			if rowStride == columns && columnStride == 1 {
				_ = values.withUnsafeMutableBufferPointer { $0.update(fromContentsOf: pointer.prefix(rows * columns)) }
				return
			}
			for row in 0..<rows {
				for column in 0..<columns {
					values[row * columns + column] = pointer[row * rowStride + column * columnStride]
				}
			}
		}
		return values
	}
}
