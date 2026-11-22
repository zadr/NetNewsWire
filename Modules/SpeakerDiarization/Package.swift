// swift-tools-version:6.2
import PackageDescription

let package = Package(
	name: "SpeakerDiarization",
	platforms: [.macOS(.v15), .iOS(.v18)],
	products: [
		.library(
			name: "SpeakerDiarization",
			targets: ["SpeakerDiarization"])
	],
	targets: [
		.target(
			name: "SpeakerDiarization",
			swiftSettings: [
				.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
				.enableUpcomingFeature("InferIsolatedConformances"),
				.unsafeFlags(["-warnings-as-errors"])
			]
		),
		.testTarget(
			name: "SpeakerDiarizationTests",
			dependencies: ["SpeakerDiarization"],
			swiftSettings: [
				.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
				.enableUpcomingFeature("InferIsolatedConformances")
			]
		)
	]
)
