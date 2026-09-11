#include "parso.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <limits>
#include <signal.h>
#include <string>
#include <thread>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <vector>

namespace {

constexpr uint32_t kSampleRate = 48000;
constexpr uint32_t kBlockFrames = 256;
constexpr uint32_t kQueueBlocks = 64;
constexpr uint32_t kMaxSeconds = 3600;
constexpr uint32_t kDefaultMaxRecoveries = 8;

struct Options {
    uint32_t seconds = 5;
    bool noDevice = false;
    bool capture = false;
    std::string inputPath;
    std::string outputTarget;
    std::string monitorTarget;
    std::string boothTarget;
    std::string captureTarget;
    std::string recordPath;
    std::string pipeWireCommand = "pw-cat";
    uint32_t maxRecoveries = kDefaultMaxRecoveries;
};

struct Block {
    std::array<float, kBlockFrames> left{};
    std::array<float, kBlockFrames> right{};
};

// A fixed-size single-producer/single-consumer block queue. The render loop
// never waits for an OS stream and the PipeWire worker never enters the engine.
class BlockQueue final {
public:
    bool beginWrite(Block **block) noexcept {
        const uint64_t write = writeIndex_.load(std::memory_order_relaxed);
        if (write - readIndex_.load(std::memory_order_acquire) >= kQueueBlocks) {
            return false;
        }
        pendingWrite_ = write;
        *block = &blocks_[write % kQueueBlocks];
        return true;
    }

    void endWrite() noexcept {
        writeIndex_.store(pendingWrite_ + 1, std::memory_order_release);
    }

    bool beginRead(const Block **block) noexcept {
        const uint64_t read = readIndex_.load(std::memory_order_relaxed);
        if (read == writeIndex_.load(std::memory_order_acquire)) return false;
        pendingRead_ = read;
        *block = &blocks_[read % kQueueBlocks];
        return true;
    }

    void endRead() noexcept {
        readIndex_.store(pendingRead_ + 1, std::memory_order_release);
    }

    uint64_t readable() const noexcept {
        return writeIndex_.load(std::memory_order_acquire) -
               readIndex_.load(std::memory_order_acquire);
    }

private:
    std::array<Block, kQueueBlocks> blocks_{};
    std::atomic<uint64_t> writeIndex_{0};
    std::atomic<uint64_t> readIndex_{0};
    uint64_t pendingWrite_ = 0;
    uint64_t pendingRead_ = 0;
};

bool parseUnsigned(const char *text, uint32_t *value) noexcept {
    if (!text || !*text || !value) return false;
    uint64_t parsed = 0;
    for (const char *cursor = text; *cursor; ++cursor) {
        if (*cursor < '0' || *cursor > '9') return false;
        parsed = parsed * 10u + static_cast<uint32_t>(*cursor - '0');
        if (parsed > kMaxSeconds) return false;
    }
    if (parsed == 0) return false;
    *value = static_cast<uint32_t>(parsed);
    return true;
}

bool parseOptions(int argc, char **argv, Options *options) {
    if (!options) return false;
    for (int index = 1; index < argc; ++index) {
        const std::string argument(argv[index]);
        auto next = [&](std::string *value) {
            if (index + 1 >= argc || !value) return false;
            *value = argv[++index];
            return true;
        };
        if (argument == "--help") {
            std::printf(
                "usage: %s [--seconds N] [--input-wav PATH] [--record PATH]\n"
                "       [--output-target NAME] [--monitor-target NAME]\n"
                "       [--booth-target NAME] [--capture [--capture-target NAME]]\n"
                "       [--pw-cat PATH] [--max-recoveries N]\n"
                "       [--no-device]\n", argv[0]);
            return false;
        }
        if (argument == "--no-device") {
            options->noDevice = true;
        } else if (argument == "--capture") {
            options->capture = true;
        } else if (argument == "--seconds") {
            std::string value;
            uint32_t seconds = 0;
            if (!next(&value) || !parseUnsigned(value.c_str(), &seconds)) return false;
            options->seconds = seconds;
        } else if (argument == "--input-wav") {
            if (!next(&options->inputPath)) return false;
        } else if (argument == "--output-target") {
            if (!next(&options->outputTarget)) return false;
        } else if (argument == "--monitor-target") {
            if (!next(&options->monitorTarget)) return false;
        } else if (argument == "--booth-target") {
            if (!next(&options->boothTarget)) return false;
        } else if (argument == "--capture-target") {
            if (!next(&options->captureTarget)) return false;
            options->capture = true;
        } else if (argument == "--record") {
            if (!next(&options->recordPath)) return false;
        } else if (argument == "--pw-cat") {
            if (!next(&options->pipeWireCommand)) return false;
        } else if (argument == "--max-recoveries") {
            std::string value;
            if (!next(&value) || !parseUnsigned(value.c_str(), &options->maxRecoveries)) return false;
        } else {
            return false;
        }
    }
    if (!options->capture) options->captureTarget.clear();
    return true;
}

bool requireStatus(parso_status_t status, const char *operation) noexcept {
    if (status == PARSO_STATUS_OK) return true;
    std::fprintf(stderr, "linux_pipewire_host: %s: %s (%s)\n", operation,
                 parso_status_string(status), parso_last_error());
    return false;
}

bool pipeWireTargetExists(const std::string &target) {
    if (target.empty()) return true;
    FILE *listing = popen("pw-cli ls Node", "r");
    if (!listing) return false;
    bool found = false;
    std::array<char, 512> line{};
    while (fgets(line.data(), static_cast<int>(line.size()), listing)) {
        if (std::strstr(line.data(), target.c_str())) found = true;
    }
    const int status = pclose(listing);
    return found && status == 0;
}

class ChildStream final {
public:
    bool start(bool playback, const std::string &target,
               const std::string &command = "pw-cat") {
        int descriptors[2] = {-1, -1};
        if (pipe(descriptors) != 0) return false;
        const pid_t child = fork();
        if (child < 0) {
            close(descriptors[0]);
            close(descriptors[1]);
            return false;
        }
        if (child == 0) {
            const int streamFd = playback ? descriptors[0] : descriptors[1];
            if (dup2(streamFd, playback ? STDIN_FILENO : STDOUT_FILENO) < 0) _exit(127);
            close(descriptors[0]);
            close(descriptors[1]);

            std::vector<std::string> arguments{
                command, playback ? "--playback" : "--record", "--raw",
                "--format", "f32", "--rate", "48000", "--channels", "2",
                "--channel-map", "FL,FR", "--latency", "256"
            };
            if (!target.empty()) {
                arguments.push_back("--target");
                arguments.push_back(target);
            }
            arguments.emplace_back("-");
            std::vector<char *> pointers;
            pointers.reserve(arguments.size() + 1);
            for (std::string &argument : arguments) pointers.push_back(argument.data());
            pointers.push_back(nullptr);
            execvp(pointers[0], pointers.data());
            _exit(127);
        }
        pid_ = child;
        fd_ = playback ? descriptors[1] : descriptors[0];
        close(playback ? descriptors[0] : descriptors[1]);
        playback_ = playback;
        target_ = target;
        command_ = command;
        return true;
    }

    int fd() const noexcept { return fd_; }

    bool writeAll(const float *left, const float *right) noexcept {
        std::array<float, kBlockFrames * 2u> interleaved{};
        for (uint32_t frame = 0; frame < kBlockFrames; ++frame) {
            interleaved[frame * 2u] = left[frame];
            interleaved[frame * 2u + 1u] = right[frame];
        }
        return writeBytes(interleaved.data(), sizeof(interleaved));
    }

    bool readAll(float *interleaved) noexcept {
        auto *bytes = reinterpret_cast<uint8_t *>(interleaved);
        std::size_t remaining = sizeof(float) * kBlockFrames * 2u;
        while (remaining > 0) {
            const ssize_t count = read(fd_, bytes, remaining);
            if (count == 0) return false;
            if (count < 0) {
                if (errno == EINTR) continue;
                return false;
            }
            bytes += count;
            remaining -= static_cast<std::size_t>(count);
        }
        return true;
    }

    void closeDescriptor() noexcept {
        if (fd_ >= 0) {
            close(fd_);
            fd_ = -1;
        }
    }

    void requestStop() noexcept {
        const pid_t child = pid_.load(std::memory_order_acquire);
        if (child > 0) kill(child, SIGTERM);
    }

    bool restart() {
        closeDescriptor();
        terminateChild();
        return start(playback_, target_, command_);
    }

    void stop() noexcept {
        closeDescriptor();
        terminateChild();
    }

private:
    void terminateChild() noexcept {
        const pid_t child = pid_.exchange(-1, std::memory_order_acq_rel);
        if (child <= 0) return;
        kill(child, SIGTERM);
        int status = 0;
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    }
    bool writeBytes(const void *data, std::size_t size) noexcept {
        const auto *bytes = static_cast<const uint8_t *>(data);
        while (size > 0) {
            const ssize_t count = write(fd_, bytes, size);
            if (count < 0) {
                if (errno == EINTR) continue;
                return false;
            }
            if (count == 0) return false;
            bytes += count;
            size -= static_cast<std::size_t>(count);
        }
        return true;
    }

    int fd_ = -1;
    std::atomic<pid_t> pid_{-1};
    bool playback_ = false;
    std::string target_;
    std::string command_ = "pw-cat";
};

bool recoverStream(ChildStream *stream, std::atomic<bool> *stop,
                   std::atomic<bool> *failed, std::atomic<uint32_t> *recoveries,
                   uint32_t maxRecoveries, const char *label) {
    for (uint32_t attempt = 1; attempt <= maxRecoveries; ++attempt) {
        if (stop->load(std::memory_order_acquire)) return false;
        std::this_thread::sleep_for(std::chrono::milliseconds(10u * attempt));
        if (stop->load(std::memory_order_acquire)) return false;
        if (stream->restart()) {
            recoveries->fetch_add(1, std::memory_order_relaxed);
            std::fprintf(stderr, "linux_pipewire_host: recovered %s stream (attempt %u)\n",
                         label, attempt);
            return true;
        }
    }
    failed->store(true, std::memory_order_release);
    std::fprintf(stderr, "linux_pipewire_host: unable to recover %s stream after %u attempts\n",
                 label, maxRecoveries);
    return false;
}

void outputWorker(BlockQueue *queue, ChildStream *stream,
                  std::atomic<bool> *stop, std::atomic<bool> *failed,
                  std::atomic<uint32_t> *recoveries, uint32_t maxRecoveries,
                  const char *label) {
    const Block *block = nullptr;
    while (!stop->load(std::memory_order_acquire) || queue->readable() != 0) {
        if (!queue->beginRead(&block)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            continue;
        }
        if (!stream->writeAll(block->left.data(), block->right.data())) {
            queue->endRead();
            if (stop->load(std::memory_order_acquire)) return;
            if (!recoverStream(stream, stop, failed, recoveries, maxRecoveries, label)) return;
            continue;
        }
        queue->endRead();
    }
}

void captureWorker(BlockQueue *queue, ChildStream *stream,
                   std::atomic<bool> *stop, std::atomic<bool> *failed,
                   std::atomic<uint32_t> *recoveries, uint32_t maxRecoveries,
                   const char *label, std::atomic<uint64_t> *blocks) {
    std::array<float, kBlockFrames * 2u> interleaved{};
    while (!stop->load(std::memory_order_acquire)) {
        if (!stream->readAll(interleaved.data())) {
            if (stop->load(std::memory_order_acquire)) return;
            if (!recoverStream(stream, stop, failed, recoveries, maxRecoveries, label)) return;
            continue;
        }
        Block *block = nullptr;
        if (queue->beginWrite(&block)) {
            for (uint32_t frame = 0; frame < kBlockFrames; ++frame) {
                block->left[frame] = interleaved[frame * 2u];
                block->right[frame] = interleaved[frame * 2u + 1u];
            }
            queue->endWrite();
            blocks->fetch_add(1, std::memory_order_relaxed);
        }
    }
}

bool writeRecording(const std::string &path, const std::vector<float> &left,
                    const std::vector<float> &right) {
    if (path.empty()) return true;
    std::vector<float> interleaved(left.size() * 2u);
    for (std::size_t index = 0; index < left.size(); ++index) {
        interleaved[index * 2u] = left[index];
        interleaved[index * 2u + 1u] = right[index];
    }
    parso_pcm_buffer_t buffer;
    parso_bytes_t bytes;
    if (!requireStatus(parso_pcm_buffer_init(&buffer), "record PCM init") ||
        !requireStatus(parso_bytes_init(&bytes), "record bytes init")) return false;
    buffer.samples = interleaved.data();
    buffer.frames = left.size();
    buffer.channel_count = 2;
    buffer.sample_rate_hz = kSampleRate;
    const bool encoded = requireStatus(parso_wav_write(&buffer, 32, 1, &bytes),
                                       "record WAV encode");
    bool ok = encoded;
    if (encoded) {
        std::ofstream file(path, std::ios::binary);
        if (!file) {
            std::fprintf(stderr, "linux_pipewire_host: cannot open %s\n", path.c_str());
            ok = false;
        } else {
            file.write(reinterpret_cast<const char *>(bytes.data),
                       static_cast<std::streamsize>(bytes.size_bytes));
            ok = static_cast<bool>(file);
        }
    }
    parso_bytes_release(&bytes);
    buffer.samples = nullptr;
    parso_pcm_buffer_release(&buffer);
    return ok;
}

bool loadInput(const Options &options, std::vector<float> *generated,
               parso_pcm_buffer_t *decoded, parso_pcm_view_t *view,
               const float *planes[2], uint64_t targetFrames) {
    if (targetFrames == 0 || targetFrames > std::numeric_limits<std::size_t>::max()) {
        return false;
    }
    if (options.inputPath.empty()) {
        generated->resize(static_cast<std::size_t>(targetFrames));
        for (uint64_t frame = 0; frame < targetFrames; ++frame) {
            (*generated)[frame] = 0.15f * std::sin(static_cast<float>(
                2.0 * 3.141592653589793 * 220.0 * frame / kSampleRate));
        }
        planes[0] = generated->data();
        if (!requireStatus(parso_pcm_view_init(view), "generated view init")) return false;
        view->planes = planes;
        view->frames = targetFrames;
        view->channel_count = 1;
        view->sample_rate_hz = kSampleRate;
        return true;
    }

    std::ifstream file(options.inputPath, std::ios::binary);
    if (!file) return false;
    const std::vector<char> data((std::istreambuf_iterator<char>(file)),
                                 std::istreambuf_iterator<char>());
    if (!requireStatus(parso_pcm_buffer_init(decoded), "input PCM init") ||
        !requireStatus(parso_wav_read(reinterpret_cast<const uint8_t *>(data.data()), data.size(),
                                      decoded), "input WAV read")) return false;
    if (decoded->channel_count < 1 || decoded->channel_count > 2 || decoded->frames == 0) {
        return false;
    }
    // The public WAV reader returns interleaved owned samples. Repeat the
    // source into caller-owned planar storage so a short test clip remains a
    // continuous live deck for the complete requested session.
    const uint64_t sourceFrames = decoded->frames;
    const uint64_t channels = decoded->channel_count;
    if (targetFrames > std::numeric_limits<std::size_t>::max() / channels) return false;
    generated->resize(static_cast<std::size_t>(targetFrames * channels));
    if (decoded->channel_count == 1) {
        for (uint64_t frame = 0; frame < targetFrames; ++frame) {
            (*generated)[frame] = decoded->samples[frame % sourceFrames];
        }
        planes[0] = generated->data();
        planes[1] = generated->data();
    } else {
        for (uint64_t frame = 0; frame < targetFrames; ++frame) {
            const uint64_t sourceFrame = frame % sourceFrames;
            (*generated)[frame] = decoded->samples[sourceFrame * 2u];
            (*generated)[targetFrames + frame] = decoded->samples[sourceFrame * 2u + 1u];
        }
        planes[0] = generated->data();
        planes[1] = generated->data() + targetFrames;
    }
    if (!requireStatus(parso_pcm_view_init(view), "input view init")) return false;
    view->planes = planes;
    view->frames = targetFrames;
    view->channel_count = decoded->channel_count;
    view->sample_rate_hz = decoded->sample_rate_hz;
    return true;
}

bool startOutput(const std::string &target, const std::string &command,
                 ChildStream *stream) {
    if (target.empty() && stream == nullptr) return false;
    return stream->start(true, target, command);
}

} // namespace

int main(int argc, char **argv) {
    Options options;
    if (!parseOptions(argc, argv, &options)) return argc > 1 && std::string(argv[1]) == "--help" ? 0 : 2;
    signal(SIGPIPE, SIG_IGN);

    const uint64_t totalFrames = static_cast<uint64_t>(options.seconds) * kSampleRate;
    std::vector<float> source;
    parso_pcm_buffer_t decoded{};
    parso_pcm_view_t sourceView{};
    const float *sourcePlanes[2] = {nullptr, nullptr};
    if (!loadInput(options, &source, &decoded, &sourceView, sourcePlanes, totalFrames)) {
        std::fprintf(stderr, "linux_pipewire_host: failed to load input WAV\n");
        parso_pcm_buffer_release(&decoded);
        return 1;
    }

    parso_engine_options_t engineOptions;
    parso_control_t control;
    parso_command_t play;
    parso_output_view_t outputView;
    if (!requireStatus(parso_engine_options_init(&engineOptions), "options init") ||
        !requireStatus(parso_control_init(&control), "control init") ||
        !requireStatus(parso_command_init(&play), "command init") ||
        !requireStatus(parso_output_view_init(&outputView), "output init")) return 1;
    engineOptions.sample_rate_hz = kSampleRate;
    engineOptions.max_frames = kBlockFrames;
    control.mic_level = options.capture ? 0.25f : 0.0f;
    play.type = PARSO_COMMAND_PLAY;
    play.deck = 0;

    parso_engine_t *engine = nullptr;
    if (!requireStatus(parso_engine_create(&engineOptions, &engine), "engine create") ||
        !requireStatus(parso_engine_set_control(engine, &control), "set control") ||
        !requireStatus(parso_engine_set_deck_buffer(engine, 0, &sourceView), "set deck") ||
        !requireStatus(parso_engine_post_command(engine, &play), "play")) {
        parso_engine_destroy(&engine);
        parso_pcm_buffer_release(&decoded);
        return 1;
    }

    ChildStream outputStream;
    ChildStream monitorStream;
    ChildStream boothStream;
    ChildStream captureStream;
    const bool useDevice = !options.noDevice;
    if (useDevice &&
        (!pipeWireTargetExists(options.outputTarget) ||
         !pipeWireTargetExists(options.monitorTarget) ||
         !pipeWireTargetExists(options.boothTarget) ||
         !pipeWireTargetExists(options.captureTarget))) {
        std::fprintf(stderr, "linux_pipewire_host: requested PipeWire target was not found\n");
        parso_engine_destroy(&engine);
        parso_pcm_buffer_release(&decoded);
        return 1;
    }
    if (useDevice &&
        (!startOutput(options.outputTarget, options.pipeWireCommand, &outputStream) ||
         (!options.monitorTarget.empty() &&
          !startOutput(options.monitorTarget, options.pipeWireCommand, &monitorStream)) ||
         (!options.boothTarget.empty() &&
          !startOutput(options.boothTarget, options.pipeWireCommand, &boothStream)) ||
         (options.capture &&
          !captureStream.start(false, options.captureTarget, options.pipeWireCommand)))) {
        std::fprintf(stderr, "linux_pipewire_host: failed to start a PipeWire stream\n");
        captureStream.stop();
        boothStream.stop();
        monitorStream.stop();
        outputStream.stop();
        parso_engine_destroy(&engine);
        parso_pcm_buffer_release(&decoded);
        return 1;
    }

    BlockQueue outputQueue;
    BlockQueue monitorQueue;
    BlockQueue boothQueue;
    BlockQueue captureQueue;
    std::atomic<bool> stop{false};
    std::atomic<bool> streamFailed{false};
    std::atomic<uint32_t> streamRecoveries{0};
    std::atomic<uint64_t> capturedBlocks{0};
    std::thread outputThread;
    std::thread monitorThread;
    std::thread boothThread;
    std::thread captureThread;
    if (useDevice) {
        outputThread = std::thread(outputWorker, &outputQueue, &outputStream, &stop,
                                   &streamFailed, &streamRecoveries,
                                   options.maxRecoveries, "master");
        if (!options.monitorTarget.empty()) {
            monitorThread = std::thread(outputWorker, &monitorQueue, &monitorStream,
                                        &stop, &streamFailed, &streamRecoveries,
                                        options.maxRecoveries, "monitor");
        }
        if (!options.boothTarget.empty()) {
            boothThread = std::thread(outputWorker, &boothQueue, &boothStream,
                                      &stop, &streamFailed, &streamRecoveries,
                                      options.maxRecoveries, "booth");
        }
        if (options.capture) {
            captureThread = std::thread(captureWorker, &captureQueue, &captureStream,
                                        &stop, &streamFailed, &streamRecoveries,
                                        options.maxRecoveries, "capture", &capturedBlocks);
        }
    }

    std::vector<float> recordedLeft;
    std::vector<float> recordedRight;
    if (!options.recordPath.empty()) {
        recordedLeft.resize(totalFrames);
        recordedRight.resize(totalFrames);
        if (!requireStatus(parso_engine_record_reset(engine), "record reset") ||
            !requireStatus(parso_engine_record_set_active(engine, 1), "record active")) {
            stop.store(true, std::memory_order_release);
        }
    }

    std::array<float, kBlockFrames> masterLeft{};
    std::array<float, kBlockFrames> masterRight{};
    std::array<float, kBlockFrames> monitorLeft{};
    std::array<float, kBlockFrames> monitorRight{};
    std::array<float, kBlockFrames> boothLeft{};
    std::array<float, kBlockFrames> boothRight{};
    std::array<float, kBlockFrames> silent{};
    uint64_t rendered = 0;
    uint64_t recorded = 0;
    uint64_t droppedBlocks = 0;
    float maxPeak = 0.0f;
    const auto startTime = std::chrono::steady_clock::now();
    while (!stop.load(std::memory_order_acquire) && rendered < totalFrames) {
        const uint32_t frames = static_cast<uint32_t>(
            std::min<uint64_t>(kBlockFrames, totalFrames - rendered));
        const parso_pcm_view_t *micView = nullptr;
        const Block *captureBlock = nullptr;
        parso_pcm_view_t micViewValue;
        const float *micPlanes[2] = {silent.data(), silent.data()};
        if (options.capture && captureQueue.beginRead(&captureBlock)) {
            micPlanes[0] = captureBlock->left.data();
            micPlanes[1] = captureBlock->right.data();
            if (requireStatus(parso_pcm_view_init(&micViewValue), "mic view init")) {
                micViewValue.planes = micPlanes;
                micViewValue.frames = kBlockFrames;
                micViewValue.channel_count = 2;
                micViewValue.sample_rate_hz = kSampleRate;
                micView = &micViewValue;
            }
        }
        if (options.capture && !micView) {
            if (requireStatus(parso_pcm_view_init(&micViewValue), "silent mic view init")) {
                micViewValue.planes = micPlanes;
                micViewValue.frames = kBlockFrames;
                micViewValue.channel_count = 2;
                micViewValue.sample_rate_hz = kSampleRate;
                micView = &micViewValue;
            }
        }
        if (micView && !requireStatus(parso_engine_set_mic_buffer(engine, micView), "set mic")) {
            stop.store(true, std::memory_order_release);
        }

        outputView.left = masterLeft.data();
        outputView.right = masterRight.data();
        outputView.frames = frames;
        const bool masterOk = requireStatus(parso_engine_render(engine, &outputView),
                                            "render master");
        outputView.left = monitorLeft.data();
        outputView.right = monitorRight.data();
        const bool monitorOk = requireStatus(parso_engine_render_monitor(engine, &outputView),
                                             "render monitor");
        outputView.left = boothLeft.data();
        outputView.right = boothRight.data();
        const bool boothOk = requireStatus(parso_engine_render_booth(engine, &outputView),
                                           "render booth");
        for (uint32_t index = 0; index < frames; ++index) {
            maxPeak = std::max(maxPeak, std::max(std::fabs(masterLeft[index]),
                                                  std::fabs(masterRight[index])));
        }
        if (!masterOk || !monitorOk || !boothOk) {
            stop.store(true, std::memory_order_release);
        }
        if (captureBlock) captureQueue.endRead();

        // The monitor and booth renders above intentionally use separate
        // caller-owned arrays in device mode; master output remains untouched.
        if (!stop.load(std::memory_order_acquire)) {
            if (useDevice) {
                Block *outputBlock = nullptr;
                if (outputQueue.beginWrite(&outputBlock)) {
                    std::copy_n(masterLeft.begin(), frames, outputBlock->left.begin());
                    std::copy_n(masterRight.begin(), frames, outputBlock->right.begin());
                    std::fill(outputBlock->left.begin() + frames, outputBlock->left.end(), 0.0f);
                    std::fill(outputBlock->right.begin() + frames, outputBlock->right.end(), 0.0f);
                    outputQueue.endWrite();
                } else {
                    ++droppedBlocks;
                }
                if (!options.monitorTarget.empty()) {
                    Block *monitorBlock = nullptr;
                    if (monitorQueue.beginWrite(&monitorBlock)) {
                        std::copy_n(monitorLeft.begin(), frames, monitorBlock->left.begin());
                        std::copy_n(monitorRight.begin(), frames, monitorBlock->right.begin());
                        monitorQueue.endWrite();
                    }
                }
                if (!options.boothTarget.empty()) {
                    Block *boothBlock = nullptr;
                    if (boothQueue.beginWrite(&boothBlock)) {
                        std::copy_n(boothLeft.begin(), frames, boothBlock->left.begin());
                        std::copy_n(boothRight.begin(), frames, boothBlock->right.begin());
                        boothQueue.endWrite();
                    }
                }
            }
        }
        if (!options.recordPath.empty() && recorded < totalFrames) {
            const uint32_t capacity = static_cast<uint32_t>(
                std::min<uint64_t>(frames, totalFrames - recorded));
            uint32_t drained = 0;
            if (!requireStatus(parso_engine_record_drain(
                    engine, recordedLeft.data() + recorded, recordedRight.data() + recorded,
                    capacity, &drained), "record drain")) {
                stop.store(true, std::memory_order_release);
            } else {
                recorded += drained;
            }
        }
        rendered += frames;
        if (useDevice) {
            const auto deadline = startTime + std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                std::chrono::duration<double>(static_cast<double>(rendered) / kSampleRate));
            std::this_thread::sleep_until(deadline);
        }
        if (streamFailed.load(std::memory_order_acquire)) stop.store(true, std::memory_order_release);
    }

    stop.store(true, std::memory_order_release);
    captureStream.requestStop();
    outputStream.requestStop();
    monitorStream.requestStop();
    boothStream.requestStop();
    if (captureThread.joinable()) captureThread.join();
    if (outputThread.joinable()) outputThread.join();
    if (monitorThread.joinable()) monitorThread.join();
    if (boothThread.joinable()) boothThread.join();
    captureStream.stop();
    boothStream.stop();
    monitorStream.stop();
    outputStream.stop();

    uint64_t recordDropped = 0;
    bool recordOk = true;
    if (!options.recordPath.empty()) {
        if (recorded < totalFrames) {
            uint32_t drained = 0;
            recordOk = requireStatus(parso_engine_record_drain(
                engine, recordedLeft.data() + recorded, recordedRight.data() + recorded,
                static_cast<uint32_t>(totalFrames - recorded), &drained), "final record drain");
            recorded += drained;
        }
        recordOk = requireStatus(parso_engine_record_dropped_frames(engine, &recordDropped),
                                  "record dropped frames") && recordOk;
        recordOk = requireStatus(parso_engine_record_set_active(engine, 0),
                                  "record inactive") && recordOk;
        recordOk = recorded == totalFrames && recordDropped == 0 && recordOk;
        recordedLeft.resize(recorded);
        recordedRight.resize(recorded);
        if (!writeRecording(options.recordPath, recordedLeft, recordedRight)) recordOk = false;
    }

    parso_stats_t stats;
    requireStatus(parso_stats_init(&stats), "stats init");
    requireStatus(parso_engine_get_stats(engine, &stats), "stats");
    const bool ok = rendered == totalFrames && stats.master_frame == rendered &&
                    maxPeak > 1.0e-5f && droppedBlocks == 0 &&
                    !streamFailed.load(std::memory_order_acquire) && recordOk;
    std::printf("linux PipeWire host: %llu frames, peak %.6f, capture blocks %llu, "
                "recorded %llu, dropped record frames %llu\n",
                static_cast<unsigned long long>(rendered), static_cast<double>(maxPeak),
                static_cast<unsigned long long>(capturedBlocks.load()),
                static_cast<unsigned long long>(recorded),
                static_cast<unsigned long long>(recordDropped));
    std::printf("stream recoveries %u\n", streamRecoveries.load(std::memory_order_relaxed));
    if (useDevice && !ok) {
        std::fprintf(stderr, "linux_pipewire_host: device stream underrun or render failure\n");
    }
    parso_engine_destroy(&engine);
    parso_pcm_buffer_release(&decoded);
    return ok && !streamFailed.load(std::memory_order_acquire) ? 0 : 1;
}
