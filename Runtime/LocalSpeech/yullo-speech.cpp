// Yullo's local speech helper keeps one audio.cpp text-to-speech session
// loaded for a sequence of independent requests from its parent app.
//
//   yullo-speech --family <family> --model <gguf> --backend cpu|metal --threads <n> --serve
//
// One compact JSON object per stdin line names a private request and output
// file inside this process's own working directory:
//   {"request": "<dir>/request.json", "out": "<dir>/speech.wav"}
// The request file holds a one-item audio.cpp request sequence, so passage text
// never enters arguments, the environment or this protocol. Each request gets
// one JSON answer line: {"complete": true} or {"error": "<code>"}. The helper
// exits at EOF; a synthesis failure exits, since the backend state is unknown.
#include "app/cli/args.h"
#include "app/cli/request.h"
#include "engine/framework/audio/wav_writer.h"
#include "engine/framework/io/json.h"
#include "engine/framework/runtime/registry.h"
#include "engine/framework/runtime/session.h"
#include "engine/framework/text/espeak_data.h"

#include <cstdio>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>
#include <unistd.h>

namespace {

constexpr size_t maximumLineBytes = 16'384;
std::FILE * protocol = nullptr;

void answer(const char * line) {
    std::fputs(line, protocol);
    std::fputc('\n', protocol);
    std::fflush(protocol);
}

std::filesystem::path privatePath(
    const engine::io::json::Value & line, const char * key, const std::filesystem::path & root) {
    const auto * value = line.find(key);
    if (value == nullptr || !value->is_string()) throw std::invalid_argument(key);
    const std::filesystem::path path(value->as_string());
    const auto relative = path.lexically_relative(root);
    if (!path.is_absolute() || path.lexically_normal() != path || relative.empty() || *relative.begin() == "..")
        throw std::invalid_argument(key);
    return path;
}

}  // namespace

int main(int argc, char ** argv) {
    // Runtime messages go to stderr; the original stdout carries only answers.
    const int protocolDescriptor = dup(STDOUT_FILENO);
    if (protocolDescriptor < 0 || dup2(STDERR_FILENO, STDOUT_FILENO) < 0) return 2;
    protocol = fdopen(protocolDescriptor, "w");
    if (protocol == nullptr) return 2;
    // The bundled default.metallib holds this ggml revision's ordinary kernels.
    // Its single-library runtime would select tensor-API dispatch on M5-class
    // GPUs, which only a source build compiles in, so keep the ordinary kernels.
    setenv("GGML_METAL_TENSOR_DISABLE", "1", 1);
    try {
        if (argc != 10 || std::string(argv[1]) != "--family" || std::string(argv[3]) != "--model" ||
            argv[4][0] != '/' || std::string(argv[5]) != "--backend" || std::string(argv[7]) != "--threads" ||
            std::string(argv[9]) != "--serve")
            throw std::invalid_argument("arguments");
        const int threads = std::stoi(argv[8]);
        if (threads < 1 || threads > 16) throw std::invalid_argument("threads");
        // Kokoro builds its eSpeak phonemizer for every passage, and given the
        // packaged data it re-reads and re-checks all of it each time. Unpack it
        // once into this process's private cache, the same validated directory
        // the phonemizer would use, and point eSpeak at that directory instead.
        if (const char * package = std::getenv("AUDIOCPP_ESPEAK_DATA")) {
            const std::filesystem::path data(package);
            if (data.extension() == ".bin" || data.extension() == ".gguf")
                setenv("AUDIOCPP_ESPEAK_DATA", engine::audio::materialize_espeak_data(data).c_str(), 1);
        }
        engine::runtime::ModelLoadRequest load;
        load.model_path = argv[4];
        load.family_hint = argv[2];
        engine::runtime::SessionOptions options;
        options.backend.type = minitts::cli::parse_backend(argv[6]);
        options.backend.threads = threads;
        const auto registry = engine::runtime::make_default_registry();
        const auto model = registry.load(load);
        const auto session = model->create_task_session(
            engine::runtime::TaskSpec{engine::runtime::VoiceTaskKind::Tts, engine::runtime::RunMode::Offline},
            options);
        engine::runtime::finish_model_load_trace();
        auto * offline = dynamic_cast<engine::runtime::IOfflineVoiceTaskSession *>(session.get());
        if (offline == nullptr) throw std::runtime_error("offline");
        const auto root = std::filesystem::current_path();
        std::string line;
        while (std::getline(std::cin, line)) {
            engine::runtime::TaskRequest request;
            std::filesystem::path output;
            try {
                if (line.size() > maximumLineBytes) throw std::invalid_argument("line");
                const auto value = engine::io::json::parse(line);
                if (!value.is_object()) throw std::invalid_argument("line");
                const auto input = privatePath(value, "request", root);
                output = privatePath(value, "out", root);
                const auto sequence = engine::io::json::parse_file(input);
                if (!sequence.is_array() || sequence.as_array().size() != 1) throw std::invalid_argument("request");
                request = minitts::cli::build_request_from_json(sequence.as_array().front(), input.parent_path());
                if (!request.text_input.has_value()) throw std::invalid_argument("request");
            } catch (const std::exception &) {
                answer("{\"error\":\"invalid_request\"}");
                continue;
            }
            session->prepare(engine::runtime::build_preparation_request(request));
            const auto result = offline->run(request);
            if (!result.audio_output.has_value() || result.audio_output->samples.empty())
                throw std::runtime_error("audio");
            const auto & audio = *result.audio_output;
            engine::audio::write_wav(output, audio.sample_rate, audio.channels, audio.samples);
            answer("{\"complete\":true}");
        }
        return 0;
    } catch (const std::exception &) {
        // Never echo an exception message: it could quote request content.
        answer("{\"error\":\"failed\"}");
        return 2;
    }
}
