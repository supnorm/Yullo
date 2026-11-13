cmake_minimum_required(VERSION 3.20)
project(YulloLocalSpeech LANGUAGES C CXX)
if(NOT YULLO_AUDIOCPP_SOURCE)
    message(FATAL_ERROR "A pinned audio.cpp source directory is required")
endif()
# The unmodified audio.cpp build supplies the runtime, eSpeak and its data package.
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
add_subdirectory("${YULLO_AUDIOCPP_SOURCE}" audiocpp EXCLUDE_FROM_ALL)
# Yullo's serve entry point reuses audio.cpp's own request parsing.
add_executable(yullo-speech
    yullo-speech.cpp
    "${YULLO_AUDIOCPP_SOURCE}/app/cli/args.cpp"
    "${YULLO_AUDIOCPP_SOURCE}/app/cli/request.cpp"
    "${YULLO_AUDIOCPP_SOURCE}/app/common/base64.cpp")
target_compile_features(yullo-speech PRIVATE cxx_std_17)
target_include_directories(yullo-speech PRIVATE "${YULLO_AUDIOCPP_SOURCE}")
target_link_libraries(yullo-speech PRIVATE engine_runtime ggml)
if(AUDIOCPP_STATIC_ESPEAK)
    audiocpp_stage_espeak(yullo-speech)
endif()
