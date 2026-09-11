if(NOT DEFINED PARSO_HOST OR NOT DEFINED PARSO_FAKE_COMMAND OR NOT DEFINED PARSO_STATE_DIR OR
   NOT DEFINED PARSO_RECORD_PATH)
    message(FATAL_ERROR "PipeWire recovery harness arguments are incomplete")
endif()

file(REMOVE_RECURSE "${PARSO_STATE_DIR}")
file(REMOVE "${PARSO_RECORD_PATH}")

execute_process(
    COMMAND "${CMAKE_COMMAND}" -E env
        "PARSO_FAKE_PW_CAT_STATE_DIR=${PARSO_STATE_DIR}"
        "${PARSO_HOST}"
        --pw-cat "${PARSO_FAKE_COMMAND}"
        --capture
        --seconds 1
        --record "${PARSO_RECORD_PATH}"
    RESULT_VARIABLE result
    OUTPUT_VARIABLE output
    ERROR_VARIABLE error
)

if(NOT result EQUAL 0)
    message(FATAL_ERROR "PipeWire recovery host failed (${result})\n${output}\n${error}")
endif()

if(NOT EXISTS "${PARSO_RECORD_PATH}")
    message(FATAL_ERROR "PipeWire recovery did not produce a recording")
endif()

file(SIZE "${PARSO_RECORD_PATH}" record_size)
if(record_size LESS_EQUAL 44)
    message(FATAL_ERROR "PipeWire recovery recording is empty (${record_size} bytes)")
endif()

if(NOT output MATCHES "stream recoveries 2")
    message(FATAL_ERROR "Expected playback and capture recovery, got:\n${output}\n${error}")
endif()

message(STATUS "${output}")
