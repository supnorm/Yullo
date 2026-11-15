cmake_minimum_required(VERSION 3.20)
project(YulloLocalTranslation LANGUAGES C CXX OBJC OBJCXX)
if(NOT YULLO_LLAMA_SOURCE)
    message(FATAL_ERROR "A pinned llama.cpp source directory is required")
endif()
add_subdirectory("${YULLO_LLAMA_SOURCE}" llama-build EXCLUDE_FROM_ALL)
# The pinned ggml reads a NULL Metal pipeline when a kernel is missing from the compiled
# libraries, which crashed translation on M5 Macs. Its two files build from copies with
# ggml-metal-missing-pipeline.patch: the graph fails instead, and the app retries in a
# safer mode. The pinned source tree itself stays unmodified.
set(YULLO_GGML_METAL "${YULLO_LLAMA_SOURCE}/ggml/src/ggml-metal")
set(YULLO_GUARDED_METAL "${CMAKE_CURRENT_BINARY_DIR}/ggml-metal-guarded")
set(YULLO_METAL_PATCH "${CMAKE_CURRENT_SOURCE_DIR}/ggml-metal-missing-pipeline.patch")
file(REMOVE_RECURSE "${YULLO_GUARDED_METAL}")
file(COPY "${YULLO_GGML_METAL}/ggml-metal-device.m" "${YULLO_GGML_METAL}/ggml-metal-context.m"
    DESTINATION "${YULLO_GUARDED_METAL}")
execute_process(
    COMMAND patch --forward --batch --fuzz=0 --quiet -p1 -d "${YULLO_GUARDED_METAL}" -i "${YULLO_METAL_PATCH}"
    RESULT_VARIABLE YULLO_METAL_PATCHED)
if(NOT YULLO_METAL_PATCHED EQUAL 0)
    message(FATAL_ERROR "ggml-metal-missing-pipeline.patch does not apply to the pinned ggml")
endif()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${YULLO_METAL_PATCH}")
get_target_property(YULLO_METAL_SOURCES ggml-metal SOURCES)
list(TRANSFORM YULLO_METAL_SOURCES REPLACE "^(.*/)?ggml-metal-(device|context)\\.m$"
    "${YULLO_GUARDED_METAL}/ggml-metal-\\2.m")
list(FILTER YULLO_METAL_SOURCES INCLUDE REGEX "ggml-metal-guarded/ggml-metal-(device|context)\\.m$")
list(LENGTH YULLO_METAL_SOURCES YULLO_GUARDED_COUNT)
if(NOT YULLO_GUARDED_COUNT EQUAL 2)
    message(FATAL_ERROR "The pinned ggml-metal target no longer lists the guarded files")
endif()
get_target_property(YULLO_METAL_SOURCES ggml-metal SOURCES)
list(TRANSFORM YULLO_METAL_SOURCES REPLACE "^(.*/)?ggml-metal-(device|context)\\.m$"
    "${YULLO_GUARDED_METAL}/ggml-metal-\\2.m")
set_property(TARGET ggml-metal PROPERTY SOURCES ${YULLO_METAL_SOURCES})
target_include_directories(ggml-metal PRIVATE "${YULLO_GGML_METAL}")
add_executable(yullo-llama yullo-llama.mm)
target_compile_features(yullo-llama PRIVATE cxx_std_17)
target_compile_options(yullo-llama PRIVATE -fobjc-arc)
target_link_libraries(yullo-llama PRIVATE llama "-framework Foundation")
