// Independent PCM transport for the pinned transcribe.cpp C ABI. No capture,
// network, preferences or prompt context. One process owns one loaded model and
// serves one recording at a time: each begins with its own session identifier
// and ends with its final text or a cancellation; no audio or text carries over.
#include "transcribe.h"
#include "transcribe/parakeet.h"
#define DR_WAV_IMPLEMENTATION
#include "dr_wav.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cctype>
#include <cerrno>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <poll.h>
#include <signal.h>
#include <string>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {
using Clock = std::chrono::steady_clock;
constexpr size_t kWindow = 8 * 16000, kPending = 2 * 16000;
// Until the first words appear, decode after half a second instead of one.
constexpr uint64_t kFirstWindow = 8000, kNextWindow = 16000;
constexpr uint64_t kMaximumSamples = 1800ULL * 16000;
constexpr size_t kMaximumText = 262144, kMaximumFrame = 65537;

std::string quote(const std::string & text) {
    std::string value = "\"";
    for (unsigned char c : text) {
        if (c == '"' || c == '\\') { value += '\\'; value += char(c); }
        else if (c < 32) { char escaped[7]; std::snprintf(escaped, sizeof(escaped), "\\u%04x", c); value += escaped; }
        else value += char(c);
    }
    return value + '"';
}
std::string tail(const char * text, size_t length) {
    size_t start = length > 8192 ? length - 8192 : 0;
    while (start < length && (static_cast<unsigned char>(text[start]) & 0xc0) == 0x80) ++start;
    return std::string(text + start, length - start);
}
bool emit(const std::string & session, const std::string & body) {
    std::string line = "{\"session\":" + quote(session) + "," + body + "}\n";
    if (line.size() > 1048576) return false;
    return std::fwrite(line.data(), 1, line.size(), stdout) == line.size() && std::fflush(stdout) == 0;
}
struct State {
    std::mutex mutex;
    std::condition_variable changed;
    std::atomic<bool> cancelled{false}, finishing{false}, finalPass{false};
    std::atomic<double> deadline{0};
    bool native = false, completed = false;
    std::string finalPath, error;
    std::vector<float> pending, ring;
    size_t ringHead = 0, ringCount = 0;
    uint64_t received = 0;
    double energy = 0;
};
double monotonic() { return std::chrono::duration<double>(Clock::now().time_since_epoch()).count(); }
bool abort_decode(void * pointer) {
    auto & state = *static_cast<State *>(pointer);
    return state.cancelled.load() || (state.deadline.load() > 0 && monotonic() >= state.deadline.load()) ||
        (!state.native && state.finishing.load() && !state.finalPass.load());
}
bool read_exact(const std::atomic<bool> & stop, void * destination, size_t count) {
    auto * bytes = static_cast<unsigned char *>(destination);
    size_t offset = 0;
    while (offset < count && !stop.load()) {
        pollfd descriptor{STDIN_FILENO, POLLIN, 0};
        int ready = poll(&descriptor, 1, 50);
        if (ready < 0 && errno == EINTR) continue;
        if (ready < 0) return false;
        if (!ready) continue;
        ssize_t readCount = read(STDIN_FILENO, bytes + offset, count - offset);
        if (readCount > 0) offset += size_t(readCount);
        else if (readCount < 0 && errno == EINTR) continue;
        else return false;
    }
    return offset == count;
}
std::string status_code(transcribe_status status) {
    if (status == TRANSCRIBE_ERR_INPUT_TOO_LONG) return "tooLong";
    if (status == TRANSCRIBE_ERR_UNSUPPORTED_LANGUAGE) return "languageRequired";
    if (status == TRANSCRIBE_ERR_OUTPUT_TRUNCATED || status == TRANSCRIBE_ERR_OUTPUT_REPETITION) return "invalidOutput";
    return "failed";
}
std::vector<float> snapshot(State & state) {
    std::vector<float> result(state.ringCount);
    size_t first = std::min(state.ringCount, kWindow - state.ringHead);
    std::copy_n(state.ring.data() + state.ringHead, first, result.data());
    std::copy_n(state.ring.data(), state.ringCount - first, result.data() + first);
    return result;
}
bool load_final(const std::string & path, std::vector<float> & audio) {
    struct stat info{};
    if (path.empty() || path[0] != '/' || path.size() > 4096 || path.find('\0') != std::string::npos ||
        path.find('\n') != std::string::npos || path.find('\r') != std::string::npos ||
        stat(path.c_str(), &info) != 0 || !S_ISREG(info.st_mode) || info.st_size <= 0 || info.st_size > 60000000) return false;
    drwav wav{};
    if (!drwav_init_file(&wav, path.c_str(), nullptr)) return false;
    bool valid = wav.channels == 1 && wav.sampleRate == 16000 && wav.totalPCMFrameCount > 0 && wav.totalPCMFrameCount <= kMaximumSamples;
    if (valid) {
        audio.resize(size_t(wav.totalPCMFrameCount));
        valid = drwav_read_pcm_frames_f32(&wav, wav.totalPCMFrameCount, audio.data()) == wav.totalPCMFrameCount;
    }
    drwav_uninit(&wav);
    return valid && std::all_of(audio.begin(), audio.end(), [](float value) { return std::isfinite(value); });
}
void run_worker(State & state, transcribe_session * context, const transcribe_run_params & run,
                const std::string & architecture, const std::string & session) {
    uint64_t decoded = 0, revision = 0;
    std::string previous;
    auto nextDecode = Clock::now();
    int failedWindows = 0;
    auto fail = [&](const std::string & code) {
        { std::lock_guard<std::mutex> guard(state.mutex); if (state.error.empty()) state.error = code; }
        state.cancelled = true; state.changed.notify_all();
    };
    while (!state.cancelled.load()) {
        std::vector<float> audio;
        uint64_t cursor = 0;
        bool finish = false;
        {
            std::unique_lock<std::mutex> guard(state.mutex);
            if (state.native) {
                state.changed.wait(guard, [&] { return state.cancelled.load() || state.finishing.load() || !state.pending.empty(); });
                audio.swap(state.pending); finish = state.finishing.load() && audio.empty();
            } else {
                const uint64_t needed = revision == 0 ? kFirstWindow : kNextWindow;
                for (;;) {
                    if (state.cancelled.load() || state.finishing.load()) break;
                    if (state.received - decoded >= needed && Clock::now() >= nextDecode) break;
                    if (state.received - decoded >= needed) state.changed.wait_until(guard, nextDecode);
                    else state.changed.wait(guard);
                }
                finish = state.finishing.load();
                if (!finish && !state.cancelled.load()) {
                    cursor = state.received;
                    // Skip exact/near silence only; quiet speech stays eligible.
                    if (state.energy > 1e-8 * double(cursor - decoded)) audio = snapshot(state);
                    state.energy = 0; decoded = cursor;
                }
            }
        }
        if (state.cancelled.load()) break;
        if (finish) {
            state.finalPass = true;
            transcribe_status status;
            if (state.native) {
                transcribe_stream_update update; transcribe_stream_update_init(&update);
                state.deadline = monotonic() + 45;
                status = transcribe_stream_finalize(context, &update);
            } else {
                if (!load_final(state.finalPath, audio)) { fail("invalidAudio"); break; }
                if (architecture == "sensevoice" && audio.size() > 30 * 16000) { fail("senseVoiceTooLong"); break; }
                state.deadline = monotonic() + std::max(45.0, std::min(600.0, double(audio.size()) / 16000 * 3 + 45));
                status = transcribe_run(context, audio.data(), int(audio.size()), &run);
            }
            if (status != TRANSCRIBE_OK || transcribe_was_truncated(context)) { fail(status == TRANSCRIBE_OK ? "invalidOutput" : status_code(status)); break; }
            const char * pointer = transcribe_full_text(context);
            std::string text = pointer ? pointer : "";
            const bool empty = text.empty() || std::all_of(text.begin(), text.end(), [](unsigned char c) { return std::isspace(c); });
            if (empty || text.size() > kMaximumText) { fail(empty ? "noSpeech" : "invalidOutput"); break; }
            state.completed = emit(session, "\"type\":\"final\",\"text\":" + quote(text));
            if (!state.completed) fail("invalidOutput");
            break;
        }
        if (audio.empty()) continue;
        const auto began = Clock::now();
        state.deadline = monotonic() + (state.native ? 10 : 3);
        transcribe_status status;
        if (state.native) {
            transcribe_stream_update update; transcribe_stream_update_init(&update);
            status = transcribe_stream_feed(context, audio.data(), int(audio.size()), &update);
        } else status = transcribe_run(context, audio.data(), int(audio.size()), &run);
        const double duration = std::chrono::duration<double>(Clock::now() - began).count();
        const bool overBudget = state.deadline.load() > 0 && monotonic() >= state.deadline.load();
        state.deadline = 0;
        const double interval = std::max(revision == 0 ? 0.5 : 1.0, duration * 2.5);
        nextDecode = began + std::chrono::duration_cast<Clock::duration>(std::chrono::duration<double>(interval));
        if (!state.native && state.finishing.load()) continue; // Stop interrupted a provisional pass.
        if (overBudget) { fail("overloaded"); break; }
        if (status != TRANSCRIBE_OK || transcribe_was_truncated(context)) {
            if (!state.native && ++failedWindows < 3) continue;
            fail(status == TRANSCRIBE_OK ? "invalidOutput" : status_code(status)); break;
        }
        failedWindows = 0;
        const char * pointer = nullptr;
        size_t length = 0;
        if (state.native) {
            transcribe_stream_text view; transcribe_stream_text_init(&view);
            if (transcribe_stream_get_text(context, &view) == TRANSCRIBE_OK) {
                pointer = view.full_text; length = size_t(view.full_text_bytes);
            }
        } else { pointer = transcribe_full_text(context); length = pointer ? std::strlen(pointer) : 0; }
        std::string text = pointer ? tail(pointer, length) : "";
        if (!text.empty() && text != previous) {
            previous = text;
            if (!emit(session, "\"type\":\"partial\",\"revision\":" + std::to_string(++revision) + ",\"text\":" + quote(text))) { fail("failed"); break; }
        }
    }
}
bool read_frame(const std::atomic<bool> & stop, std::vector<unsigned char> & frame) {
    unsigned char header[4];
    if (!read_exact(stop, header, sizeof(header))) return false;
    uint32_t length = uint32_t(header[0]) | uint32_t(header[1]) << 8 | uint32_t(header[2]) << 16 | uint32_t(header[3]) << 24;
    if (length < 1 || length > kMaximumFrame) throw std::string("invalidOutput");
    frame.resize(length);
    if (!read_exact(stop, frame.data(), frame.size())) throw std::string("invalidOutput");
    return true;
}
bool valid_session(const std::string & session) {
    return session.size() == 36 &&
        std::all_of(session.begin(), session.end(), [](unsigned char c) { return std::isxdigit(c) || c == '-'; });
}
struct Runtime {
    transcribe_model * model = nullptr;
    transcribe_session * context = nullptr;
    transcribe_run_params run;
    std::string architecture;
    bool native = false;
};
// One recording. Returns true when the process can serve another: its final
// text was written, or the app cancelled it. Errors are reported for this session.
bool serve_recording(Runtime & runtime, const std::string & session) {
    State state;
    state.native = runtime.native;
    if (!state.native) state.ring.resize(kWindow);
    transcribe_set_abort_callback(runtime.context, abort_decode, &state);
    bool abandoned = false;
    try {
        if (state.native) {
            transcribe_stream_params stream; transcribe_stream_params_init(&stream);
            transcribe_parakeet_stream_ext ext; transcribe_parakeet_stream_ext_init(&ext);
            if (transcribe_model_accepts_ext_kind(runtime.model, TRANSCRIBE_EXT_SLOT_STREAM, TRANSCRIBE_EXT_KIND_PARAKEET_STREAM)) {
                ext.att_context_right = 13; stream.family = &ext.ext;
            }
            transcribe_status status = transcribe_stream_begin(runtime.context, &runtime.run, &stream);
            if (status != TRANSCRIBE_OK) throw status_code(status);
        }
        if (!emit(session, "\"type\":\"ready\",\"version\":2,\"mode\":" + quote(state.native ? "stream" : "window"))) throw std::string("failed");
        std::thread worker([&] {
            try { run_worker(state, runtime.context, runtime.run, runtime.architecture, session); }
            catch (...) { std::lock_guard<std::mutex> guard(state.mutex); state.error = "failed"; state.cancelled = true; state.changed.notify_all(); }
        });
        try {
            std::vector<unsigned char> frame;
            while (!state.cancelled.load()) {
                if (!read_frame(state.cancelled, frame)) break;
                if (frame[0] == 4 && frame.size() == 1) { abandoned = true; break; }
                if (frame[0] == 2) {
                    std::string path(reinterpret_cast<const char *>(frame.data() + 1), frame.size() - 1);
                    if (path.empty() || path[0] != '/' || path.size() > 4096 || path.find('\0') != std::string::npos ||
                        path.find('\n') != std::string::npos || path.find('\r') != std::string::npos) throw std::string("invalidAudio");
                    { std::lock_guard<std::mutex> guard(state.mutex); state.finalPath = path; state.finishing = true; }
                    state.changed.notify_all(); break;
                }
                if (frame[0] != 1 || frame.size() <= 1 || (frame.size() - 1) % sizeof(float) != 0) throw std::string("invalidAudio");
                size_t count = (frame.size() - 1) / sizeof(float);
                std::vector<float> samples(count); std::memcpy(samples.data(), frame.data() + 1, count * sizeof(float));
                if (!std::all_of(samples.begin(), samples.end(), [](float sample) { return std::isfinite(sample) && sample >= -1 && sample <= 1; })) throw std::string("invalidAudio");
                {
                    std::lock_guard<std::mutex> guard(state.mutex);
                    if (state.received + count > kMaximumSamples) throw std::string("tooLong");
                    state.received += count;
                    if (state.native) {
                        if (state.pending.size() + count > kPending) throw std::string("overloaded");
                        state.pending.insert(state.pending.end(), samples.begin(), samples.end());
                    } else for (float sample : samples) {
                        if (state.ringCount < kWindow) state.ring[(state.ringHead + state.ringCount++) % kWindow] = sample;
                        else { state.ring[state.ringHead] = sample; state.ringHead = (state.ringHead + 1) % kWindow; }
                        state.energy += double(sample) * sample;
                    }
                }
                state.changed.notify_all();
            }
        } catch (const std::string & error) {
            { std::lock_guard<std::mutex> guard(state.mutex); state.error = error; }
            state.cancelled = true;
        } catch (...) { state.cancelled = true; }
        if (abandoned || !state.finishing.load()) state.cancelled = true;
        state.changed.notify_all(); worker.join();
        transcribe_set_abort_callback(runtime.context, nullptr, nullptr);
        if (abandoned) {
            if (state.native) transcribe_stream_reset(runtime.context);
            return emit(session, "\"type\":\"cancelled\"");
        }
        if (state.completed) return true;
        throw state.error.empty() ? std::string("failed") : state.error;
    } catch (const std::string & error) { emit(session, "\"type\":\"error\",\"code\":" + quote(error)); }
    catch (...) { emit(session, "\"type\":\"error\",\"code\":\"failed\""); }
    transcribe_set_abort_callback(runtime.context, nullptr, nullptr);
    return false;
}
} // namespace

// Usage: --model PATH --language auto|CODE --serve. Frames on stdin: 3 begins a
// recording with its 36-byte session identifier, 1 carries PCM, 2 finishes it
// with the captured WAV path and 4 cancels it. End of input while idle exits.
int main(int argc, char ** argv) {
    signal(SIGPIPE, SIG_IGN);
    std::string modelPath, language;
    bool serve = false;
    for (int i = 1; i < argc; ++i) {
        std::string key = argv[i];
        if (key == "--serve") { serve = true; continue; }
        if (i + 1 >= argc) return 2;
        if (key == "--model") modelPath = argv[++i];
        else if (key == "--language") language = argv[++i];
        else return 2;
    }
    if (argc != 6 || !serve || modelPath.empty() || modelPath[0] != '/' ||
        (language != "auto" && (language.size() < 2 || language.size() > 3 || !std::all_of(language.begin(), language.end(), [](char c) { return c >= 'a' && c <= 'z'; })))) return 2;
    transcribe_log_set(nullptr, nullptr);
    Runtime runtime;
    int result = 1;
    std::string session;
    try {
        transcribe_status status = transcribe_model_load_file(modelPath.c_str(), nullptr, &runtime.model);
        if (status != TRANSCRIBE_OK) throw std::string("failed");
        const char * arch = transcribe_model_arch_string(runtime.model);
        runtime.architecture = arch ? arch : "";
        const std::string & architecture = runtime.architecture;
        if (architecture != "qwen3_asr" && architecture != "parakeet" && architecture != "sensevoice" && architecture != "cohere_asr") throw std::string("unsupported");
        if (architecture == "cohere_asr" && language == "auto") throw std::string("languageRequired");
        transcribe_session_params params; transcribe_session_params_init(&params); params.n_threads = 4;
        status = transcribe_session_init(runtime.model, &params, &runtime.context);
        if (status != TRANSCRIBE_OK) throw std::string("failed");
        transcribe_run_params_init(&runtime.run); runtime.run.language = language == "auto" ? nullptr : language.c_str();
        transcribe_capabilities caps; transcribe_capabilities_init(&caps); transcribe_model_get_capabilities(runtime.model, &caps);
        runtime.native = caps.supports_streaming;
        const std::atomic<bool> idle{false};
        std::vector<unsigned char> frame;
        for (;;) {
            session.clear();
            if (!read_frame(idle, frame)) { result = 0; break; }
            std::string identifier(reinterpret_cast<const char *>(frame.data() + 1), frame.size() - 1);
            if (frame[0] != 3 || !valid_session(identifier)) throw std::string("invalidOutput");
            session = identifier;
            if (!serve_recording(runtime, session)) break;
        }
    } catch (const std::string & error) { emit(session, "\"type\":\"error\",\"code\":" + quote(error)); }
    catch (...) { emit(session, "\"type\":\"error\",\"code\":\"failed\""); }
    if (runtime.context) transcribe_session_free(runtime.context);
    if (runtime.model) transcribe_model_free(runtime.model);
    return result;
}
