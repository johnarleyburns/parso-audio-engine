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

struct pd_eq3 {
    double sampleRate;
    double smoothing;
    double crossoverLow;
    double crossoverHigh;

    Biquad lowShelf;
    Biquad midPeak;
    Biquad highShelf;

    // WARM2 uses a fourth-order 3-way split: two cascaded biquads per
    // crossover branch. The low-pass/high-pass split is duplicated so the
    // three band outputs sum to unity when all gains are flat.
    pd_eq3_profile profile = PD_EQ3_PROFILE_GENERIC;
    std::array<Biquad, 2> warmLowPass;
    std::array<Biquad, 2> warmLowHighPass;
    std::array<Biquad, 2> warmMidLowPass;
    std::array<Biquad, 2> warmMidHighPass;

    double lowDB = 0.0;
    double midDB = 0.0;
    double highDB = 0.0;
    double targetLowDB = 0.0;
    double targetMidDB = 0.0;
    double targetHighDB = 0.0;
    bool hasProcessed = false;
};

extern "C" {

pd_eq3* pd_eq3_create(double sample_rate, double xover_lo_hz, double xover_hi_hz) {
    if (!std::isfinite(sample_rate) || sample_rate <= 0.0 ||
        !std::isfinite(xover_lo_hz) || !std::isfinite(xover_hi_hz) ||
        xover_lo_hz <= 0.0 || xover_hi_hz <= xover_lo_hz ||
        xover_hi_hz >= sample_rate * 0.5) {
        return nullptr;
    }

    pd_eq3* eq = new (std::nothrow) pd_eq3;
    if (eq == nullptr) return nullptr;
    eq->sampleRate = sample_rate;
    eq->crossoverLow = xover_lo_hz;
    eq->crossoverHigh = xover_hi_hz;
    // Ten milliseconds is within the specified 5–20 ms control smoothing range.
    eq->smoothing = 1.0 - std::exp(-1.0 / (sample_rate * 0.010));
    const double midFrequency = std::sqrt(xover_lo_hz * xover_hi_hz);
    const double midQ = midFrequency / (xover_hi_hz - xover_lo_hz);
    eq->lowShelf.setLowShelf(sample_rate, xover_lo_hz, 0.0);
    eq->midPeak.setPeaking(sample_rate, midFrequency, midQ, 0.0);
    eq->highShelf.setHighShelf(sample_rate, xover_hi_hz, 0.0);
    return eq;
}

void pd_eq3_set_profile(pd_eq3* eq, pd_eq3_profile profile) {
    if (eq == nullptr) return;
    eq->profile = profile == PD_EQ3_PROFILE_WARM2
        ? PD_EQ3_PROFILE_WARM2 : PD_EQ3_PROFILE_GENERIC;
    if (eq->profile == PD_EQ3_PROFILE_WARM2) {
        eq->crossoverLow = 300.0;
        eq->crossoverHigh = 4000.0;
    }
}

void pd_eq3_set(pd_eq3* eq, float low_db, float mid_db, float high_db) {
    if (eq == nullptr) return;
    if (eq->profile == PD_EQ3_PROFILE_WARM2) {
        eq->targetLowDB = sanitizedWarm2DB(low_db, -70.0);
        eq->targetMidDB = sanitizedWarm2DB(mid_db, -40.0);
        eq->targetHighDB = sanitizedWarm2DB(high_db, -70.0);
    } else {
        eq->targetLowDB = sanitizedDB(low_db);
        eq->targetMidDB = sanitizedDB(mid_db);
        eq->targetHighDB = sanitizedDB(high_db);
    }
    // The first control message establishes the initial state before audio is
    // running. Later messages are smoothed in the render loop.
    if (!eq->hasProcessed) {
        eq->lowDB = eq->targetLowDB;
        eq->midDB = eq->targetMidDB;
        eq->highDB = eq->targetHighDB;
    }
}

void pd_eq3_process(pd_eq3* eq, const float* in, float* out, int frames) {
    if (eq == nullptr || out == nullptr || frames <= 0) return;
    if (in == nullptr) {
        for (int frame = 0; frame < frames; ++frame) out[frame] = 0.0f;
        return;
    }
    eq->hasProcessed = true;

    for (int frame = 0; frame < frames; ++frame) {
        eq->lowDB += (eq->targetLowDB - eq->lowDB) * eq->smoothing;
        eq->midDB += (eq->targetMidDB - eq->midDB) * eq->smoothing;
        eq->highDB += (eq->targetHighDB - eq->highDB) * eq->smoothing;
        if (eq->profile == PD_EQ3_PROFILE_WARM2) {
            const double q = 1.0 / std::sqrt(2.0);
            for (int stage = 0; stage < 2; ++stage) {
                eq->warmLowPass[stage].setLowPass(eq->sampleRate, eq->crossoverLow, q);
                eq->warmLowHighPass[stage].setHighPass(eq->sampleRate, eq->crossoverLow, q);
                eq->warmMidLowPass[stage].setLowPass(eq->sampleRate, eq->crossoverHigh, q);
                eq->warmMidHighPass[stage].setHighPass(eq->sampleRate, eq->crossoverHigh, q);
            }
            float low = in[frame];
            float residual = in[frame];
            for (int stage = 0; stage < 2; ++stage) {
                low = eq->warmLowPass[stage].process(low);
                residual = eq->warmLowHighPass[stage].process(residual);
            }
            float mid = residual;
            float high = residual;
            for (int stage = 0; stage < 2; ++stage) {
                mid = eq->warmMidLowPass[stage].process(mid);
                high = eq->warmMidHighPass[stage].process(high);
            }
            const float lowGain = static_cast<float>(std::pow(10.0, eq->lowDB / 20.0));
            const float midGain = static_cast<float>(std::pow(10.0, eq->midDB / 20.0));
            const float highGain = static_cast<float>(std::pow(10.0, eq->highDB / 20.0));
            out[frame] = low * lowGain + mid * midGain + high * highGain;
            continue;
        }
        const double midFrequency = std::sqrt(eq->crossoverLow * eq->crossoverHigh);
        const double midQ = midFrequency / (eq->crossoverHigh - eq->crossoverLow);
        eq->lowShelf.setLowShelf(eq->sampleRate, eq->crossoverLow, eq->lowDB);
        eq->midPeak.setPeaking(eq->sampleRate, midFrequency, midQ, eq->midDB);
        eq->highShelf.setHighShelf(eq->sampleRate, eq->crossoverHigh, eq->highDB);

        float sample = eq->lowShelf.process(in[frame]);
        sample = eq->midPeak.process(sample);
        out[frame] = eq->highShelf.process(sample);
    }
}

void pd_eq3_destroy(pd_eq3* eq) { delete eq; }

} // extern "C"
