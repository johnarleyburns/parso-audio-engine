#include "parso_dsp.h"

#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>
#include <vector>

#include "parso_dsp_filters.hpp"

using namespace parso_dsp_detail;

struct pd_filter {
    double sampleRate;
    double smoothing;
    float knob = 0.0f;
    float targetKnob = 0.0f;
    float resonance = 0.3f;
    float targetResonance = 0.3f;
    Biquad biquad;
};

extern "C" {

pd_filter* pd_filter_create(double sample_rate) {
    if (!std::isfinite(sample_rate) || sample_rate <= 0.0) return nullptr;
    pd_filter* filter = new (std::nothrow) pd_filter;
    if (filter == nullptr) return nullptr;
    filter->sampleRate = sample_rate;
    filter->smoothing = 1.0 - std::exp(-1.0 / (sample_rate * 0.010));
    return filter;
}

void pd_filter_set(pd_filter* filter, float knob, float resonance) {
    if (filter == nullptr) return;
    filter->targetKnob = std::isfinite(knob) ?
        std::fmax(-1.0f, std::fmin(1.0f, knob)) : 0.0f;
    filter->targetResonance = std::isfinite(resonance) ?
        std::fmax(0.0f, std::fmin(1.0f, resonance)) : 0.3f;
}

void pd_filter_process(pd_filter* filter, const float* in, float* out, int frames) {
    if (filter == nullptr || out == nullptr || frames <= 0) return;
    if (in == nullptr) {
        for (int frame = 0; frame < frames; ++frame) out[frame] = 0.0f;
        return;
    }

    // Both branches must converge to a near-transparent (allpass-like)
    // response as the knob approaches zero from either side, and the biquad
    // must be fed on every sample so its internal state stays continuous
    // across the low-pass/high-pass topology switch at the centre. Two bugs
    // used to violate this: (1) a hard `|knob| < 0.0001` bypass that skipped
    // the biquad entirely, leaving its state stale when it re-engaged, and
    // (2) the high-pass branch's cutoff mapping was inverted — it hit its
    // MOST aggressive cutoff (~20 kHz, stripping nearly the whole signal)
    // right at knob≈0, then relaxed back toward transparent as the knob
    // turned further toward +1, exactly backwards from the low-pass branch
    // and from every mixer-knob convention (centre = no effect). Together
    // these produced an audible click/near-silence-then-return right at the
    // crossing on continuous knob sweeps (found while reviewing the Phase 6d
    // A-B render, docs/phase6-parity.md is the parity record; see
    // current_status.md "Phase 6" for the render that surfaced this).
    const double logRange = std::log(1000.0);
    const double minimumCutoff = std::min(20.0, filter->sampleRate * 0.02);
    const double maximumCutoff = filter->sampleRate * 0.49;
    for (int frame = 0; frame < frames; ++frame) {
        filter->knob += static_cast<float>(filter->smoothing) *
            (filter->targetKnob - filter->knob);
        filter->resonance += static_cast<float>(filter->smoothing) *
            (filter->targetResonance - filter->resonance);

        // normalized == 0 at the centre on both branches -> cutoff ==
        // minimumCutoff on both -> low-pass at minimumCutoff is near-Nyquist
        // transparent... no: low-pass wants cutoff -> maximumCutoff to be
        // transparent, so the two branches intentionally use opposite
        // directions of `normalized` while both starting from knob == 0.
        const double normalized = filter->knob < 0.0f
            ? 1.0 + static_cast<double>(filter->knob)   // -1..0 -> 0..1 (LP: dark -> transparent)
            : static_cast<double>(filter->knob);        //  0..1 -> 0..1 (HP: transparent -> bright)
        const double cutoff = std::fmax(
            minimumCutoff,
            std::fmin(maximumCutoff, minimumCutoff * std::exp(logRange * normalized))
        );
        const double q = 0.5 + 9.5 * static_cast<double>(filter->resonance);
        if (filter->knob < 0.0f) {
            filter->biquad.setLowPass(filter->sampleRate, cutoff, q);
        } else {
            filter->biquad.setHighPass(filter->sampleRate, cutoff, q);
        }
        out[frame] = filter->biquad.process(in[frame]);
    }
}

void pd_filter_destroy(pd_filter* filter) { delete filter; }

} // extern "C"
