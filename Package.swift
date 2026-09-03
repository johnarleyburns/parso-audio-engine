// swift-tools-version: 6.0
import PackageDescription

// parso-audio-engine — MIT-licensed, permissive-only software DJ engine
// delivering full DDJ-FLX4 functional equivalence. See docs/SPEC.md.
//
// Apple platforms only (iOS / macCatalyst / macOS / watchOS). Linux support was
// retired in Phase 1b; see docs/UNIFICATION_PLAN.md §4b.
//
// Swift 6 language mode is enabled package-wide (strict concurrency).
// The C/C++ targets vendor real permissive-licensed libraries (sources under
// each Sources/C*/; provenance in the matching VENDOR.md), per docs/SPEC.md §4:
//   Cflac    -> libFLAC 1.4.3 (BSD-3)      https://xiph.org/flac/
//   Cebur128 -> libebur128 (MIT)          https://github.com/jiixyj/libebur128
//   Csrc     -> libsamplerate 0.2.2 (BSD-2) https://github.com/libsndfile/libsamplerate
//   Cvorbis  -> stb_vorbis (Public Domain) https://github.com/nothings/stb   (Ogg Vorbis decode)
//   Copus    -> libogg + libopus + libopusfile (BSD-3)  https://github.com/xiph  (Opus decode)
//   CParsoDSP/vendor/signalsmith -> Signalsmith Stretch (MIT)
//                                          https://github.com/Signalsmith-Audio/signalsmith-stretch
//   CGlint   -> Glint clean-room MP3 encode/decode (AudioToolbox has no MP3 encoder) + AAC-LC

let package = Package(
    name: "parso-audio-engine",
    platforms: [
        .iOS(.v17),
        .macCatalyst(.v17),
        .macOS(.v14),
        .watchOS(.v10)
    ],
    products: [
        .library(name: "ParsoAudioCore",     targets: ["ParsoAudioCore"]),
        .library(name: "ParsoAudioAnalysis", targets: ["ParsoAudioAnalysis"]),
        .library(name: "ParsoAudioPlayback",  targets: ["ParsoAudioPlayback"]),
        .library(name: "ParsoAudioStreaming", targets: ["ParsoAudioStreaming"]),
        .library(name: "ParsoDJEngine",      targets: ["ParsoDJEngine"]),
    ],
    targets: [
        // ── Vendored C libraries (permissive upstream licenses; see VENDOR.md) ──
        .target(
            name: "Cflac",
            path: "Sources/Cflac",
            exclude: ["src/deduplication"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .headerSearchPath("src/include"),
                .define("FLAC__NO_DLL"),
                .define("HAVE_STDINT_H"),
                .define("FLAC__HAS_OGG", to: "0"),
                .define("HAVE_LROUND"),
                .define("HAVE_FSEEKO"),
                .define("HAVE_INTTYPES_H"),
                .define("HAVE_SYS_PARAM_H"),
                .define("PACKAGE_VERSION", to: "\"1.4.3\""),
                .unsafeFlags(["-include", "strings.h", "-include", "string.h"])
            ]
        ),
        .target(
            name: "Cebur128",
            path: "Sources/Cebur128",
            publicHeadersPath: "include",
            cSettings: [.define("M_PI", to: "3.14159265358979323846")]
        ),
        .target(
            name: "Csrc",
            path: "Sources/Csrc",
            publicHeadersPath: "include",
            cSettings: [
                .define("ENABLE_SINC_BEST_CONVERTER"),
                .define("ENABLE_SINC_MEDIUM_CONVERTER"),
                .define("ENABLE_SINC_FAST_CONVERTER"),
                .define("HAVE_STDBOOL_H"),
                .define("PACKAGE", to: "\"libsamplerate\""),
                .define("VERSION", to: "\"0.2.2\"")
            ]
        ),
        .target(name: "Cvorbis",  path: "Sources/Cvorbis",  publicHeadersPath: "include"),
        .target(
            name: "Copus",
            path: "Sources/Copus",
            exclude: ["silk/float"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .headerSearchPath("src/opusfile"),
                .headerSearchPath("celt"),
                .headerSearchPath("silk"),
                .headerSearchPath("silk/fixed"),
                .headerSearchPath("silk/float"),
                .headerSearchPath("include/ogg"),
                .headerSearchPath("include/opus"),
                .define("HAVE_CONFIG_H"),
                .define("OPUS_BUILD"),
                .define("OPUS_DISABLE_INTRINSICS"),
                .define("FIXED_POINT"),
                .define("USE_ALLOCA")
            ],
            linkerSettings: [.linkedLibrary("m")]
        ),

        // ── C/C++ DSP core + DJ real-time engine (C-clean public headers) ──
        .target(
            name: "CParsoDSP",
            path: "Sources/CParsoDSP",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("vendor/signalsmith"),
                .headerSearchPath("src"),
                .define("SIGNALSMITH_USE_ACCELERATE"),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate")
            ]
        ),
        .target(
            name: "CParsoEngine",
            dependencies: ["CParsoDSP"],
            path: "Sources/CParsoEngine",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CGlint",
            path: "Sources/CGlint",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("src")
            ]
        ),
        .target(
            name: "CflacBridge",
            dependencies: ["Cflac"],
            path: "Sources/CflacBridge",
            publicHeadersPath: "include",
            cSettings: [
                // libFLAC's public share/safe_str.h is an upstream header that
                // relies on the including translation unit for string APIs.
                .unsafeFlags(["-include", "string.h"])
            ]
        ),
        .target(
            name: "CvorbisBridge",
            dependencies: ["Cvorbis"],
            path: "Sources/CvorbisBridge",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CopusBridge",
            dependencies: ["Copus"],
            path: "Sources/CopusBridge",
            publicHeadersPath: "include"
        ),

        // ── Swift layers (Swift 6 language mode) ──
        .target(
            name: "ParsoAudioCore",
            dependencies: ["CParsoDSP", "CGlint", "CflacBridge", "CvorbisBridge", "CopusBridge", "Cebur128", "Csrc"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox", .when(platforms: [.iOS, .macCatalyst, .macOS])),
                .linkedFramework("Accelerate"),
            ]
        ),
        .target(
            name: "ParsoAudioAnalysis",
            dependencies: ["ParsoAudioCore"],
            linkerSettings: [
                .linkedFramework("Accelerate")
            ]
        ),
        .target(
            name: "ParsoAudioPlayback",
            dependencies: ["ParsoAudioCore"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .target(
            name: "ParsoAudioStreaming",
            dependencies: ["ParsoAudioCore"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
            ]
        ),
        .target(
            name: "ParsoDJEngine",
            dependencies: ["ParsoAudioCore", "ParsoAudioAnalysis", "CParsoEngine"]
        ),

        // ── Tests ──
        .testTarget(
            name: "ParsoAudioCoreTests",
            dependencies: ["ParsoAudioCore", "ParsoTestSupport"]
        ),
        .testTarget(
            name: "ParsoAudioAnalysisTests",
            dependencies: ["ParsoAudioAnalysis", "ParsoTestSupport"]
        ),
        .testTarget(
            name: "ParsoAudioPlaybackTests",
            dependencies: ["ParsoAudioPlayback", "ParsoTestSupport"]
        ),
        .testTarget(
            name: "ParsoAudioStreamingTests",
            dependencies: ["ParsoAudioStreaming", "ParsoTestSupport"]
        ),
        .testTarget(
            name: "ParsoDJEngineTests",
            dependencies: ["ParsoDJEngine", "ParsoTestSupport"]
        ),
        .target(
            name: "ParsoTestSupport",
            dependencies: ["ParsoAudioCore"],
            path: "Tests/Support"
        ),
    ],
    swiftLanguageModes: [.v6],
    cLanguageStandard: .c11,
    cxxLanguageStandard: .cxx17
)
