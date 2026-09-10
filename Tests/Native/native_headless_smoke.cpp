#include "parso_engine.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <array>
#include <vector>

namespace {

bool require(bool condition, const char* message) {
    if (!condition) std::fprintf(stderr, "native_headless_smoke: %s\n", message);
    return condition;
}

pe_engine* configuredEngine(double sampleRate, int maxFrames,
                            const float* const* channels, int64_t frames) {
    pe_engine* engine = pe_create(sampleRate, maxFrames, 2);
    if (!engine) return nullptr;

    pe_deck_set_buffer(engine, 0, channels, 2, frames, sampleRate);

    pe_control control{};
    control.master_level = 1.0f;
    control.limiter_ceiling_db = -0.3f;
    control.xfade_assign[0] = 2.0f; // thru
    control.fader[0] = 1.0f;
    control.trim[0] = 1.0f;
    pe_set_control(engine, &control);

    pe_command play{};
    play.type = PE_CMD_PLAY;
    play.deck = 0;
    if (!require(pe_post_command(engine, &play) == 1, "PE_CMD_PLAY was rejected")) {
        pe_destroy(engine);
        return nullptr;
    }
    return engine;
}

} // namespace

int main() {
    constexpr double sampleRate = 48000.0;
    constexpr int maxFrames = 512;
    constexpr int totalFrames = 1091;

    std::vector<float> left(totalFrames + 1);
    std::vector<float> right(totalFrames + 1);
    for (int i = 0; i <= totalFrames; ++i) {
        const float sample = 0.25f * std::sin(
            static_cast<float>(2.0 * 3.141592653589793 * 440.0 * i / sampleRate)
        );
        left[i] = sample;
        right[i] = sample;
    }
    const float* channels[] = {left.data(), right.data()};

    pe_engine* stepEngine = configuredEngine(sampleRate, maxFrames, channels, totalFrames + 1);
    pe_engine* renderEngine = configuredEngine(sampleRate, maxFrames, channels, totalFrames + 1);
    if (!require(stepEngine != nullptr && renderEngine != nullptr,
                 "pe_create returned null")) {
        pe_destroy(stepEngine);
        pe_destroy(renderEngine);
        return 1;
    }

    const std::array<int, 9> blockSizes = {1, 17, 64, 127, 128, 3, 89, 150, 512};
    std::vector<float> stepLeft(totalFrames);
    std::vector<float> stepRight(totalFrames);
    std::vector<float> renderLeft(totalFrames);
    std::vector<float> renderRight(totalFrames);
    int offset = 0;
    for (const int blockSize : blockSizes) {
        if (!require(blockSize <= maxFrames, "test block exceeds max frame limit")) {
            pe_destroy(stepEngine);
            pe_destroy(renderEngine);
            return 1;
        }
        pe_step(stepEngine, stepLeft.data() + offset, stepRight.data() + offset, blockSize);
        pe_render(renderEngine, renderLeft.data() + offset, renderRight.data() + offset, blockSize);
        offset += blockSize;
    }

    bool outputHasSignal = false;
    bool outputMatches = true;
    for (int i = 0; i < totalFrames; ++i) {
        if (std::fabs(stepLeft[i]) > 1.0e-5f || std::fabs(stepRight[i]) > 1.0e-5f) {
            outputHasSignal = true;
        }
        if (std::fabs(stepLeft[i] - renderLeft[i]) > 1.0e-6f ||
            std::fabs(stepRight[i] - renderRight[i]) > 1.0e-6f) {
            outputMatches = false;
        }
    }

    pe_stats stepStats{};
    pe_stats renderStats{};
    pe_get_stats(stepEngine, &stepStats);
    pe_get_stats(renderEngine, &renderStats);

    const bool ok = require(outputHasSignal, "headless render produced silence") &&
                   require(outputMatches, "pe_step and pe_render diverged") &&
                   require(stepStats.master_frame == totalFrames &&
                           renderStats.master_frame == totalFrames,
                           "master frame did not advance across variable blocks") &&
                   require(stepStats.starved_frames == 0 && renderStats.starved_frames == 0,
                           "deck unexpectedly starved");
    pe_destroy(stepEngine);
    pe_destroy(renderEngine);
    return ok ? 0 : 1;
}
