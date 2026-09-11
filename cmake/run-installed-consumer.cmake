if(NOT DEFINED PARSO_PACKAGE_SOURCE_DIR OR NOT DEFINED PARSO_PACKAGE_BINARY_DIR OR
   NOT DEFINED PARSO_PACKAGE_INSTALL_DIR)
    message(FATAL_ERROR "installed consumer variables are required")
endif()

file(REMOVE_RECURSE "${PARSO_PACKAGE_INSTALL_DIR}")
execute_process(
    COMMAND "${CMAKE_COMMAND}" --install "${PARSO_PACKAGE_BINARY_DIR}"
            --prefix "${PARSO_PACKAGE_INSTALL_DIR}"
    RESULT_VARIABLE install_status
)
if(NOT install_status EQUAL 0)
    message(FATAL_ERROR "native package installation failed: ${install_status}")
endif()

set(consumer_source_dir "${PARSO_PACKAGE_SOURCE_DIR}/Tests/Native/installed_consumer")
set(consumer_build_dir "${PARSO_PACKAGE_BINARY_DIR}/installed-consumer-build")
file(REMOVE_RECURSE "${consumer_build_dir}")
execute_process(
    COMMAND "${CMAKE_COMMAND}" -S "${consumer_source_dir}" -B "${consumer_build_dir}"
            -DCMAKE_BUILD_TYPE=Release
            -DCMAKE_PREFIX_PATH=${PARSO_PACKAGE_INSTALL_DIR}
            -DPARSO_INSTALL_PREFIX=${PARSO_PACKAGE_INSTALL_DIR}
    RESULT_VARIABLE configure_status
)
if(NOT configure_status EQUAL 0)
    message(FATAL_ERROR "installed consumer configure failed: ${configure_status}")
endif()

execute_process(
    COMMAND "${CMAKE_COMMAND}" --build "${consumer_build_dir}" --config Release
    RESULT_VARIABLE build_status
)
if(NOT build_status EQUAL 0)
    message(FATAL_ERROR "installed consumer build failed: ${build_status}")
endif()

set(consumer_executable "${consumer_build_dir}/installed_c_consumer")
set(cpp_consumer_executable "${consumer_build_dir}/installed_cpp_consumer")
if(WIN32)
    set(consumer_executable "${consumer_executable}.exe")
    set(cpp_consumer_executable "${cpp_consumer_executable}.exe")
    set(runtime_path "PATH=${PARSO_PACKAGE_INSTALL_DIR}/bin;$ENV{PATH}")
elseif(APPLE)
    set(runtime_path "DYLD_LIBRARY_PATH=${PARSO_PACKAGE_INSTALL_DIR}/lib:$ENV{DYLD_LIBRARY_PATH}")
else()
    set(runtime_path "LD_LIBRARY_PATH=${PARSO_PACKAGE_INSTALL_DIR}/lib:$ENV{LD_LIBRARY_PATH}")
endif()
execute_process(
    COMMAND "${CMAKE_COMMAND}" -E env "${runtime_path}" "${consumer_executable}"
    RESULT_VARIABLE run_status
)
if(NOT run_status EQUAL 0)
    message(FATAL_ERROR "installed consumer failed: ${run_status}")
endif()
execute_process(
    COMMAND "${CMAKE_COMMAND}" -E env "${runtime_path}" "${cpp_consumer_executable}"
    RESULT_VARIABLE cpp_run_status
)
if(NOT cpp_run_status EQUAL 0)
    message(FATAL_ERROR "installed C++ consumer failed: ${cpp_run_status}")
endif()
