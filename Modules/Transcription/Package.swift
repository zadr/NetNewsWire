// swift-tools-version:6.2
import PackageDescription

let package = Package(
	name: "Transcription",
	platforms: [.macOS(.v15), .iOS(.v18)],
	products: [
		.library(
			name: "Transcription",
			type: .dynamic,
			targets: ["Transcription"])
	],
	dependencies: [
		.package(path: "../RSCore"),
		.package(path: "../SpeakerDiarization")
	],
	targets: [
		.target(
			name: "Transcription",
			dependencies: [
				"RSCore",
				"SpeakerDiarization"
			],
			swiftSettings: [
				.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
				.enableUpcomingFeature("InferIsolatedConformances"),
				.unsafeFlags(["-warnings-as-errors"])
			]
		),
		.testTarget(
			name: "TranscriptionTests",
			dependencies: ["Transcription"],
			swiftSettings: [
				.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
				.enableUpcomingFeature("InferIsolatedConformances")
			]
		)
	]
)
