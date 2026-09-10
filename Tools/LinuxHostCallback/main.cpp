#include "parso.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <vector>

namespace {

constexpr uint32_t kSampleRate = 48000;
constexpr uint32_t kRenderFrames = kSampleRate;

bool requireStatus(parso_status_t status, const char *operation) noexcept {
    if (status == PARSO_STATUS_OK) return true;
    std::fprintf(stderr, "linux_host_callback: %s: %s (%s)\n", operation,
                 parso_status_string(status), parso_last_error());
    return false;
}

struct HostCallback {
    parso_engine_t *engine = nullptr;

    parso_status_t render(float *left, float *right, uint32_t frames) const noexcept {
        parso_output_view_t output;
        const parso_status_t initStatus = parso_output_view_init(&output);
        if (initStatus != PARSO_STATUS_OK) return initStatus;
        output.left = left;
        output.right = right;
        output.frames = frames;
        return parso_engine_render(engine, &output);
    }
};

bool writeWav(const char *path, const std::vector<float> &left,
             const std::vector<float> &right) {
    std::vector<float> interleaved(left.size() * 2u);
    for (std::size_t index = 0; index < left.size(); ++index) {
        interleaved[index * 2u] = left[index];
        interleaved[index * 2u + 1u] = right[index];
    }

    parso_pcm_buffer_t buffer;
    parso_bytes_t bytes;
    if (!requireStatus(parso_pcm_buffer_init(&buffer), "PCM init") ||
        !requireStatus(parso_bytes_init(&bytes), "bytes init")) {
        return false;
    }
    buffer.samples = interleaved.data();
    buffer.frames = left.size();
    buffer.channel_count = 2;
    buffer.sample_rate_hz = kSampleRate;
    const parso_status_t writeStatus = parso_wav_write(&buffer, 32, 1, &bytes);
    buffer.samples = nullptr;
    const bool ok = requireStatus(writeStatus, "WAV encode");
    bool wrote = ok;
    if (ok) {
        std::ofstream file(path, std::ios::binary);
        if (!file) {
            std::fprintf(stderr, "linux_host_callback: cannot open %s\n", path);
        } else {
            file.write(reinterpret_cast<const char *>(bytes.data),
                       static_cast<std::streamsize>(bytes.size_bytes));
        }
        if (!file) {
            std::fprintf(stderr, "linux_host_callback: cannot write %s\n", path);
            wrote = false;
        }
    }
    parso_bytes_release(&bytes);
    parso_pcm_buffer_release(&buffer);
    return wrote;
}

} // namespace

int main(int argc, char **argv) {
    std::vector<float> source(kRenderFrames);
    std::vector<float> outputLeft(kRenderFrames, 0.0f);
    std::vector<float> outputRight(kRenderFrames, 0.0f);
    for (uint32_t index = 0; index < kRenderFrames; ++index) {
        source[index] = 0.2f * std::sin(static_cast<float>(
            2.0 * 3.141592653589793 * 220.0 * index / kSampleRate));
    }
    const float *planes[] = {source.data()};

    parso_engine_options_t options;
    parso_control_t control;
    parso_pcm_view_t view;
    parso_command_t command;
    parso_engine_t *engine = nullptr;
    if (!requireStatus(parso_engine_options_init(&options), "options init") ||
        !requireStatus(parso_control_init(&control), "control init") ||
        !requireStatus(parso_pcm_view_init(&view), "PCM view init") ||
        !requireStatus(parso_command_init(&command), "command init")) {
        return 1;
    }

    options.sample_rate_hz = kSampleRate;
    options.max_frames = 512;
    view.planes = planes;
    view.frames = source.size();
    view.channel_count = 1;
    view.sample_rate_hz = kSampleRate;
    command.type = PARSO_COMMAND_PLAY;
    command.deck = 0;

    if (!requireStatus(parso_engine_create(&options, &engine), "create") ||
        !requireStatus(parso_engine_set_control(engine, &control), "set control") ||
        !requireStatus(parso_engine_set_deck_buffer(engine, 0, &view), "set deck buffer") ||
        !requireStatus(parso_engine_post_command(engine, &command), "post play")) {
        parso_engine_destroy(&engine);
        return 1;
    }

    HostCallback callback{engine};
    constexpr uint32_t callbackSizes[] = {64, 127, 256, 96, 192};
    uint32_t frameOffset = 0;
    std::size_t callbackIndex = 0;
    while (frameOffset < kRenderFrames) {
        const uint32_t requested = callbackSizes[callbackIndex % std::size(callbackSizes)];
        const uint32_t frames = std::min(requested, kRenderFrames - frameOffset);
        if (!requireStatus(callback.render(outputLeft.data() + frameOffset,
                                           outputRight.data() + frameOffset, frames),
                           "host callback render")) {
            parso_engine_destroy(&engine);
            return 1;
        }
        frameOffset += frames;
        ++callbackIndex;
    }

    parso_event_t events[16];
    for (parso_event_t &event : events) {
        if (!requireStatus(parso_event_init(&event), "event init")) {
            parso_engine_destroy(&engine);
            return 1;
        }
    }
    uint32_t eventCount = 0;
    parso_stats_t stats;
    if (!requireStatus(parso_stats_init(&stats), "stats init") ||
        !requireStatus(parso_engine_poll_events(engine, events, 16, &eventCount),
                       "poll events") ||
        !requireStatus(parso_engine_get_stats(engine, &stats), "get stats")) {
        parso_engine_destroy(&engine);
        return 1;
    }

    float peak = 0.0f;
    for (uint32_t index = 0; index < kRenderFrames; ++index) {
        peak = std::max(peak, std::max(std::fabs(outputLeft[index]),
                                       std::fabs(outputRight[index])));
    }
    if (peak <= 1.0e-5f || stats.master_frame != kRenderFrames || eventCount == 0) {
        std::fprintf(stderr, "linux_host_callback: render contract failed\n");
        parso_engine_destroy(&engine);
        return 1;
    }

    if (argc > 1 && !writeWav(argv[1], outputLeft, outputRight)) {
        parso_engine_destroy(&engine);
        return 1;
    }
    std::printf("linux host callback: %u frames, peak %.6f, %u events\n",
                kRenderFrames, static_cast<double>(peak), eventCount);
    return requireStatus(parso_engine_destroy(&engine), "destroy") && engine == nullptr ? 0 : 1;
}
