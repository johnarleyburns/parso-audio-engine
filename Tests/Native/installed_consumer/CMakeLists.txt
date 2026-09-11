cmake_minimum_required(VERSION 3.20)

project(parso_installed_consumer LANGUAGES C CXX)

find_package(ParsoAudioEngine CONFIG REQUIRED)

add_executable(installed_c_consumer ../installed_consumer.c)
target_link_libraries(installed_c_consumer PRIVATE ParsoAudioEngine::ParsoAPI)
if(UNIX)
    target_link_libraries(installed_c_consumer PRIVATE m)
endif()
target_include_directories(installed_c_consumer PRIVATE
    $<BUILD_INTERFACE:${PARSO_INSTALL_PREFIX}/include>
)
set_property(TARGET installed_c_consumer PROPERTY C_STANDARD 11)
set_property(TARGET installed_c_consumer PROPERTY C_STANDARD_REQUIRED ON)

add_executable(installed_cpp_consumer ../public_cpp_services_consumer.cpp)
target_link_libraries(installed_cpp_consumer PRIVATE ParsoAudioEngine::ParsoAPI)
target_include_directories(installed_cpp_consumer PRIVATE
    $<BUILD_INTERFACE:${PARSO_INSTALL_PREFIX}/include>
)
set_property(TARGET installed_cpp_consumer PROPERTY CXX_STANDARD 17)
set_property(TARGET installed_cpp_consumer PROPERTY CXX_STANDARD_REQUIRED ON)
