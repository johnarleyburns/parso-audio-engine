// CParsoDSP kernels. The remaining kernels below are still scaffold bodies; the
// isolator is implemented here first so its state and processing path are shared
// by the headless and device builds.
#include "parso_dsp.h"
#include "signalsmith-stretch.h"

#include <cmath>
#include <new>

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr double kMinimumGainDB = -120.0;
constexpr double kMaximumGainDB = 6.0;

struct Biquad {
    double b0 = 1.0;
    double b1 = 0.0;
    double b2 = 0.0;
    double a1 = 0.0;
    double a2 = 0.0;
    double x1 = 0.0;
    double x2 = 0.0;
    double y1 = 0.0;
    double y2 = 0.0;

    void setLowShelf(double sampleRate, double frequency, double db) {
        const double a = std::pow(10.0, db / 40.0);
        const double w0 = 2.0 * kPi * frequency / sampleRate;
        const double cosine = std::cos(w0);
        const double sine = std::sin(w0);
        const double alpha = sine * 0.5 * std::sqrt(2.0);
        const double beta = 2.0 * std::sqrt(a) * alpha;
        setCoefficients(
            a * ((a + 1.0) - (a - 1.0) * cosine + beta),
            2.0 * a * ((a - 1.0) - (a + 1.0) * cosine),
            a * ((a + 1.0) - (a - 1.0) * cosine - beta),
            (a + 1.0) + (a - 1.0) * cosine + beta,
            -2.0 * ((a - 1.0) + (a + 1.0) * cosine),
            (a + 1.0) + (a - 1.0) * cosine - beta
        );
    }

    void setHighShelf(double sampleRate, double frequency, double db) {
        const double a = std::pow(10.0, db / 40.0);
        const double w0 = 2.0 * kPi * frequency / sampleRate;
        const double cosine = std::cos(w0);
        const double sine = std::sin(w0);
        const double alpha = sine * 0.5 * std::sqrt(2.0);
        const double beta = 2.0 * std::sqrt(a) * alpha;
        setCoefficients(
            a * ((a + 1.0) + (a - 1.0) * cosine + beta),
            -2.0 * a * ((a - 1.0) + (a + 1.0) * cosine),
            a * ((a + 1.0) + (a - 1.0) * cosine - beta),
            (a + 1.0) - (a - 1.0) * cosine + beta,
            2.0 * ((a - 1.0) - (a + 1.0) * cosine),
            (a + 1.0) - (a - 1.0) * cosine - beta
        );
    }

    void setPeaking(double sampleRate, double frequency, double q, double db) {
        const double a = std::pow(10.0, db / 40.0);
        const double w0 = 2.0 * kPi * frequency / sampleRate;
        const double cosine = std::cos(w0);
        const double alpha = std::sin(w0) / (2.0 * q);
        setCoefficients(
            1.0 + alpha * a, -2.0 * cosine, 1.0 - alpha * a,
            1.0 + alpha / a, -2.0 * cosine, 1.0 - alpha / a
        );
    }

    float process(float input) {
        const double x = static_cast<double>(input);
        const double y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
        x2 = x1;
        x1 = x;
        y2 = y1;
        y1 = y;
        return static_cast<float>(y);
    }

private:
    void setCoefficients(double rawB0, double rawB1, double rawB2,
                         double rawA0, double rawA1, double rawA2) {
        b0 = rawB0 / rawA0;
        b1 = rawB1 / rawA0;
        b2 = rawB2 / rawA0;
        a1 = rawA1 / rawA0;
        a2 = rawA2 / rawA0;
    }
};

double sanitizedDB(float db) {
    if (std::isnan(db)) return 0.0;
    if (std::isinf(db) && db < 0.0f) return kMinimumGainDB;
    return std::fmax(kMinimumGainDB,
                     std::fmin(kMaximumGainDB, static_cast<double>(db)));
}

} // namespace

struct pd_eq3 {
    double sampleRate;
    double smoothing;
    double crossoverLow;
    double crossoverHigh;

    Biquad lowShelf;
    Biquad midPeak;
    Biquad highShelf;

    double lowDB = 0.0;
    double midDB = 0.0;
    double highDB = 0.0;
    double targetLowDB = 0.0;
    double targetMidDB = 0.0;
    double targetHighDB = 0.0;
    bool hasProcessed = false;
};

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
        : stretch(0x504152534fULL), sampleRate(sr), channels(channelCount), maxBlock(blockSize) {
        stretch.presetDefault(channels, static_cast<float>(sampleRate), false);
    }
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

void pd_eq3_set(pd_eq3* eq, float low_db, float mid_db, float high_db) {
    if (eq == nullptr) return;
    eq->targetLowDB = sanitizedDB(low_db);
    eq->targetMidDB = sanitizedDB(mid_db);
    eq->targetHighDB = sanitizedDB(high_db);
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

pd_filter* pd_filter_create(double) { return nullptr; }
void pd_filter_set(pd_filter*, float, float) {}
void pd_filter_process(pd_filter*, const float* in, float* out, int frames) { for (int i=0;i<frames;++i) out[i]=in?in[i]:0.f; }
void pd_filter_destroy(pd_filter*) {}

pd_timepitch* pd_tp_create(double sr, int channels, int max_block) {
    if (!std::isfinite(sr) || sr <= 0.0 || channels <= 0 || max_block <= 0) return nullptr;
    return new (std::nothrow) pd_timepitch(sr, channels, max_block);
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

pd_delay* pd_delay_create(double, double) { return nullptr; }
void pd_delay_set(pd_delay*, double, float, float) {}
void pd_delay_process(pd_delay*, const float* in, float* out, int frames) { for (int i=0;i<frames;++i) out[i]=in?in[i]:0.f; }
void pd_delay_destroy(pd_delay*) {}

pd_reverb* pd_reverb_create(double) { return nullptr; }
void pd_reverb_set(pd_reverb*, float, float, float, float) {}
void pd_reverb_process(pd_reverb*, const float* il, const float* ir, float* ol, float* or_, int n) { for(int i=0;i<n;++i){ol[i]=il?il[i]:0.f;or_[i]=ir?ir[i]:0.f;} }
void pd_reverb_destroy(pd_reverb*) {}

pd_limiter* pd_limiter_create(double, float) { return nullptr; }
void pd_limiter_process(pd_limiter*, float*, float*, int) {}
void pd_limiter_destroy(pd_limiter*) {}

pd_ring* pd_ring_create(size_t, size_t) { return nullptr; }
int  pd_ring_push(pd_ring*, const void*) { return 0; }
int  pd_ring_pop(pd_ring*, void*) { return 0; }
void pd_ring_destroy(pd_ring*) {}

void pd_enable_ftz(void) {}
} // extern "C"
