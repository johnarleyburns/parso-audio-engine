#include "parso_dsp.h"

#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>
#include <vector>

struct pd_delay {
    double sampleRate;
    double smoothing;
    std::vector<float> buffer;
    size_t writeIndex = 0;
    double timeSeconds = 0.01;
    double targetTimeSeconds = 0.01;
    float feedback = 0.0f;
    float targetFeedback = 0.0f;
    float mix = 0.5f;
    float targetMix = 0.5f;
    bool hasProcessed = false;
};

extern "C" {

pd_delay* pd_delay_create(double sample_rate, double max_seconds) {
    if (!std::isfinite(sample_rate) || sample_rate <= 0.0 ||
        !std::isfinite(max_seconds) || max_seconds <= 0.0 || max_seconds > 60.0) {
        return nullptr;
    }
    const double requestedFrames = std::ceil(sample_rate * max_seconds) + 2.0;
    if (!std::isfinite(requestedFrames) || requestedFrames > 20'000'000.0) return nullptr;

    pd_delay* delay = new (std::nothrow) pd_delay;
    if (delay == nullptr) return nullptr;
    delay->sampleRate = sample_rate;
    delay->smoothing = 1.0 - std::exp(-1.0 / (sample_rate * 0.010));
    try {
        delay->buffer.assign(static_cast<size_t>(requestedFrames), 0.0f);
    } catch (...) {
        delete delay;
        return nullptr;
    }
    return delay;
}

void pd_delay_set(pd_delay* delay, double time_seconds, float feedback, float mix) {
    if (delay == nullptr) return;
    delay->targetTimeSeconds = std::isfinite(time_seconds)
        ? std::fmax(0.0001, std::fmin(60.0, time_seconds)) : 0.01;
    delay->targetFeedback = std::isfinite(feedback)
        ? std::fmax(0.0f, std::fmin(0.95f, feedback)) : 0.0f;
    delay->targetMix = std::isfinite(mix)
        ? std::fmax(0.0f, std::fmin(1.0f, mix)) : 0.5f;
    if (!delay->hasProcessed) {
        delay->timeSeconds = delay->targetTimeSeconds;
        delay->feedback = delay->targetFeedback;
        delay->mix = delay->targetMix;
    }
}

void pd_delay_process(pd_delay* delay, const float* in, float* out, int frames) {
    if (delay == nullptr || out == nullptr || frames <= 0 || delay->buffer.size() < 3) return;
    delay->hasProcessed = true;
    const double maximumDelay = static_cast<double>(delay->buffer.size() - 2) / delay->sampleRate;
    for (int frame = 0; frame < frames; ++frame) {
        delay->timeSeconds += (delay->targetTimeSeconds - delay->timeSeconds) * delay->smoothing;
        delay->feedback += (delay->targetFeedback - delay->feedback) *
            static_cast<float>(delay->smoothing);
        delay->mix += (delay->targetMix - delay->mix) * static_cast<float>(delay->smoothing);
        const double delaySeconds = std::fmax(0.0001, std::fmin(maximumDelay, delay->timeSeconds));
        const double delayFrames = delaySeconds * delay->sampleRate;
        const double readPosition = static_cast<double>(delay->writeIndex) - delayFrames;
        double wrappedPosition = readPosition;
        if (wrappedPosition < 0.0) wrappedPosition += delay->buffer.size();
        const size_t lower = static_cast<size_t>(wrappedPosition);
        const size_t upper = lower + 1 < delay->buffer.size() ? lower + 1 : 0;
        const float fraction = static_cast<float>(wrappedPosition - static_cast<double>(lower));
        const float delayed = delay->buffer[lower] * (1.0f - fraction) +
            delay->buffer[upper] * fraction;
        const float dry = in == nullptr ? 0.0f : in[frame];
        delay->buffer[delay->writeIndex] = dry + delayed * delay->feedback;
        out[frame] = dry * (1.0f - delay->mix) + delayed * delay->mix;
        delay->writeIndex = delay->writeIndex + 1 < delay->buffer.size()
            ? delay->writeIndex + 1 : 0;
    }
}

void pd_delay_destroy(pd_delay* delay) { delete delay; }

} // extern "C"
