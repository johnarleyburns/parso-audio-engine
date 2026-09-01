// swift-tools-version: 6.0
import PackageDescription

// parso-audio-engine — MIT-licensed, permissive-only software DJ engine
// delivering full DDJ-FLX4 functional equivalence. See docs/SPEC.md.
//
// Swift 6 language mode is enabled package-wide (strict concurrency).
// The C/C++ targets currently ship as *placeholder* modules that compile but
// return errors; vendor the real permissive libraries per docs/SPEC.md §4:
//   Cflac    -> libFLAC (BSD-3)            https://xiph.org/flac/
//   Cebur128 -> libebur128 (MIT)          https://github.com/jiixyj/libebur128
//   Csrc     -> libsamplerate >= 0.2.2     https://github.com/libsndfile/libsamplerate  (BSD-2)
//   Cvorbis  -> stb_vorbis (Public Domain) https://github.com/nothings/stb   (Ogg Vorbis decode)
//   Copus    -> libogg + libopus + libopusfile (BSD-3)  https://github.com/xiph  (Opus decode)
//   CParsoDSP/vendor/signalsmith -> Signalsmith Stretch (MIT)
//                                          https://github.com/Signalsmith-Audio/signalsmith-stretch
//   CGlint (planned) -> Glint portable MP3/AAC-LC compatibility and MP3 encode
//   Calac    -> AppleALAC codec (Apache-2.0) https://github.com/macosforge/alac

let package = Package(
    name: "parso-audio-engine",
    platforms: [
        .iOS(.v15),
        .macCatalyst(.v15),
        .macOS(.v13)
    ],
    products: [
        .library(name: "ParsoAudioCore",     targets: ["ParsoAudioCore"]),
        .library(name: "ParsoAudioAnalysis", targets: ["ParsoAudioAnalysis"]),
        .library(name: "ParsoDJEngine",      targets: ["ParsoDJEngine"]),
        .executable(name: "ParsoAcceptanceArtifacts", targets: ["ParsoAcceptanceArtifacts"]),
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
                .define("HAVE_CPUID_H", .when(platforms: [.linux])),
                .define("HAVE_FSEEKO"),
                .define("HAVE_INTTYPES_H"),
                .define("HAVE_SYS_PARAM_H"),
                .define("_POSIX_C_SOURCE", to: "200809L", .when(platforms: [.linux])),
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
                .define("SIGNALSMITH_USE_ACCELERATE", .when(platforms: [.iOS, .macCatalyst, .macOS])),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate", .when(platforms: [.iOS, .macCatalyst, .macOS]))
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
            name: "Calac",
            path: "Sources/Calac",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("vendor/codec")
            ],
            cxxSettings: [
                .headerSearchPath("vendor/codec")
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
            dependencies: ["CParsoDSP", "CGlint", "Calac", "CflacBridge", "CvorbisBridge", "CopusBridge", "Cebur128", "Csrc"],
            linkerSettings: [
                .linkedFramework("AVFoundation", .when(platforms: [.iOS, .macCatalyst, .macOS])),
                .linkedFramework("AudioToolbox", .when(platforms: [.iOS, .macCatalyst, .macOS])),
                .linkedFramework("Accelerate",   .when(platforms: [.iOS, .macCatalyst, .macOS])),
            ]
        ),
        .target(
            name: "ParsoAudioAnalysis",
            dependencies: ["ParsoAudioCore"],
            linkerSettings: [
                .linkedFramework("Accelerate", .when(platforms: [.iOS, .macCatalyst, .macOS]))
            ]
        ),
        .target(
            name: "ParsoDJEngine",
            dependencies: ["ParsoAudioCore", "ParsoAudioAnalysis", "CParsoEngine"]
        ),
        .executableTarget(
            name: "ParsoAcceptanceArtifacts",
            dependencies: ["ParsoAudioCore", "ParsoAudioAnalysis", "ParsoDJEngine"],
            path: "Sources/ParsoAcceptanceArtifacts"
        ),

        // ── Tests ──
        .testTarget(
            name: "ParsoAudioCoreTests",
            dependencies: ["ParsoAudioCore", "Calac", "ParsoTestSupport"]
        ),
        .testTarget(
            name: "ParsoAudioAnalysisTests",
            dependencies: ["ParsoAudioAnalysis", "ParsoTestSupport"]
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
