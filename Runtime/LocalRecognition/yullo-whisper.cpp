// App-owned entry point for the pinned whisper.cpp CLI. Personal hints enter
// through a bounded private pipe, never the operating system's argument list.
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#ifndef YULLO_WHISPER_WRAPPER_TEST
#include "common-whisper.h"
// The upstream CLI loads its model before reading audio. With
// --yullo-wait-audio that read waits for the finished WAV's path on stdin, so
// the app can start this helper when recording begins.
bool yullo_whisper_read_audio(const std::string & fname, std::vector<float> & pcmf32,
                              std::vector<std::vector<float>> & pcmf32s, bool stereo);
#define main yullo_upstream_whisper_main
#define read_audio_data yullo_whisper_read_audio
#include YULLO_WHISPER_CLI_SOURCE
#undef read_audio_data
#undef main
#endif

namespace yullo_whisper {
constexpr size_t maximum_hint_bytes = 192;
constexpr size_t hint_context_tokens = maximum_hint_bytes + 1; // upstream reserves one previous-token marker
constexpr const char * hint_flag = "--yullo-hints-stdin";
constexpr const char * wait_flag = "--yullo-wait-audio";
bool waits_for_audio = false;

bool valid_hint(const std::string & text) {
    if (text.empty() || text.size() > maximum_hint_bytes || text.find("<|") != std::string::npos
        || text.find("|>") != std::string::npos) return false;
    bool non_space = false;
    for (size_t i = 0; i < text.size();) {
        const unsigned char first = static_cast<unsigned char>(text[i]);
        if (first < 0x20 || first == 0x7f) return false;
        if (first != ' ') non_space = true;
        size_t count = 0;
        unsigned int scalar = 0;
        if (first < 0x80) { count = 1; scalar = first; }
        else if (first >= 0xc2 && first <= 0xdf) { count = 2; scalar = first & 0x1f; }
        else if (first >= 0xe0 && first <= 0xef) { count = 3; scalar = first & 0x0f; }
        else if (first >= 0xf0 && first <= 0xf4) { count = 4; scalar = first & 0x07; }
        else return false;
        if (i + count > text.size()) return false;
        for (size_t j = 1; j < count; ++j) {
            const unsigned char next = static_cast<unsigned char>(text[i + j]);
            if ((next & 0xc0) != 0x80) return false;
            scalar = (scalar << 6) | (next & 0x3f);
        }
        if ((count == 2 && scalar < 0x80) || (count == 3 && scalar < 0x800)
            || (count == 4 && scalar < 0x10000) || scalar > 0x10ffff
            || (scalar >= 0xd800 && scalar <= 0xdfff) || (scalar >= 0x80 && scalar <= 0x9f)
            || scalar == 0x2028 || scalar == 0x2029) return false;
        i += count;
    }
    return non_space;
}

// A waiting helper's stdin carries the hints line (when requested), then one
// absolute WAV path line. Hints never contain control characters.
bool valid_audio_path(const std::string & path) {
    if (path.empty() || path[0] != '/' || path.size() > 4096) return false;
    for (const unsigned char byte : path) if (byte < 0x20 || byte == 0x7f) return false;
    return true;
}

std::vector<std::string> arguments(const std::vector<std::string> & supplied, std::istream & input) {
    std::vector<std::string> result;
    bool requested = false;
    bool waiting = false;
    for (const auto & argument : supplied) {
        if (argument == hint_flag) {
            if (requested) throw std::runtime_error("invalid vocabulary hints");
            requested = true;
        } else if (argument == wait_flag) {
            if (waiting) throw std::runtime_error("invalid audio wait");
            waiting = true;
        } else result.push_back(argument);
    }
    waits_for_audio = waiting;
    if (!requested) return result;
    std::string hints;
    char byte = 0;
    bool terminated = false;
    while (input.get(byte)) {
        if (waiting && byte == '\n') {
            terminated = true;
            break;
        }
        if (hints.size() == maximum_hint_bytes) throw std::runtime_error("invalid vocabulary hints");
        hints.push_back(byte);
    }
    if ((waiting ? !terminated : !input.eof()) || !valid_hint(hints))
        throw std::runtime_error("invalid vocabulary hints");
    // The upstream CLI sees these only in this process's private memory. The
    // last explicit budget wins; the caller cannot enlarge it through argv.
    result.insert(result.end(), {"--prompt", hints, "--carry-initial-prompt",
                                "--max-context", std::to_string(hint_context_tokens)});
    return result;
}
}

#ifndef YULLO_WHISPER_WRAPPER_TEST
bool yullo_whisper_read_audio(const std::string & fname, std::vector<float> & pcmf32,
                              std::vector<std::vector<float>> & pcmf32s, bool stereo) {
    if (!yullo_whisper::waits_for_audio) return read_audio_data(fname, pcmf32, pcmf32s, stereo);
    // End of input before a path means the recording was cancelled.
    std::string path;
    if (fname != "-" || !std::getline(std::cin, path) || !yullo_whisper::valid_audio_path(path)) return false;
    return read_audio_data(path, pcmf32, pcmf32s, stereo);
}

int main(int argc, char ** argv) {
    try {
        std::vector<std::string> supplied(argv, argv + argc);
        auto values = yullo_whisper::arguments(supplied, std::cin);
        std::vector<char *> forwarded;
        for (auto & value : values) forwarded.push_back(value.data());
        forwarded.push_back(nullptr);
        return yullo_upstream_whisper_main(static_cast<int>(values.size()), forwarded.data());
    } catch (const std::exception &) {
        // Never print the rejected values or personal terms.
        std::cerr << "error: invalid vocabulary hints\n";
        return 2;
    }
}
#endif
