// CParsoDSP kernels. The remaining kernels below are still scaffold bodies; the
// isolator is implemented here first so its state and processing path are shared
// by the headless and device builds.
#include "parso_dsp.h"

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

pd_timepitch* pd_tp_create(double, int, int) { return nullptr; }
void pd_tp_set_mode(pd_timepitch*, pd_tp_mode) {}
void pd_tp_set_time_ratio(pd_timepitch*, double) {}
void pd_tp_set_pitch_semitones(pd_timepitch*, double) {}
void pd_tp_reset(pd_timepitch*) {}
int  pd_tp_process(pd_timepitch*, const float* const*, int, float* const*, int out_frames) { return out_frames; }
void pd_tp_destroy(pd_timepitch*) {}

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
