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
option(PARSO_ENABLE_SANITIZERS "Enable AddressSanitizer and UndefinedBehaviorSanitizer" OFF)

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

if(PARSO_ENABLE_SANITIZERS)
    if(MSVC)
        message(FATAL_ERROR "PARSO_ENABLE_SANITIZERS requires Clang or GCC")
    endif()
    add_compile_options(-fsanitize=address,undefined -fno-omit-frame-pointer)
    add_link_options(-fsanitize=address,undefined)
endif()

add_library(CParsoDSP STATIC
    Sources/CParsoDSP/src/parso_dsp_stub.cpp
)
target_include_directories(CParsoDSP
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/Sources/CParsoDSP/include>
        $<INSTALL_INTERFACE:include>
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
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/Sources/CParsoEngine/include>
        $<INSTALL_INTERFACE:include>
    PRIVATE Sources/CParsoDSP/include
)
target_link_libraries(CParsoEngine PUBLIC CParsoDSP)
set_target_properties(CParsoDSP CParsoEngine PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

# Reuse the permissively licensed, clean-room WAV/PCM implementation already
# shipped for the SwiftPM Glint target. Only its container-independent parser
# is needed by this native CP3 slice; no platform codec is implied by linking it.
add_library(CGlintWav STATIC Sources/CGlint/src/wav_io.cpp)
target_include_directories(CGlintWav PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/Sources/CGlint/src>
    $<INSTALL_INTERFACE:include>
)
set_target_properties(CGlintWav PROPERTIES POSITION_INDEPENDENT_CODE ON)

add_library(Csrc STATIC
    Sources/Csrc/src/samplerate.c
    Sources/Csrc/src/src_linear.c
    Sources/Csrc/src/src_sinc.c
    Sources/Csrc/src/src_zoh.c
)
target_include_directories(Csrc PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/Sources/Csrc/include>
    $<INSTALL_INTERFACE:include>
)
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
target_include_directories(Cebur128 PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/Sources/Cebur128/include>
    $<INSTALL_INTERFACE:include>
)
if(NOT MSVC)
    # Upstream 1.2.6 carries an intentionally unused error scratch variable in
    # one allocation path; keep the warning boundary limited to that vendor.
    target_compile_options(Cebur128 PRIVATE -Wno-unused-but-set-variable)
    if(CMAKE_C_COMPILER_ID MATCHES "Clang")
        target_compile_options(Cebur128 PRIVATE -Wno-cpp -Wno-pedantic)
    endif()
endif()
if(MINGW)
    # MinGW does not ship the BSD <sys/queue.h> header used by libebur128.
    # Keep the compatibility header first-party and outside the vendored tree.
    target_include_directories(Cebur128 PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/Sources/Cebur128/compat"
    )
endif()
set_target_properties(Cebur128 PROPERTIES POSITION_INDEPENDENT_CODE ON)

if(PARSO_BUILD_CODEC_BRIDGES)
    # These source lists mirror the SwiftPM vendor targets. The source files
    # remain unmodified upstream code; the SYSTEM include boundary keeps their
    # diagnostics from changing the first-party warning policy.
    add_library(Cogg STATIC
        Sources/Cogg/src/bitwise.c
        Sources/Cogg/src/framing.c
    )
    target_include_directories(Cogg SYSTEM PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/Sources/Cogg/include>
        $<INSTALL_INTERFACE:include>
    )
    if(PARSO_ENABLE_SANITIZERS AND CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
        # libogg's signed bit-packing shifts are upstream implementation
        # details; keep the sanitizer boundary narrow and source-unmodified.
        target_compile_options(Cogg PRIVATE -fno-sanitize=undefined)
    endif()
    set_target_properties(Cogg PROPERTIES POSITION_INDEPENDENT_CODE ON)

    file(GLOB_RECURSE Cflac_sources CONFIGURE_DEPENDS
        Sources/Cflac/src/*.c
    )
    list(FILTER Cflac_sources EXCLUDE REGEX "/deduplication/")
    add_library(Cflac STATIC ${Cflac_sources})
    target_include_directories(Cflac SYSTEM
        PUBLIC
            $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/Sources/Cflac/include>
            $<INSTALL_INTERFACE:include>
        PRIVATE Sources/Cflac/src Sources/Cflac/src/include
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
    if(WIN32)
        # The 1.4.3 headers select UTF-8-aware Windows file wrappers, but the
        # source drop omits their implementation. Keep that compatibility code
        # first-party and outside the vendored tree.
        target_sources(Cflac PRIVATE
            Sources/CflacCompat/src/win_utf8_io.c
        )
    endif()
    if(UNIX)
        target_link_libraries(Cflac PUBLIC m)
    endif()
    set_target_properties(Cflac PROPERTIES POSITION_INDEPENDENT_CODE ON)

    add_library(CflacBridge STATIC Sources/CflacBridge/src/parso_flac.c)
    target_include_directories(CflacBridge PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/Sources/CflacBridge/include>
        $<INSTALL_INTERFACE:include>
    )
    target_compile_definitions(CflacBridge PRIVATE FLAC__NO_DLL)
    target_link_libraries(CflacBridge PUBLIC Cflac)
    set_target_properties(CflacBridge PROPERTIES POSITION_INDEPENDENT_CODE ON)

    file(GLOB_RECURSE Cvorbis_sources CONFIGURE_DEPENDS
        Sources/Cvorbis/xiph/src/*.c
    )
    list(FILTER Cvorbis_sources EXCLUDE REGEX "/psytune\\.c$")
    add_library(Cvorbis STATIC ${Cvorbis_sources})
    target_include_directories(Cvorbis SYSTEM
        PUBLIC
            $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/Sources/Cvorbis/xiph/include>
            $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/Sources/Cogg/include>
            $<INSTALL_INTERFACE:include>
        PRIVATE Sources/Cvorbis/xiph/src
    )
    target_compile_definitions(Cvorbis PRIVATE HAVE_CONFIG_H)
    if(CMAKE_C_COMPILER_ID STREQUAL "GNU")
        # Unmodified libvorbis 1.3.7 uses compact one-line cleanup statements
        # that trigger this diagnostic under the repository's -Werror policy.
        target_compile_options(Cvorbis PRIVATE
            -Wno-misleading-indentation
            -Wno-maybe-uninitialized
        )
    elseif(CMAKE_C_COMPILER_ID MATCHES "Clang")
        target_compile_options(Cvorbis PRIVATE
            -Wno-misleading-indentation
            -Wno-strict-prototypes
            -Wno-unused-but-set-variable
            -Wno-unused-variable
        )
    endif()
    if(PARSO_ENABLE_SANITIZERS AND CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
        # libvorbis contains intentional signed bit-packing operations that
        # UBSan reports in unchanged upstream code. Keep ASan and all
        # first-party/bridge instrumentation enabled; exclude only this vendor
        # target at the compiler boundary.
        target_compile_options(Cvorbis PRIVATE -fno-sanitize=undefined)
    endif()
    target_link_libraries(Cvorbis PUBLIC Cogg)
    if(UNIX)
        target_link_libraries(Cvorbis PUBLIC m)
    endif()
    set_target_properties(Cvorbis PROPERTIES POSITION_INDEPENDENT_CODE ON)

    add_library(CvorbisBridge STATIC Sources/CvorbisBridge/src/parso_vorbis.c)
    target_include_directories(CvorbisBridge
        PUBLIC
            $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/Sources/CvorbisBridge/include>
            $<INSTALL_INTERFACE:include>
        PRIVATE Sources/Cvorbis/xiph/include Sources/Cogg/include
    )
    target_link_libraries(CvorbisBridge PUBLIC Cvorbis)
    set_target_properties(CvorbisBridge PROPERTIES POSITION_INDEPENDENT_CODE ON)

    file(GLOB_RECURSE Copus_sources CONFIGURE_DEPENDS
        Sources/Copus/celt/*.c
        Sources/Copus/silk/*.c
        Sources/Copus/src/*.c
    )
    list(FILTER Copus_sources EXCLUDE REGEX "/src/(bitwise|framing)\\.c$")
    list(FILTER Copus_sources EXCLUDE REGEX "/silk/float/")
    add_library(Copus STATIC ${Copus_sources})
    target_include_directories(Copus SYSTEM
        PUBLIC
            $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/Sources/Copus/include>
            $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/Sources/Cogg/include>
            $<INSTALL_INTERFACE:include>
        PRIVATE
            Sources/Copus/src
            Sources/Copus/src/opusfile
            Sources/Copus/celt
            Sources/Copus/silk
            Sources/Copus/silk/fixed
            Sources/Copus/silk/float
            Sources/Copus/include/ogg
            Sources/Copus/include/opus
            Sources/Cogg/include
    )
    target_compile_definitions(Copus PRIVATE
        HAVE_CONFIG_H
        OPUS_BUILD
        OPUS_DISABLE_INTRINSICS
        FIXED_POINT
        USE_ALLOCA
    )
    if(CMAKE_C_COMPILER_ID STREQUAL "GNU")
        # These are optimizer diagnostics in the unchanged libopus/libopusfile
        # sources; they are not emitted by the first-party bridge or tests.
        target_compile_options(Copus PRIVATE
            -Wno-maybe-uninitialized
            -Wno-stringop-overflow
            -Wno-unused-variable
        )
    elseif(CMAKE_C_COMPILER_ID MATCHES "Clang")
        target_compile_options(Copus PRIVATE
            -Wno-unused-variable
            -Wno-null-pointer-subtraction
        )
    endif()
    if(UNIX)
        target_link_libraries(Copus PUBLIC Cogg m)
    else()
        target_link_libraries(Copus PUBLIC Cogg)
    endif()
    set_target_properties(Copus PROPERTIES POSITION_INDEPENDENT_CODE ON)

    add_library(CopusBridge STATIC Sources/CopusBridge/src/parso_opus.c)
    target_include_directories(CopusBridge PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/Sources/CopusBridge/include>
        $<INSTALL_INTERFACE:include>
    )
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
        PUBLIC
            $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/Sources/CGlint/include>
            $<INSTALL_INTERFACE:include>
        PRIVATE Sources/CGlint/src
    )
    if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
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
    elseif(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
        target_compile_options(CGlint PRIVATE
            -Wno-unused-parameter
            -Wno-unused-variable
            -Wno-unused-but-set-variable
            -Wno-unused-function
        )
    endif()
    if(WIN32)
        target_compile_definitions(CGlint PRIVATE _USE_MATH_DEFINES)
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
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/Sources/CParsoAPI/include>
        $<INSTALL_INTERFACE:include>
    PRIVATE Sources/CParsoEngine/include Sources/CGlint/src
            Sources/CGlint/include Sources/Csrc/include Sources/Cebur128/include
)
target_link_libraries(CParsoAPI PUBLIC CParsoEngine PRIVATE CGlintWav Csrc Cebur128)
if(APPLE)
    target_link_libraries(CParsoAPI PUBLIC c++)
elseif(UNIX OR MINGW)
    target_link_libraries(CParsoAPI PUBLIC stdc++)
endif()
if(PARSO_BUILD_CODEC_BRIDGES)
    target_compile_definitions(CParsoAPI PRIVATE PARSO_CODEC_BRIDGES_AVAILABLE)
    target_include_directories(CParsoAPI PRIVATE Sources/CflacBridge/include)
    target_link_libraries(CParsoAPI PRIVATE CGlint CflacBridge CvorbisBridge CopusBridge)
endif()

if(PARSO_BUILD_SHARED_API)
    add_library(ParsoAPI SHARED
        Sources/CParsoAPI/src/parso_api.cpp
    )
    target_include_directories(ParsoAPI
        PUBLIC
            $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/Sources/CParsoAPI/include>
            $<INSTALL_INTERFACE:include>
        PRIVATE Sources/CParsoEngine/include Sources/CGlint/src
                Sources/CGlint/include Sources/Csrc/include Sources/Cebur128/include
    )
    target_compile_definitions(ParsoAPI PRIVATE
        PARSO_BUILD_SHARED
        PARSO_BUILDING_LIBRARY
    )
    target_link_libraries(ParsoAPI PRIVATE CParsoEngine CGlintWav Csrc Cebur128)
    if(PARSO_BUILD_CODEC_BRIDGES)
        target_compile_definitions(ParsoAPI PRIVATE PARSO_CODEC_BRIDGES_AVAILABLE)
        target_include_directories(ParsoAPI PRIVATE Sources/CflacBridge/include)
        target_link_libraries(ParsoAPI PRIVATE CGlint CflacBridge CvorbisBridge CopusBridge)
    endif()
    set_target_properties(ParsoAPI PROPERTIES OUTPUT_NAME parso)
endif()

if(ANDROID AND PARSO_BUILD_SHARED_API)
    find_path(PARSO_ANDROID_JNI_INCLUDE jni.h
        PATHS "${CMAKE_SYSROOT}/usr/include"
              "${CMAKE_ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include"
        NO_DEFAULT_PATH
    )
    if(NOT PARSO_ANDROID_JNI_INCLUDE)
        message(FATAL_ERROR "Android JNI headers were not found")
    endif()
    add_library(ParsoAndroidJNI SHARED
        Sources/ParsoAndroidJNI/src/parso_android_jni.cpp
    )
    target_include_directories(ParsoAndroidJNI PRIVATE
        "${PARSO_ANDROID_JNI_INCLUDE}"
        Sources/CParsoAPI/include
    )
    target_link_libraries(ParsoAndroidJNI PRIVATE ParsoAPI)
    set_target_properties(ParsoAndroidJNI PROPERTIES OUTPUT_NAME parso_android)
endif()

include(GNUInstallDirs)
include(CMakePackageConfigHelpers)

set(PARSO_INSTALL_TARGETS
    CParsoDSP CParsoEngine CGlintWav Csrc Cebur128 CParsoAPI
)
if(PARSO_BUILD_CODEC_BRIDGES)
    list(APPEND PARSO_INSTALL_TARGETS
        Cogg Cflac CflacBridge Cvorbis CvorbisBridge Copus CopusBridge CGlint
    )
endif()
if(PARSO_BUILD_SHARED_API)
    list(APPEND PARSO_INSTALL_TARGETS ParsoAPI)
endif()

install(TARGETS ${PARSO_INSTALL_TARGETS}
    EXPORT ParsoAudioEngineTargets
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)
install(FILES
    Sources/CParsoAPI/include/parso.h
    Sources/CParsoAPI/include/parso.hpp
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
)
install(DIRECTORY Sources/CParsoDSP/include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(DIRECTORY Sources/CParsoEngine/include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(DIRECTORY Sources/Csrc/include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(DIRECTORY Sources/Cebur128/include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(DIRECTORY Sources/Cogg/include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(DIRECTORY Sources/Cflac/include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(DIRECTORY Sources/Cvorbis/xiph/include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(DIRECTORY Sources/Copus/include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(DIRECTORY Sources/CflacBridge/include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(DIRECTORY Sources/CvorbisBridge/include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(DIRECTORY Sources/CopusBridge/include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(DIRECTORY Sources/CGlint/include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(FILES Sources/CGlint/src/wav_io.hpp DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(EXPORT ParsoAudioEngineTargets
    FILE ParsoAudioEngineTargets.cmake
    NAMESPACE ParsoAudioEngine::
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/ParsoAudioEngine
)
configure_package_config_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/cmake/ParsoAudioEngineConfig.cmake.in
    ${CMAKE_CURRENT_BINARY_DIR}/ParsoAudioEngineConfig.cmake
    INSTALL_DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/ParsoAudioEngine
)
write_basic_package_version_file(
    ${CMAKE_CURRENT_BINARY_DIR}/ParsoAudioEngineConfigVersion.cmake
    VERSION ${PROJECT_VERSION}
    COMPATIBILITY SameMajorVersion
)
install(FILES
    ${CMAKE_CURRENT_BINARY_DIR}/ParsoAudioEngineConfig.cmake
    ${CMAKE_CURRENT_BINARY_DIR}/ParsoAudioEngineConfigVersion.cmake
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/ParsoAudioEngine
)
set(PARSO_PKGCONFIG_LIBS "-lparso")
if(NOT PARSO_BUILD_SHARED_API)
    if(APPLE)
        set(PARSO_CXX_RUNTIME "-lc++")
    elseif(UNIX OR MINGW)
        set(PARSO_CXX_RUNTIME "-lstdc++")
    else()
        set(PARSO_CXX_RUNTIME "")
    endif()
    set(PARSO_PKGCONFIG_LIBS "-lCParsoAPI -lCParsoEngine -lCParsoDSP -lCGlintWav -lCsrc -lCebur128")
    if(PARSO_BUILD_CODEC_BRIDGES)
        set(PARSO_PKGCONFIG_LIBS
            "${PARSO_PKGCONFIG_LIBS} -lCGlint -lCflacBridge -lCflac -lCvorbisBridge -lCvorbis -lCopusBridge -lCopus -lCogg"
        )
    endif()
    set(PARSO_PKGCONFIG_LIBS "${PARSO_PKGCONFIG_LIBS} ${PARSO_CXX_RUNTIME} -lm")
endif()
configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/cmake/parso-audio-engine.pc.in
    ${CMAKE_CURRENT_BINARY_DIR}/parso-audio-engine.pc
    @ONLY
)
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/parso-audio-engine.pc
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/pkgconfig
)

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

        add_executable(parso_rt_allocation_consumer
            Tests/Native/rt_allocation_consumer.cpp
        )
        target_link_libraries(parso_rt_allocation_consumer PRIVATE CParsoEngine)
        target_include_directories(parso_rt_allocation_consumer PRIVATE
            Sources/CParsoEngine/include
        )
        add_test(NAME rt_allocation_consumer COMMAND parso_rt_allocation_consumer)
        set_tests_properties(rt_allocation_consumer PROPERTIES
            LABELS "native;engine;stress;rt"
        )
        if(PARSO_ENABLE_SANITIZERS)
            # This consumer deliberately replaces global new/delete with a
            # malloc/free counting pair. ASan otherwise flags that test
            # harness pairing as an allocator mismatch before engine teardown.
            set_tests_properties(rt_allocation_consumer PROPERTIES
                ENVIRONMENT "ASAN_OPTIONS=alloc_dealloc_mismatch=0"
            )
        endif()

        add_executable(parso_long_session_consumer
            Tests/Native/long_session_consumer.cpp
        )
        target_link_libraries(parso_long_session_consumer PRIVATE
            $<$<BOOL:${PARSO_BUILD_SHARED_API}>:ParsoAPI>
            $<$<NOT:$<BOOL:${PARSO_BUILD_SHARED_API}>>:CParsoAPI>
        )
        target_include_directories(parso_long_session_consumer PRIVATE
            Sources/CParsoAPI/include
        )
        add_test(NAME long_session_consumer COMMAND parso_long_session_consumer)
        set_tests_properties(long_session_consumer PROPERTIES
            LABELS "native;stress;recording;consumer;cxx17"
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
        if(UNIX)
            target_link_libraries(parso_public_c_services_consumer PRIVATE m)
        endif()
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

        add_executable(parso_public_c_record_consumer
            Tests/Native/public_c_record_consumer.c
        )
        target_link_libraries(parso_public_c_record_consumer PRIVATE
            $<$<BOOL:${PARSO_BUILD_SHARED_API}>:ParsoAPI>
            $<$<NOT:$<BOOL:${PARSO_BUILD_SHARED_API}>>:CParsoAPI>
        )
        if(UNIX)
            target_link_libraries(parso_public_c_record_consumer PRIVATE m)
        endif()
        target_include_directories(parso_public_c_record_consumer PRIVATE
            Sources/CParsoAPI/include
        )
        add_test(NAME public_c_record_consumer COMMAND parso_public_c_record_consumer)
        set_tests_properties(public_c_record_consumer PROPERTIES
            LABELS "native;public-api;consumer;recording;c11"
        )

        add_executable(parso_native_acceptance_artifacts
            Tools/NativeAcceptanceArtifacts/main.cpp
        )
        target_link_libraries(parso_native_acceptance_artifacts PRIVATE
            $<$<BOOL:${PARSO_BUILD_SHARED_API}>:ParsoAPI>
            $<$<NOT:$<BOOL:${PARSO_BUILD_SHARED_API}>>:CParsoAPI>
        )
        target_include_directories(parso_native_acceptance_artifacts PRIVATE
            Sources/CParsoAPI/include
        )
        add_test(NAME native_acceptance_artifacts
            COMMAND parso_native_acceptance_artifacts
                --output-dir "${CMAKE_CURRENT_BINARY_DIR}/native-acceptance-artifacts"
        )
        set_tests_properties(native_acceptance_artifacts PROPERTIES
            LABELS "native;acceptance;offline;recording;cxx17"
        )
        add_test(NAME native_acceptance_crossfader
            COMMAND parso_native_acceptance_artifacts
                --output-dir "${CMAKE_CURRENT_BINARY_DIR}/native-crossfader-artifacts"
                --scenario crossfader-sweep
        )
        set_tests_properties(native_acceptance_crossfader PROPERTIES
            LABELS "native;acceptance;offline;engine;crossfader;cxx17"
        )

        if(PARSO_BUILD_CODEC_BRIDGES)
            add_executable(parso_public_codec_consumer
                Tests/Native/public_codec_consumer.c
            )
            target_link_libraries(parso_public_codec_consumer PRIVATE
                $<$<BOOL:${PARSO_BUILD_SHARED_API}>:ParsoAPI>
                $<$<NOT:$<BOOL:${PARSO_BUILD_SHARED_API}>>:CParsoAPI>
            )
            if(UNIX)
                target_link_libraries(parso_public_codec_consumer PRIVATE m)
            endif()
            target_include_directories(parso_public_codec_consumer PRIVATE
                Sources/CParsoAPI/include
            )
            add_test(NAME public_codec_consumer COMMAND parso_public_codec_consumer)
            set_tests_properties(public_codec_consumer PROPERTIES
                LABELS "native;public-api;consumer;offline;codec;c11"
            )
            if(PARSO_BUILD_CODEC_FIXTURE_TESTS)
                add_test(NAME public_codec_fixture_consumer
                    COMMAND parso_public_codec_consumer
                        "${PARSO_NATIVE_FIXTURES_DIR}/wikipedia_chanukah.flac"
                        "${PARSO_NATIVE_FIXTURES_DIR}/audial_waking_up.ogg"
                        "${PARSO_NATIVE_FIXTURES_DIR}/gostreyshen_world.mp3"
                )
                set_tests_properties(public_codec_fixture_consumer PROPERTIES
                    LABELS "native;public-api;consumer;offline;codec;fixtures;c11"
                    SKIP_RETURN_CODE 77
                )
            endif()
        endif()

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

        if(NOT PARSO_ENABLE_SANITIZERS)
            add_test(NAME installed_c_consumer
                COMMAND ${CMAKE_COMMAND}
                    -DPARSO_PACKAGE_SOURCE_DIR=${CMAKE_SOURCE_DIR}
                    -DPARSO_PACKAGE_BINARY_DIR=${CMAKE_BINARY_DIR}
                    -DPARSO_PACKAGE_INSTALL_DIR=${CMAKE_BINARY_DIR}/installed-package
                    -P ${CMAKE_SOURCE_DIR}/cmake/run-installed-consumer.cmake
            )
            set_tests_properties(installed_c_consumer PROPERTIES
                LABELS "native;public-api;consumer;packaging;c11"
            )
        endif()

        if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
            add_executable(parso_linux_host_callback
                Tools/LinuxHostCallback/main.cpp
            )
            target_link_libraries(parso_linux_host_callback PRIVATE
                $<$<BOOL:${PARSO_BUILD_SHARED_API}>:ParsoAPI>
                $<$<NOT:$<BOOL:${PARSO_BUILD_SHARED_API}>>:CParsoAPI>
            )
            target_include_directories(parso_linux_host_callback PRIVATE
                Sources/CParsoAPI/include
            )
            add_test(NAME linux_host_callback COMMAND parso_linux_host_callback)
            set_tests_properties(linux_host_callback PROPERTIES
                LABELS "native;linux;host-callback;consumer;cxx17"
            )
        endif()
    endif()
endif()
