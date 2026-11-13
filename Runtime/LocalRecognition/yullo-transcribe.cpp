// App-owned entry point for the pinned transcribe.cpp CLI. The upstream CLI
// sources are compiled unchanged, with `main` and `transcribe_model_load_file`
// renamed, so ordinary invocations keep the upstream behavior.
//
// The upstream batch mode reads its list before loading the model. With
// --yullo-wait-audio the app can start this helper when recording begins: the
// model loads first, then one absolute WAV path line arrives on stdin, becomes
// the one-row batch list, and the upstream CLI runs with the loaded model.
#include "transcribe.h"

#include <cstring>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

int yullo_upstream_transcribe_main(int argc, char ** argv);

namespace yullo_transcribe {
constexpr const char * wait_flag = "--yullo-wait-audio";

transcribe_model * preloaded = nullptr;
std::string preloaded_path;
transcribe_model_load_params preloaded_params;

bool valid_audio_path(const std::string & path) {
    if (path.empty() || path[0] != '/' || path.size() > 4096) return false;
    for (const unsigned char byte : path) if (byte < 0x20 || byte == 0x7f) return false;
    return true;
}

// Options that change how the CLI loads its model or installs its log sink
// would differ from the early load, so waiting accepts only the app's form.
bool supported_while_waiting(const std::string & argument) {
    return argument != "--backend" && argument != "--device" && argument != "--no-mmap" &&
           argument != "--list-devices";
}
}

// The upstream CLI calls this in place of transcribe_model_load_file. It hands
// over the early-loaded model once, for the same path and load parameters.
extern "C" transcribe_status yullo_transcribe_model_load_file(
    const char * path, const transcribe_model_load_params * params, transcribe_model ** out_model) {
    using namespace yullo_transcribe;
    if (preloaded && path && params && out_model && preloaded_path == path &&
        params->backend == preloaded_params.backend && params->device == preloaded_params.device &&
        params->no_mmap == preloaded_params.no_mmap) {
        *out_model = preloaded;
        preloaded = nullptr;
        return TRANSCRIBE_OK;
    }
    if (preloaded) {
        transcribe_model_free(preloaded);
        preloaded = nullptr;
    }
    return transcribe_model_load_file(path, params, out_model);
}

int main(int argc, char ** argv) {
    using namespace yullo_transcribe;
    std::vector<char *> forwarded;
    std::string model, batch;
    bool waiting = false, quiet = false;
    for (int index = 0; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == wait_flag) {
            if (waiting) return 2;
            waiting = true;
            continue;
        }
        if ((argument == "--model" || argument == "-m") && index + 1 < argc) model = argv[index + 1];
        if (argument == "--batch" && index + 1 < argc) batch = argv[index + 1];
        if (argument == "--quiet") quiet = true;
        forwarded.push_back(argv[index]);
    }
    if (!waiting) return yullo_upstream_transcribe_main(argc, argv);
    for (const char * argument : forwarded) if (!supported_while_waiting(argument)) return 2;
    // The CLI installs no log sink with --quiet, so loading first is safe.
    if (!quiet || model.empty() || model[0] != '/' || batch.empty() || batch[0] != '/') return 2;
    transcribe_model_load_params_init(&preloaded_params);
    preloaded_path = model;
    // A failed early load leaves the CLI to load and report the error itself.
    if (transcribe_model_load_file(model.c_str(), &preloaded_params, &preloaded) != TRANSCRIBE_OK) preloaded = nullptr;
    // End of input before a path means the recording was cancelled.
    std::string path;
    if (!std::getline(std::cin, path) || !valid_audio_path(path)) {
        if (preloaded) transcribe_model_free(preloaded);
        return 3;
    }
    {
        std::ofstream list(batch, std::ios::binary | std::ios::trunc);
        list << path << '\n';
        if (!list) {
            if (preloaded) transcribe_model_free(preloaded);
            return 2;
        }
    }
    forwarded.push_back(nullptr);
    return yullo_upstream_transcribe_main(static_cast<int>(forwarded.size()) - 1, forwarded.data());
}
