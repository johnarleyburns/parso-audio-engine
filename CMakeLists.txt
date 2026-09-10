cmake_minimum_required(VERSION 3.20)

project(parso_audio_engine
    VERSION 0.1.0
    LANGUAGES C CXX
    DESCRIPTION "Portable native DSP and headless render core for parso-audio-engine"
)

option(PARSO_BUILD_TESTS "Build native CTest smoke tests" ON)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(CParsoDSP STATIC
    Sources/CParsoDSP/src/parso_dsp_stub.cpp
)
target_include_directories(CParsoDSP
    PUBLIC Sources/CParsoDSP/include
    PRIVATE Sources/CParsoDSP/vendor/signalsmith
            Sources/CParsoDSP/src
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

add_library(CParsoAPI STATIC
    Sources/CParsoAPI/src/parso_api.cpp
)
target_include_directories(CParsoAPI
    PUBLIC Sources/CParsoAPI/include
    PRIVATE Sources/CParsoEngine/include
)
target_link_libraries(CParsoAPI PUBLIC CParsoEngine)

if(MSVC)
    target_compile_options(CParsoDSP PRIVATE /W4)
    target_compile_options(CParsoEngine PRIVATE /W4)
else()
    target_compile_options(CParsoDSP PRIVATE -Wall -Wextra -Wpedantic)
    target_compile_options(CParsoEngine PRIVATE -Wall -Wextra -Wpedantic)
    target_compile_options(CParsoAPI PRIVATE -Wall -Wextra -Wpedantic)
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
        target_link_libraries(parso_public_c_consumer PRIVATE CParsoAPI)
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
    endif()
endif()
