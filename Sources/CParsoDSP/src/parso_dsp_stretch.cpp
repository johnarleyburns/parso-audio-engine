// Streaming exact-rate time-stretch (Signalsmith Stretch, MIT). See parso_dsp.h.
// 60 ms blocks / 15 ms interval: in the Tonearm blend lab this setting kept kick
// timing jitter at 6.6 ms p90 (the 120 ms default smeared kicks more).
#include "parso_dsp.h"

#include <algorithm>
#include <cmath>
#include <new>

#include "signalsmith-stretch.h"

struct pd_stretch {
    signalsmith::stretch::SignalsmithStretch<float> stretch;
    int channels;
    pd_stretch(double sr, int channelCount, int maxIn, int maxOut)
        : stretch(0x4152534fL), channels(channelCount) {
        // The block is a quality setting, not a buffer size: process() copies any
        // input length through a block+interval scratch, so maxIn doesn't bound it.
        (void)maxIn;
        const int block = std::max(static_cast<int>(sr * 0.06), maxOut);
        const int interval = std::max(1, static_cast<int>(sr * 0.015));
        stretch.configure(channelCount, block, interval, false);
    }
};

extern "C" {

pd_stretch* pd_stretch_create(double sr, int channels, int max_in, int max_out) {
    if (!std::isfinite(sr) || sr <= 0.0 || channels <= 0 || max_in <= 0 || max_out <= 0) return nullptr;
    try {
        return new (std::nothrow) pd_stretch(sr, channels, max_in, max_out);
    } catch (...) {
        return nullptr;
    }
}

int pd_stretch_seek_length(const pd_stretch* s, double rate) {
    if (s == nullptr || !std::isfinite(rate) || rate <= 0.0) return 0;
    return s->stretch.outputSeekLength(static_cast<float>(rate));
}

void pd_stretch_output_seek(pd_stretch* s, const float* const* in, int in_frames) {
    if (s == nullptr || in == nullptr || in_frames <= 0) return;
    s->stretch.outputSeek(in, in_frames);
}

void pd_stretch_process(pd_stretch* s, const float* const* in, int in_frames,
                        float* const* out, int out_frames) {
    if (s == nullptr || in == nullptr || out == nullptr || out_frames <= 0) return;
    s->stretch.process(in, std::max(0, in_frames), out, out_frames);
}

void pd_stretch_destroy(pd_stretch* s) { delete s; }

} // extern "C"
