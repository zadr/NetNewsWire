//
//  SpeakerDiarizerTests.swift
//  SpeakerDiarizationTests
//

import Foundation
import Testing
@testable import SpeakerDiarization

@Suite(.serialized, .enabled(if: ConversionFixtures.isAvailable, "Needs a model build; run Conversion/build-model.sh"))
struct SpeakerDiarizerTests {

	/// The Swift pipeline against NVIDIA’s PyTorch pipeline and the Python Core ML port, on the parity gate’s clip,
	/// with the parity gate’s thresholds.
	@Test func matchesReferenceOnReferenceClip() async throws {
		let info = try ConversionFixtures.info()
		let referenceProbabilities = try ConversionFixtures.floats("reference_probs.f32")
		let pythonProbabilities = try ConversionFixtures.floats("coreml_probs.f32")
		let validFrames = try ConversionFixtures.floats("mel_mask.f32").count { $0 > 0 }

		let diarizer = try SpeakerDiarizer(resourcesURL: ConversionFixtures.resourcesURL)
		let samples = try ConversionFixtures.decodedSamples(ConversionFixtures.clipURL)
		let (logits, validFrameCount) = try diarizer.logits(samples: samples)
		let probabilities = sigmoid(logits)

		#expect(validFrameCount == validFrames)
		#expect(probabilities.count == info.numFrames * info.numSpeakers)

		let valid = validFrames * info.numSpeakers
		for (name, expected) in [("PyTorch", referenceProbabilities), ("Python Core ML", pythonProbabilities)] {
			let der = frameDER(reference: expected, hypothesis: probabilities, speakers: info.numSpeakers, validFrames: validFrames)
			let correlation = pearson(Array(probabilities.prefix(valid)), Array(expected.prefix(valid)))
			let maximumDifference = zip(probabilities.prefix(valid), expected.prefix(valid)).map { abs($0 - $1) }.max() ?? 0
			print("Swift vs \(name): DER \(String(format: "%.3f", der * 100))%, Pearson r \(String(format: "%.6f", correlation)), max |dp| \(String(format: "%.3f", maximumDifference))")
			#expect(der <= info.maxDER, "\(name)")
			#expect(correlation >= info.minPearson, "\(name)")
		}
	}

	@Test func diarizesFileIntoSpeakerSegments() async throws {
		let diarizer = try SpeakerDiarizer(resourcesURL: ConversionFixtures.resourcesURL)
		let activity = try await diarizer.diarize(fileURL: ConversionFixtures.clipURL)

		#expect(diarizer.modelInfo.repository == "nvidia/Nemotron-3-Diarization")
		#expect(diarizer.modelInfo.revision.count == 40)
		// Three voices, two of them overlapping for a moment.
		#expect(activity.speakers == [0, 1, 2])
		#expect(activity.frames.contains { $0.nonzeroBitCount > 1 })
		let segments = activity.segments
		#expect(segments.first?.speaker == 0)
		#expect(segments.allSatisfy { $0.endTime > $0.startTime })
	}

	@Test func missingResourcesThrow() {
		#expect(throws: SpeakerDiarizationError.self) {
			try SpeakerDiarizer(resourcesURL: URL(filePath: "/nonexistent", directoryHint: .isDirectory))
		}
	}

	/// Timing of the whole pipeline (decode, log-mel, chunk loop, Core ML) on a long clip.
	/// Set SPEAKER_DIARIZATION_BENCHMARK_AUDIO to an audio file, for instance one made with
	/// `python -I Conversion/make_clip.py clip.wav --minutes 6`.
	@Test(.enabled(if: ProcessInfo.processInfo.environment["SPEAKER_DIARIZATION_BENCHMARK_AUDIO"] != nil))
	func benchmark() async throws {
		let path = try #require(ProcessInfo.processInfo.environment["SPEAKER_DIARIZATION_BENCHMARK_AUDIO"])
		let url = URL(filePath: path)
		let runs = 5

		let loadStart = ContinuousClock.now
		let diarizer = try SpeakerDiarizer(resourcesURL: ConversionFixtures.resourcesURL)
		let loadTime = ContinuousClock.now - loadStart

		let warmUp = try await diarizer.diarize(fileURL: url)
		var times = [Double]()
		for _ in 0..<runs {
			let start = ContinuousClock.now
			let activity = try await diarizer.diarize(fileURL: url)
			times.append((ContinuousClock.now - start).seconds)
			#expect(activity == warmUp)
		}
		times.sort()
		print(String(format: "benchmark: %.1f s of audio, %d speakers; model load %.2f s; %d runs after warm-up: median %.3f s, min %.3f s, max %.3f s",
					 warmUp.duration, warmUp.speakers.count, loadTime.seconds, runs, times[runs / 2], times[0], times[runs - 1]))
	}
}

private extension Duration {

	var seconds: Double {
		Double(components.seconds) + Double(components.attoseconds) / 1e18
	}
}
