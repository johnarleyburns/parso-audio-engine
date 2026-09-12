#include "parso_dsp.h"

#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>
#include <vector>

#include "signalsmith-stretch.h"

struct pd_timepitch {
    signalsmith::stretch::SignalsmithStretch<float> stretch;
    double sampleRate;
    int channels;
    int maxBlock;
    pd_tp_mode mode = PD_TP_VARISPEED;
    double timeRatio = 1.0;
    double pitchSemitones = 0.0;
    double varispeedPhase = 0.0;

    pd_timepitch(double sr, int channelCount, int blockSize)
        // Keep the seed within the 32-bit range of long on Windows/MinGW and
        // use the same value on LP64 hosts for deterministic cross-builds.
        : stretch(0x4152534fL), sampleRate(sr), channels(channelCount), maxBlock(blockSize) {
        // Signalsmith's process() keeps a temporary vector whose capacity is
        // established by configure(). Make its analysis block at least as
        // large as the host block, so normal render calls never grow it.
        const double defaultBlockValue = std::fmax(1.0, sampleRate * 0.12);
        const int defaultBlock = static_cast<int>(std::fmin(
            defaultBlockValue, static_cast<double>(std::numeric_limits<int>::max() / 2)
        ));
        const int configuredBlock = std::max(defaultBlock, maxBlock);
        const int configuredInterval = static_cast<int>(std::fmin(
            std::fmax(1.0, sampleRate * 0.03),
            static_cast<double>(std::numeric_limits<int>::max() / 4)
        ));
        stretch.configure(channels, configuredBlock, configuredInterval, false);
    }
};

extern "C" {

pd_timepitch* pd_tp_create(double sr, int channels, int max_block) {
    if (!std::isfinite(sr) || sr <= 0.0 || channels <= 0 || max_block <= 0) return nullptr;
    // Vector-backed third-party setup can throw bad_alloc even when the
    // object itself uses nothrow new. Keep C callers from observing an
    // exception or terminating during control-side creation.
    try {
        return new (std::nothrow) pd_timepitch(sr, channels, max_block);
    } catch (...) {
        return nullptr;
    }
}

void pd_tp_set_mode(pd_timepitch* tp, pd_tp_mode mode) {
    if (tp == nullptr) return;
    tp->mode = mode == PD_TP_KEYLOCK ? PD_TP_KEYLOCK : PD_TP_VARISPEED;
}

void pd_tp_set_time_ratio(pd_timepitch* tp, double ratio) {
    if (tp == nullptr) return;
    if (!std::isfinite(ratio)) ratio = 1.0;
    tp->timeRatio = std::fmax(0.06, std::fmin(2.0, ratio));
}

void pd_tp_set_pitch_semitones(pd_timepitch* tp, double semis) {
    if (tp == nullptr) return;
    if (!std::isfinite(semis)) semis = 0.0;
    tp->pitchSemitones = std::fmax(-12.0, std::fmin(12.0, semis));
    tp->stretch.setTransposeSemitones(static_cast<float>(tp->pitchSemitones));
}

void pd_tp_reset(pd_timepitch* tp) {
    if (tp == nullptr) return;
    tp->stretch.reset();
    tp->varispeedPhase = 0.0;
}

static float sampleAt(const float* samples, int frames, int index) {
    if (frames <= 0 || samples == nullptr) return 0.0f;
    if (index < 0) index = 0;
    if (index >= frames) index = frames - 1;
    return samples[index];
}

static float hermiteAt(const float* samples, int frames, double position) {
    const int index = static_cast<int>(std::floor(position));
    const double fraction = position - index;
    const double xm1 = sampleAt(samples, frames, index - 1);
    const double x0 = sampleAt(samples, frames, index);
    const double x1 = sampleAt(samples, frames, index + 1);
    const double x2 = sampleAt(samples, frames, index + 2);
    const double c0 = x0;
    const double c1 = 0.5 * (x1 - xm1);
    const double c2 = xm1 - 2.5 * x0 + 2.0 * x1 - 0.5 * x2;
    const double c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1);
    return static_cast<float>(((c3 * fraction + c2) * fraction + c1) * fraction + c0);
}

static int processVarispeed(pd_timepitch* tp, const float* const* in, int in_frames,
                            float* const* out, int out_frames) {
    const double pitchFactor = std::pow(2.0, tp->pitchSemitones / 12.0);
    const double step = tp->timeRatio * pitchFactor;
    const int writable = std::min(out_frames,
                                  std::max(0, static_cast<int>(std::ceil(
                                      (in_frames - tp->varispeedPhase) / step))));
    for (int channel = 0; channel < tp->channels; ++channel) {
        if (in[channel] == nullptr || out[channel] == nullptr) continue;
        for (int frame = 0; frame < writable; ++frame) {
            out[channel][frame] = hermiteAt(in[channel], in_frames,
                                             tp->varispeedPhase + frame * step);
        }
    }
    tp->varispeedPhase += writable * step;
    if (tp->varispeedPhase >= in_frames) tp->varispeedPhase -= in_frames;
    return writable;
}

int pd_tp_process(pd_timepitch* tp, const float* const* in, int in_frames,
                  float* const* out, int out_frames) {
    if (tp == nullptr || in == nullptr || out == nullptr || in_frames <= 0 || out_frames <= 0) {
        return 0;
    }
    if (tp->mode == PD_TP_VARISPEED) {
        return processVarispeed(tp, in, in_frames, out, out_frames);
    }
    tp->stretch.process(in, in_frames, out, out_frames);
    return out_frames;
}

void pd_tp_destroy(pd_timepitch* tp) { delete tp; }

} // extern "C"
