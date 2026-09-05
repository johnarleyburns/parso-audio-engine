// swift-tools-version: 6.0
import PackageDescription

// Host-side developer tool, kept in its own package on purpose.
//
// It is a command-line executable, and watchOS has no CLI executables to link, so
// while it lived in the root package `xcodebuild -scheme parso-audio-engine-Package`
// could never succeed for a watch destination. Conditioning the manifest cannot fix
// that: Package.swift is evaluated on the host, not the destination. Splitting the
// package leaves the root holding only libraries, so its scheme builds everywhere
// (docs/UNIFICATION_PLAN.md §4c).
//
//   swift run --package-path Tools/AcceptanceArtifacts ParsoAcceptanceArtifacts ...
let package = Package(
    name: "AcceptanceArtifacts",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "ParsoAcceptanceArtifacts",
            dependencies: [
                .product(name: "ParsoAudioCore", package: "parso-audio-engine"),
                .product(name: "ParsoAudioAnalysis", package: "parso-audio-engine"),
                .product(name: "ParsoDJEngine", package: "parso-audio-engine"),
            ]
        ),
        // Phase 7b/7c human-listening acceptance: real stem separation and
        // real CLAP semantic search over Wikimedia Commons fixtures, run
        // against caller-supplied `.mlpackage` weights (never shipped).
        .executableTarget(
            name: "ParsoStemsAcceptance",
            dependencies: [
                .product(name: "ParsoAudioCore", package: "parso-audio-engine"),
                .product(name: "ParsoAudioNeural", package: "parso-audio-engine"),
            ]
        ),
        .executableTarget(
            name: "ParsoClapAcceptance",
            dependencies: [
                .product(name: "ParsoAudioCore", package: "parso-audio-engine"),
                .product(name: "ParsoAudioAnalysis", package: "parso-audio-engine"),
                .product(name: "ParsoAudioNeural", package: "parso-audio-engine"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
