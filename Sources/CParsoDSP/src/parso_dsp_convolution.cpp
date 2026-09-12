#include "parso_dsp.h"

#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>
#include <vector>

#include <complex>
#include "signalsmith-stretch.h"

extern "C" {

struct pd_conv {
    static constexpr int B = 512;
    static constexpr int N = 1024;
    static constexpr int NB = N / 2 + 1;
    static constexpr int MAX_PARTS = 384;   // up to ~196 k-sample IR (~4 s at 48 kHz)
    double sampleRate;
    signalsmith::linear::RealFFT<float> fft{N};

    struct Bank {
        std::vector<std::complex<float>> spec;   // parts * NB
        int parts = 0;
        float gain = 1.0f;
    };
    Bank bank[2];
    std::atomic<int> active{-1};                  // -1 none, else 0/1

    std::vector<std::complex<float>> fdl;         // MAX_PARTS * NB, circular
    int fdlHead = 0;
    std::array<float, N> inWin{};                 // [B history | B new]
    std::array<std::complex<float>, NB> xSpec{};
    std::array<std::complex<float>, NB> ySpec{};
    std::array<float, N> timeOut{};
    std::array<float, B> inAccum{};
    int inFill = 0;
    std::array<float, B> outBlock{};              // last completed conv block
    int outPos = B;                               // B => nothing ready yet
    float mix = 1.0f;

    explicit pd_conv(double sr) : sampleRate(sr) {
        fdl.assign(static_cast<size_t>(MAX_PARTS) * NB, {});
    }

    void runBlock() {
        const int a = active.load(std::memory_order_acquire);
        // Slide history: inWin[0..B) <- previous new; inWin[B..2B) <- inAccum.
        for (int i = 0; i < B; ++i) inWin[i] = inWin[B + i];
        for (int i = 0; i < B; ++i) inWin[B + i] = inAccum[i];
        fft.fft(inWin.data(), xSpec.data());
        std::complex<float>* slot = &fdl[static_cast<size_t>(fdlHead) * NB];
        for (int k = 0; k < NB; ++k) slot[k] = xSpec[k];

        if (a < 0) { outBlock.fill(0.0f); outPos = 0; fdlHead = (fdlHead + 1) % MAX_PARTS; return; }
        const Bank& bk = bank[a];
        for (int k = 0; k < NB; ++k) ySpec[k] = {0.0f, 0.0f};
        for (int p = 0; p < bk.parts; ++p) {
            int src = fdlHead - p;
            if (src < 0) src += MAX_PARTS;
            const std::complex<float>* xs = &fdl[static_cast<size_t>(src) * NB];
            const std::complex<float>* hs = &bk.spec[static_cast<size_t>(p) * NB];
            for (int k = 0; k < NB; ++k) ySpec[k] += xs[k] * hs[k];
        }
        fdlHead = (fdlHead + 1) % MAX_PARTS;
        fft.ifft(ySpec.data(), timeOut.data());
        const float norm = bk.gain / static_cast<float>(N);
        for (int i = 0; i < B; ++i) {
            const float v = timeOut[B + i] * norm;
            outBlock[i] = std::isfinite(v) ? v : 0.0f;
        }
        outPos = 0;
    }
};

pd_conv* pd_conv_create(double sample_rate) {
    if (!std::isfinite(sample_rate) || sample_rate <= 0.0) return nullptr;
    return new (std::nothrow) pd_conv(sample_rate);
}

int pd_conv_set_ir(pd_conv* c, const float* ir, int ir_len) {
    if (!c || !ir || ir_len <= 0) {
        if (c) c->active.store(-1, std::memory_order_release);
        return PD_ERR_PARAM;
    }
    const int B = pd_conv::B, N = pd_conv::N, NB = pd_conv::NB;
    int parts = (ir_len + B - 1) / B;
    if (parts > pd_conv::MAX_PARTS) parts = pd_conv::MAX_PARTS;

    const int live = c->active.load(std::memory_order_acquire);
    const int next = (live == 0) ? 1 : 0;         // fill the non-live bank
    pd_conv::Bank& bk = c->bank[next];
    bk.spec.assign(static_cast<size_t>(parts) * NB, {});
    bk.parts = parts;

    float peak = 1e-9f;
    for (int i = 0; i < ir_len; ++i) peak = std::fmax(peak, std::fabs(ir[i]));
    bk.gain = 1.0f / peak;                        // unity-peak so `mix` is predictable

    std::array<float, N> block{};
    std::array<std::complex<float>, NB> spec{};
    for (int p = 0; p < parts; ++p) {
        block.fill(0.0f);
        const int off = p * B;
        for (int i = 0; i < B && off + i < ir_len; ++i) block[i] = ir[off + i];
        c->fft.fft(block.data(), spec.data());
        std::complex<float>* dst = &bk.spec[static_cast<size_t>(p) * NB];
        for (int k = 0; k < NB; ++k) dst[k] = spec[k];
    }
    c->active.store(next, std::memory_order_release);   // publish
    return PD_OK;
}

void pd_conv_set_mix(pd_conv* c, float mix) {
    if (c) c->mix = std::isfinite(mix) ? std::fmax(0.0f, std::fmin(1.0f, mix)) : 0.0f;
}

void pd_conv_process(pd_conv* c, const float* in_l, const float* in_r,
                     float* out_l, float* out_r, int frames) {
    if (!c || frames <= 0) return;
    if (c->active.load(std::memory_order_acquire) < 0) {   // no IR -> dry passthrough
        for (int i = 0; i < frames; ++i) {
            if (out_l) out_l[i] = in_l ? in_l[i] : 0.0f;
            if (out_r) out_r[i] = in_r ? in_r[i] : (in_l ? in_l[i] : 0.0f);
        }
        return;
    }
    for (int i = 0; i < frames; ++i) {
        const float dl = in_l ? in_l[i] : 0.0f;
        const float dr = in_r ? in_r[i] : dl;
        c->inAccum[c->inFill++] = 0.5f * (dl + dr);   // mono send
        float w = 0.0f;
        if (c->outPos < pd_conv::B) w = c->outBlock[c->outPos++];
        if (c->inFill == pd_conv::B) { c->runBlock(); c->inFill = 0; }
        if (out_l) out_l[i] = dl * (1.0f - c->mix) + w * c->mix;
        if (out_r) out_r[i] = dr * (1.0f - c->mix) + w * c->mix;
    }
}

void pd_conv_destroy(pd_conv* c) { delete c; }


} // extern "C"

