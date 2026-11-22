//
//  LogMelExtractor.swift
//  SpeakerDiarization
//

import Foundation
import Accelerate

/// The model’s front-end: 128 log-mel features every 10 ms from 16 kHz mono audio,
/// as the official `NemotronAsrStreamingFeatureExtractor` computes them offline.
///
/// Pre-emphasis 0.97; 256 samples of zero padding on each side; frame `t` covers padded samples `[160t, 160t + 512)`
/// with a symmetric 400-point Hann window centered in 512 points; power spectrum; Slaney mel filters; natural log
/// with a 2⁻²⁴ guard; no normalization. Audio of `L` samples makes `L / 160 + 1` frames, of which the last is
/// zeroed and masked.
///
/// Audio is appended in pieces, and frames come out as soon as their samples are in, so a long episode
/// never has to be in memory all at once.
final class LogMelExtractor {

	static let sampleRate = 16000.0
	static let hopLength = 160
	static let fftLength = 512
	static let windowLength = 400
	static let numberOfMels = 128
	static let numberOfBins = fftLength / 2 + 1
	static let preemphasis: Float = 0.97
	static let logGuard: Float = 0x1p-24

	private static let padding = fftLength / 2
	private static let framesPerBatch = 256

	/// Number of frames computed so far.
	private(set) var frameCount = 0
	private(set) var sampleCount = 0

	private let melFiltersTransposed: [Float]
	private let window: [Float]
	private let dftSetup: vDSP_DFT_Setup

	/// Pre-emphasized samples, with the leading padding; `paddedSamples[0]` is padded sample `paddedOffset`.
	private var paddedSamples = [Float](repeating: 0, count: LogMelExtractor.padding)
	private var paddedOffset = 0
	private var previousSample: Float?
	private var isFinished = false

	/// `melFilters`: 128 × 257, row-major.
	init(melFilters: [Float]) {
		precondition(melFilters.count == Self.numberOfMels * Self.numberOfBins)
		var transposed = [Float](repeating: 0, count: melFilters.count)
		vDSP_mtrans(melFilters, 1, &transposed, 1, vDSP_Length(Self.numberOfBins), vDSP_Length(Self.numberOfMels))
		melFiltersTransposed = transposed
		window = Self.makeWindow()
		guard let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(Self.fftLength), .FORWARD) else {
			preconditionFailure("vDSP_DFT_zrop_CreateSetup failed for length \(Self.fftLength)")
		}
		dftSetup = setup
	}

	deinit {
		vDSP_DFT_DestroySetup(dftSetup)
	}

	/// Appends audio and adds the features of every frame that is now complete to `features` (128 floats per frame).
	func append(_ samples: UnsafeBufferPointer<Float>, to features: inout [Float]) {
		precondition(!isFinished)
		guard !samples.isEmpty else {
			return
		}
		let start = paddedSamples.count
		paddedSamples.append(contentsOf: samples)
		// y[0] = x[0], y[n] = x[n] − 0.97·x[n−1]
		var previous = previousSample ?? 0
		for i in start..<paddedSamples.count {
			let sample = paddedSamples[i]
			paddedSamples[i] = sample - Self.preemphasis * previous
			previous = sample
		}
		previousSample = previous
		sampleCount += samples.count

		// Frame t needs padded samples up to 160t + 512.
		let availablePaddedSamples = paddedOffset + paddedSamples.count
		let completeFrames = availablePaddedSamples >= Self.fftLength ? (availablePaddedSamples - Self.fftLength) / Self.hopLength + 1 : 0
		computeFrames(upTo: completeFrames, features: &features)
	}

	/// Pads the end of the audio and adds the remaining frames’ features. Returns the number of valid frames
	/// (`L / 160`); the last frame, number `L / 160`, is zeroed.
	func finish(features: inout [Float]) -> Int {
		precondition(!isFinished)
		isFinished = true
		paddedSamples.append(contentsOf: repeatElement(0, count: Self.padding))
		let totalFrames = sampleCount / Self.hopLength + 1
		let firstNewFrame = frameCount
		let featureCountBefore = features.count
		computeFrames(upTo: totalFrames, features: &features)

		let lastFrameStart = featureCountBefore + (totalFrames - 1 - firstNewFrame) * Self.numberOfMels
		if totalFrames - 1 >= firstNewFrame {
			features.replaceSubrange(lastFrameStart..<lastFrameStart + Self.numberOfMels, with: repeatElement(0, count: Self.numberOfMels))
		}
		return totalFrames - 1
	}
}

private extension LogMelExtractor {

	/// Symmetric Hann window of length 400, centered in 512 points with zeros around it, as `torch.stft` does.
	static func makeWindow() -> [Float] {
		var window = [Float](repeating: 0, count: fftLength)
		let left = (fftLength - windowLength) / 2
		for n in 0..<windowLength {
			window[left + n] = Float(0.5 - 0.5 * cos(2.0 * Double.pi * Double(n) / Double(windowLength - 1)))
		}
		return window
	}

	func computeFrames(upTo endFrame: Int, features: inout [Float]) {
		let halfLength = Self.fftLength / 2
		var power = [Float](repeating: 0, count: Self.framesPerBatch * Self.numberOfBins)
		var mel = [Float](repeating: 0, count: Self.framesPerBatch * Self.numberOfMels)
		var evenSamples = [Float](repeating: 0, count: halfLength)
		var oddSamples = [Float](repeating: 0, count: halfLength)
		var real = [Float](repeating: 0, count: halfLength)
		var imaginary = [Float](repeating: 0, count: halfLength)
		var magnitudes = [Float](repeating: 0, count: halfLength)
		let oddWindow = Array(window[1...])

		while frameCount < endFrame {
			let batchCount = min(Self.framesPerBatch, endFrame - frameCount)
			for b in 0..<batchCount {
				// Windowed frame, split into even and odd samples: the real DFT’s input as a half-length complex signal.
				let start = (frameCount + b) * Self.hopLength - paddedOffset
				paddedSamples.withUnsafeBufferPointer { padded in
					guard let frame = padded.baseAddress?.advanced(by: start) else {
						return
					}
					vDSP_vmul(frame, 2, window, 2, &evenSamples, 1, vDSP_Length(halfLength))
					vDSP_vmul(frame + 1, 2, oddWindow, 2, &oddSamples, 1, vDSP_Length(halfLength))
				}
				vDSP_DFT_Execute(dftSetup, evenSamples, oddSamples, &real, &imaginary)

				// vDSP’s real DFT returns twice the transform, with bin 256 (real) packed into imaginary[0].
				let dc = real[0] * 0.5
				let nyquist = imaginary[0] * 0.5
				vDSP_vmma(real, 1, real, 1, imaginary, 1, imaginary, 1, &magnitudes, 1, vDSP_Length(halfLength))
				let row = b * Self.numberOfBins
				for k in 1..<halfLength {
					power[row + k] = magnitudes[k] * 0.25
				}
				power[row] = dc * dc
				power[row + halfLength] = nyquist * nyquist
			}

			vDSP_mmul(power, 1, melFiltersTransposed, 1, &mel, 1, vDSP_Length(batchCount), vDSP_Length(Self.numberOfMels), vDSP_Length(Self.numberOfBins))
			let count = batchCount * Self.numberOfMels
			mel.withUnsafeMutableBufferPointer { melPointer in
				guard let values = melPointer.baseAddress else {
					return
				}
				var logGuard = Self.logGuard
				vDSP_vsadd(values, 1, &logGuard, values, 1, vDSP_Length(count))
				var length = Int32(count)
				vvlogf(values, values, &length)
			}
			features.append(contentsOf: mel[0..<count])
			frameCount += batchCount
		}

		dropUsedSamples()
	}

	/// Drops samples that no future frame needs.
	func dropUsedSamples() {
		let firstNeeded = frameCount * Self.hopLength - paddedOffset
		guard firstNeeded > 1 << 16 else {
			return
		}
		paddedSamples.removeFirst(firstNeeded)
		paddedOffset += firstNeeded
	}
}
