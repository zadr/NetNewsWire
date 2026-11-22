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
	targets: [
		.target(
			name: "Transcription",
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
