cmake_minimum_required(VERSION 3.20)

project(parso_audio_engine
    VERSION 0.1.0
    LANGUAGES C CXX
    DESCRIPTION "Portable native DSP and headless render core for parso-audio-engine"
)

option(PARSO_BUILD_TESTS "Build native CTest smoke tests" ON)
option(PARSO_BUILD_SHARED_API "Build the shared parso C ABI library" ON)
option(PARSO_BUILD_CODEC_BRIDGES "Build the vendored FLAC/Vorbis/Opus bridge targets" ON)
option(PARSO_BUILD_CODEC_FIXTURE_TESTS "Build native codec fixture smoke tests" ON)

set(PARSO_NATIVE_FIXTURES_DIR "${CMAKE_SOURCE_DIR}/Tests/Fixtures/audio" CACHE PATH
    "Directory containing downloaded native codec fixtures")

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Treat first-party native warnings as errors in every C/C++ target, including
# the standalone consumers. Vendored Signalsmith headers are marked SYSTEM on
# the DSP target below so their unchanged upstream diagnostics do not weaken
# this policy.
if(MSVC)
    add_compile_options(/W4 /WX)
else()
    add_compile_options(-Wall -Wextra -Wpedantic -Werror)
endif()

add_library(CParsoDSP STATIC
    Sources/CParsoDSP/src/parso_dsp_stub.cpp
)
target_include_directories(CParsoDSP
    PUBLIC Sources/CParsoDSP/include
    PRIVATE Sources/CParsoDSP/src
)
target_include_directories(CParsoDSP SYSTEM PRIVATE
    Sources/CParsoDSP/vendor/signalsmith
)

# Signalsmith has a portable implementation. Accelerate remains an Apple-only
# optimization in SwiftPM; it must never be required by Linux or Android builds.
if(APPLE)
    target_compile_definitions(CParsoDSP PRIVATE SIGNALSMITH_USE_ACCELERATE)
    find_library(ACCELERATE_FRAMEWORK Accelerate REQUIRED)
    target_link_libraries(CParsoDSP PRIVATE "${ACCELERATE_FRAMEWORK}")
endif()

add_library(CParsoEngine STATIC
    Sources/CParsoEngine/src/parso_engine_stub.cpp
)
target_include_directories(CParsoEngine
    PUBLIC Sources/CParsoEngine/include
    PRIVATE Sources/CParsoDSP/include
)
target_link_libraries(CParsoEngine PUBLIC CParsoDSP)
set_target_properties(CParsoDSP CParsoEngine PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

# Reuse the permissively licensed, clean-room WAV/PCM implementation already
# shipped for the SwiftPM Glint target. Only its container-independent parser
# is needed by this native CP3 slice; no platform codec is implied by linking it.
add_library(CGlintWav STATIC
    Sources/CGlint/src/wav_io.cpp
)
target_include_directories(CGlintWav PUBLIC Sources/CGlint/src)
set_target_properties(CGlintWav PROPERTIES POSITION_INDEPENDENT_CODE ON)

add_library(Csrc STATIC
    Sources/Csrc/src/samplerate.c
    Sources/Csrc/src/src_linear.c
    Sources/Csrc/src/src_sinc.c
    Sources/Csrc/src/src_zoh.c
)
target_include_directories(Csrc PUBLIC Sources/Csrc/include)
target_compile_definitions(Csrc PRIVATE
    HAVE_STDBOOL_H
    ENABLE_SINC_BEST_CONVERTER
    ENABLE_SINC_MEDIUM_CONVERTER
    ENABLE_SINC_FAST_CONVERTER
    PACKAGE="libsamplerate"
    VERSION="0.2.2"
)
set_target_properties(Csrc PROPERTIES POSITION_INDEPENDENT_CODE ON)
if(UNIX)
    target_link_libraries(Csrc PUBLIC m)
endif()

add_library(Cebur128 STATIC
    Sources/Cebur128/src/ebur128.c
)
target_include_directories(Cebur128 PUBLIC Sources/Cebur128/include)
if(NOT MSVC)
    # Upstream 1.2.6 carries an intentionally unused error scratch variable in
    # one allocation path; keep the warning boundary limited to that vendor.
    target_compile_options(Cebur128 PRIVATE -Wno-unused-but-set-variable)
endif()
set_target_properties(Cebur128 PROPERTIES POSITION_INDEPENDENT_CODE ON)

if(PARSO_BUILD_CODEC_BRIDGES)
    # These source lists mirror the SwiftPM vendor targets. The source files
    # remain unmodified upstream code; the SYSTEM include boundary keeps their
    # diagnostics from changing the first-party warning policy.
    file(GLOB_RECURSE Cflac_sources CONFIGURE_DEPENDS
        Sources/Cflac/src/*.c
    )
    list(FILTER Cflac_sources EXCLUDE REGEX "/deduplication/")
    add_library(Cflac STATIC ${Cflac_sources})
    target_include_directories(Cflac
        SYSTEM PUBLIC Sources/Cflac/include
        SYSTEM PRIVATE Sources/Cflac/src Sources/Cflac/src/include
    )
    target_compile_definitions(Cflac PRIVATE
        FLAC__NO_DLL
        HAVE_STDINT_H
        FLAC__HAS_OGG=0
        HAVE_LROUND
        HAVE_FSEEKO
        HAVE_INTTYPES_H
        HAVE_SYS_PARAM_H
        PACKAGE_VERSION="1.4.3"
    )
    if(CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
        # GCC's optimized build diagnoses an upstream C99 empty initializer as
        # a pedantic error. Keep the exception on the unchanged vendor target.
        target_compile_options(Cflac PRIVATE -Wno-pedantic)
    endif()
    if(UNIX)
        target_link_libraries(Cflac PUBLIC m)
    endif()
    set_target_properties(Cflac PROPERTIES POSITION_INDEPENDENT_CODE ON)

    add_library(CflacBridge STATIC Sources/CflacBridge/src/parso_flac.c)
    target_include_directories(CflacBridge PUBLIC Sources/CflacBridge/include)
    target_link_libraries(CflacBridge PUBLIC Cflac)
    set_target_properties(CflacBridge PROPERTIES POSITION_INDEPENDENT_CODE ON)

    add_library(Cvorbis STATIC Sources/Cvorbis/src/stb_vorbis_impl.c)
    target_include_directories(Cvorbis SYSTEM PUBLIC Sources/Cvorbis/include)
    set_target_properties(Cvorbis PROPERTIES POSITION_INDEPENDENT_CODE ON)

    add_library(CvorbisBridge STATIC Sources/CvorbisBridge/src/parso_vorbis.c)
    target_include_directories(CvorbisBridge PUBLIC Sources/CvorbisBridge/include)
    target_link_libraries(CvorbisBridge PUBLIC Cvorbis)
    set_target_properties(CvorbisBridge PROPERTIES POSITION_INDEPENDENT_CODE ON)

    file(GLOB_RECURSE Copus_sources CONFIGURE_DEPENDS
        Sources/Copus/celt/*.c
        Sources/Copus/silk/*.c
        Sources/Copus/src/*.c
    )
    list(FILTER Copus_sources EXCLUDE REGEX "/silk/float/")
    add_library(Copus STATIC ${Copus_sources})
    target_include_directories(Copus
        SYSTEM PUBLIC Sources/Copus/include
        SYSTEM PRIVATE
            Sources/Copus/src
            Sources/Copus/src/opusfile
            Sources/Copus/celt
            Sources/Copus/silk
            Sources/Copus/silk/fixed
            Sources/Copus/silk/float
            Sources/Copus/include/ogg
            Sources/Copus/include/opus
    )
    target_compile_definitions(Copus PRIVATE
        HAVE_CONFIG_H
        OPUS_BUILD
        OPUS_DISABLE_INTRINSICS
        FIXED_POINT
        USE_ALLOCA
    )
    if(CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
        # These are optimizer diagnostics in the unchanged libopus/libopusfile
        # sources; they are not emitted by the first-party bridge or tests.
        target_compile_options(Copus PRIVATE
            -Wno-maybe-uninitialized
            -Wno-stringop-overflow
            -Wno-unused-variable
        )
    endif()
    if(UNIX)
        target_link_libraries(Copus PUBLIC m)
    endif()
    set_target_properties(Copus PROPERTIES POSITION_INDEPENDENT_CODE ON)

    add_library(CopusBridge STATIC Sources/CopusBridge/src/parso_opus.c)
    target_include_directories(CopusBridge PUBLIC Sources/CopusBridge/include)
    target_link_libraries(CopusBridge PUBLIC Copus)
    set_target_properties(CopusBridge PROPERTIES POSITION_INDEPENDENT_CODE ON)

    # CGlint is the portable MP3/AAC codec path. Keep its complete C-clean
    # surface in one target so the native fixture gate exercises the same
    # implementation used by the SwiftPM target.
    file(GLOB_RECURSE CGlint_sources CONFIGURE_DEPENDS
        Sources/CGlint/src/*.cpp
    )
    add_library(CGlint STATIC ${CGlint_sources})
    target_include_directories(CGlint
        PUBLIC Sources/CGlint/include
        PRIVATE Sources/CGlint/src
    )
    if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
        # Glint is vendored unchanged under its MIT license. Its upstream
        # release has a few intentionally dormant code paths and optimizer
        # false positives under the repository's global -Werror policy.
        target_compile_options(CGlint PRIVATE
            -Wno-unused-parameter
            -Wno-maybe-uninitialized
            -Wno-stringop-overflow
            -Wno-unused-variable
            -Wno-unused-but-set-variable
            -Wno-unused-function
        )
    endif()
    if(UNIX)
        target_link_libraries(CGlint PUBLIC m)
    endif()
    set_target_properties(CGlint PROPERTIES POSITION_INDEPENDENT_CODE ON)
endif()

add_library(CParsoAPI STATIC
    Sources/CParsoAPI/src/parso_api.cpp
)
target_include_directories(CParsoAPI
    PUBLIC Sources/CParsoAPI/include
    PRIVATE Sources/CParsoEngine/include Sources/CGlint/src
            Sources/Csrc/include Sources/Cebur128/include
)
target_link_libraries(CParsoAPI PUBLIC CParsoEngine PRIVATE CGlintWav Csrc Cebur128)

if(PARSO_BUILD_SHARED_API)
    add_library(ParsoAPI SHARED
        Sources/CParsoAPI/src/parso_api.cpp
    )
    target_include_directories(ParsoAPI
        PUBLIC Sources/CParsoAPI/include
        PRIVATE Sources/CParsoEngine/include Sources/CGlint/src
                Sources/Csrc/include Sources/Cebur128/include
    )
    target_compile_definitions(ParsoAPI PRIVATE
        PARSO_BUILD_SHARED
        PARSO_BUILDING_LIBRARY
    )
    target_link_libraries(ParsoAPI PRIVATE CParsoEngine CGlintWav Csrc Cebur128)
    set_target_properties(ParsoAPI PROPERTIES OUTPUT_NAME parso)
endif()

include(CTest)
if(PARSO_BUILD_TESTS)
    if(BUILD_TESTING)
        add_executable(parso_native_headless_smoke
            Tests/Native/native_headless_smoke.cpp
        )
        target_link_libraries(parso_native_headless_smoke PRIVATE CParsoEngine)
        target_include_directories(parso_native_headless_smoke PRIVATE
            Sources/CParsoEngine/include
        )
        add_test(NAME native_headless_smoke COMMAND parso_native_headless_smoke)
        set_tests_properties(native_headless_smoke PROPERTIES
            LABELS "native;headless;integration"
        )

        add_executable(parso_native_header_smoke
            Tests/Native/native_header_smoke.c
        )
        target_include_directories(parso_native_header_smoke PRIVATE
            Sources/CParsoDSP/include
            Sources/CParsoEngine/include
        )
        add_test(NAME native_header_smoke COMMAND parso_native_header_smoke)
        set_tests_properties(native_header_smoke PROPERTIES
            LABELS "native;headers;unit"
        )

        add_executable(parso_public_c_consumer
            Tests/Native/public_c_consumer.c
        )
        if(PARSO_BUILD_SHARED_API)
            target_link_libraries(parso_public_c_consumer PRIVATE ParsoAPI)
        else()
            target_link_libraries(parso_public_c_consumer PRIVATE CParsoAPI)
        endif()
        target_include_directories(parso_public_c_consumer PRIVATE
            Sources/CParsoAPI/include
        )
        add_test(NAME public_c_consumer COMMAND parso_public_c_consumer)
        set_tests_properties(public_c_consumer PROPERTIES
            LABELS "native;public-api;consumer;c11"
        )

        add_executable(parso_public_cpp_consumer
            Tests/Native/public_cpp_consumer.cpp
        )
        target_link_libraries(parso_public_cpp_consumer PRIVATE CParsoAPI)
        target_include_directories(parso_public_cpp_consumer PRIVATE
            Sources/CParsoAPI/include
        )
        add_test(NAME public_cpp_consumer COMMAND parso_public_cpp_consumer)
        set_tests_properties(public_cpp_consumer PROPERTIES
            LABELS "native;public-api;consumer;cxx17"
        )

        add_executable(parso_public_c_offline_consumer
            Tests/Native/public_c_offline_consumer.c
        )
        target_link_libraries(parso_public_c_offline_consumer PRIVATE
            $<$<BOOL:${PARSO_BUILD_SHARED_API}>:ParsoAPI>
            $<$<NOT:$<BOOL:${PARSO_BUILD_SHARED_API}>>:CParsoAPI>
        )
        target_include_directories(parso_public_c_offline_consumer PRIVATE
            Sources/CParsoAPI/include
        )
        add_test(NAME public_c_offline_consumer COMMAND parso_public_c_offline_consumer)
        set_tests_properties(public_c_offline_consumer PROPERTIES
            LABELS "native;public-api;consumer;offline;c11"
        )

        add_executable(parso_public_cpp_offline_consumer
            Tests/Native/public_cpp_offline_consumer.cpp
        )
        target_link_libraries(parso_public_cpp_offline_consumer PRIVATE CParsoAPI)
        target_include_directories(parso_public_cpp_offline_consumer PRIVATE
            Sources/CParsoAPI/include
        )
        add_test(NAME public_cpp_offline_consumer COMMAND parso_public_cpp_offline_consumer)
        set_tests_properties(public_cpp_offline_consumer PROPERTIES
            LABELS "native;public-api;consumer;offline;cxx17"
        )

        add_executable(parso_public_c_services_consumer
            Tests/Native/public_c_services_consumer.c
        )
        target_link_libraries(parso_public_c_services_consumer PRIVATE
            $<$<BOOL:${PARSO_BUILD_SHARED_API}>:ParsoAPI>
            $<$<NOT:$<BOOL:${PARSO_BUILD_SHARED_API}>>:CParsoAPI>
        )
        target_include_directories(parso_public_c_services_consumer PRIVATE
            Sources/CParsoAPI/include
        )
        add_test(NAME public_c_services_consumer COMMAND parso_public_c_services_consumer)
        set_tests_properties(public_c_services_consumer PROPERTIES
            LABELS "native;public-api;consumer;offline;services;c11"
        )

        add_executable(parso_public_cpp_services_consumer
            Tests/Native/public_cpp_services_consumer.cpp
        )
        target_link_libraries(parso_public_cpp_services_consumer PRIVATE CParsoAPI)
        target_include_directories(parso_public_cpp_services_consumer PRIVATE
            Sources/CParsoAPI/include
        )
        add_test(NAME public_cpp_services_consumer COMMAND parso_public_cpp_services_consumer)
        set_tests_properties(public_cpp_services_consumer PROPERTIES
            LABELS "native;public-api;consumer;offline;services;cxx17"
        )

        if(PARSO_BUILD_CODEC_BRIDGES AND PARSO_BUILD_CODEC_FIXTURE_TESTS)
            add_executable(parso_native_codec_fixture_smoke
                Tests/Native/native_codec_fixture_smoke.c
            )
            target_include_directories(parso_native_codec_fixture_smoke PRIVATE
                Sources/CflacBridge/include
                Sources/CvorbisBridge/include
                Sources/CopusBridge/include
                Sources/CGlint/include
            )
            target_link_libraries(parso_native_codec_fixture_smoke PRIVATE
                CflacBridge CvorbisBridge CopusBridge CGlint
            )
            add_test(NAME native_codec_fixture_smoke
                COMMAND parso_native_codec_fixture_smoke
                    "${PARSO_NATIVE_FIXTURES_DIR}/wikipedia_chanukah.flac"
                    "${PARSO_NATIVE_FIXTURES_DIR}/audial_waking_up.ogg"
                    "${PARSO_NATIVE_FIXTURES_DIR}/razrfish_mocassins.opus"
                    "${PARSO_NATIVE_FIXTURES_DIR}/gostreyshen_world.mp3"
            )
            set_tests_properties(native_codec_fixture_smoke PROPERTIES
                LABELS "native;codec;fixtures;flac;vorbis;opus;mp3;aac;wav"
                SKIP_RETURN_CODE 77
            )
        endif()
    endif()
endif()
