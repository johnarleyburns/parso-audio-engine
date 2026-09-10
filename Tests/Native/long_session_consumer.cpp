#include "parso.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

namespace {

bool requireOk(parso_status_t status, const char *operation) {
    if (status == PARSO_STATUS_OK) return true;
    std::fprintf(stderr, "long_session_consumer: %s: %s (%s)\n", operation,
                 parso_status_string(status), parso_last_error());
    return false;
}

} // namespace

int main() {
    constexpr uint32_t sampleRate = 48'000;
    constexpr uint32_t maxFrames = 512;
    constexpr uint64_t totalFrames = 262'144u + 4'096u;
    const std::vector<float> source(2'048u, 0.1f);
    std::vector<float> left(maxFrames);
    std::vector<float> right(maxFrames);
    const float *planes[] = {source.data()};

    parso_engine_options_t options;
    parso_control_t control;
    parso_pcm_view_t view;
    parso_output_view_t output;
    parso_command_t command;
    parso_stats_t stats;
    parso_engine_t *engine = nullptr;
    if (!requireOk(parso_engine_options_init(&options), "options init") ||
        !requireOk(parso_control_init(&control), "control init") ||
        !requireOk(parso_pcm_view_init(&view), "PCM view init") ||
        !requireOk(parso_output_view_init(&output), "output view init") ||
        !requireOk(parso_command_init(&command), "command init") ||
        !requireOk(parso_stats_init(&stats), "stats init")) return 1;

    options.sample_rate_hz = sampleRate;
    options.max_frames = maxFrames;
    view.planes = planes;
    view.frames = source.size();
    view.channel_count = 1;
    view.sample_rate_hz = sampleRate;
    command.type = PARSO_COMMAND_PLAY;
    command.deck = 0;
    if (!requireOk(parso_engine_create(&options, &engine), "create") ||
        !requireOk(parso_engine_set_control(engine, &control), "set control") ||
        !requireOk(parso_engine_set_deck_buffer(engine, 0, &view), "set buffer") ||
        !requireOk(parso_engine_post_command(engine, &command), "post play") ||
        !requireOk(parso_engine_record_reset(engine), "record reset") ||
        !requireOk(parso_engine_record_set_active(engine, 1), "record active")) {
        if (engine) parso_engine_destroy(&engine);
        return 1;
    }

    command.type = PARSO_COMMAND_SET_SLIP;
    command.f0 = 1.0f;
    bool queueFull = false;
    for (uint32_t index = 0; index < 512; ++index) {
        const parso_status_t status = parso_engine_post_command(engine, &command);
        if (status == PARSO_STATUS_QUEUE_FULL) {
            queueFull = true;
            break;
        }
        if (!requireOk(status, "queue pressure command")) {
            parso_engine_destroy(&engine);
            return 1;
        }
    }

    constexpr uint32_t callbackSizes[] = {64, 127, 256, 511, 96, 384};
    uint64_t renderedFrames = 0;
    uint32_t callbackIndex = 0;
    while (renderedFrames < totalFrames) {
        const uint32_t requested = callbackSizes[callbackIndex % (sizeof(callbackSizes) / sizeof(callbackSizes[0]))];
        const uint32_t frames = static_cast<uint32_t>(
            std::min<uint64_t>(requested, totalFrames - renderedFrames));
        output.left = left.data();
        output.right = right.data();
        output.frames = frames;
        if (!requireOk(parso_engine_render(engine, &output), "long render")) {
            parso_engine_destroy(&engine);
            return 1;
        }
        renderedFrames += frames;
        ++callbackIndex;
    }

    uint64_t droppedFrames = 0;
    const bool ok = queueFull && renderedFrames == totalFrames &&
                    requireOk(parso_engine_get_stats(engine, &stats), "stats") &&
                    stats.master_frame == totalFrames &&
                    requireOk(parso_engine_record_dropped_frames(engine, &droppedFrames),
                              "dropped frames") &&
                    droppedFrames > 0;
    if (!ok) {
        std::fprintf(stderr,
                     "long_session_consumer: queueFull=%d rendered=%llu master=%llu dropped=%llu\n",
                     queueFull ? 1 : 0,
                     static_cast<unsigned long long>(renderedFrames),
                     static_cast<unsigned long long>(stats.master_frame),
                     static_cast<unsigned long long>(droppedFrames));
    }
    if (!requireOk(parso_engine_record_set_active(engine, 0), "record inactive") ||
        !requireOk(parso_engine_destroy(&engine), "destroy")) return 1;
    return ok && engine == nullptr ? 0 : 1;
}
