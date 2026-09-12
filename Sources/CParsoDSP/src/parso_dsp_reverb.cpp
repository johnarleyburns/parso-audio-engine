#include "parso_dsp.h"

#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>
#include <vector>

struct FreeverbComb {
    std::vector<float> buffer;
    size_t index = 0;
    float filterStore = 0.0f;
    float feedback = 0.84f;
    float damp = 0.2f;

    void initialize(int length) {
        buffer.assign(static_cast<size_t>(length), 0.0f);
        index = 0;
        filterStore = 0.0f;
    }

    float process(float input) {
        const float output = buffer[index];
        filterStore = output * (1.0f - damp) + filterStore * damp;
        buffer[index] = input + filterStore * feedback;
        index = index + 1 < buffer.size() ? index + 1 : 0;
        return output;
    }
};

struct FreeverbAllpass {
    std::vector<float> buffer;
    size_t index = 0;
    static constexpr float feedback = 0.5f;

    void initialize(int length) {
        buffer.assign(static_cast<size_t>(length), 0.0f);
        index = 0;
    }

    float process(float input) {
        const float buffered = buffer[index];
        const float output = -input + buffered;
        buffer[index] = input + buffered * feedback;
        index = index + 1 < buffer.size() ? index + 1 : 0;
        return output;
    }
};

extern "C" {

struct pd_reverb {
    double sampleRate;
    double smoothing;
    std::array<FreeverbComb, 8> combLeft;
    std::array<FreeverbComb, 8> combRight;
    std::array<FreeverbAllpass, 4> allpassLeft;
    std::array<FreeverbAllpass, 4> allpassRight;
    float room = 0.5f;
    float targetRoom = 0.5f;
    float damp = 0.5f;
    float targetDamp = 0.5f;
    float width = 1.0f;
    float targetWidth = 1.0f;
    float mix = 0.3f;
    float targetMix = 0.3f;
    bool hasProcessed = false;

    explicit pd_reverb(double sr)
        : sampleRate(sr), smoothing(1.0 - std::exp(-1.0 / (sr * 0.010))) {}

    bool initialize() {
        static constexpr int combTuning[8] = {1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617};
        static constexpr int allpassTuning[4] = {556, 441, 341, 225};
        const double scale = sampleRate / 44'100.0;
        if (!std::isfinite(scale) || scale <= 0.0 || scale > 1'000.0) return false;
        const int spread = std::max(1, static_cast<int>(std::lround(23.0 * scale)));

        for (int i = 0; i < 8; ++i) {
            const int baseLength = std::max(1, static_cast<int>(std::lround(combTuning[i] * scale)));
            combLeft[i].initialize(baseLength);
            combRight[i].initialize(baseLength + spread);
        }
        for (int i = 0; i < 4; ++i) {
            const int baseLength = std::max(1, static_cast<int>(std::lround(allpassTuning[i] * scale)));
            allpassLeft[i].initialize(baseLength);
            allpassRight[i].initialize(baseLength + spread);
        }
        return true;
    }
};

// Feedback Delay Network reverb (CDJ3000 parity C7) — an 8-line FDN with an
// orthonormal Hadamard feedback matrix (lossless mixing), per-line one-pole
// damping and slow delay modulation. A materially lusher / less metallic tail
// than the Freeverb topology, RT-safe and allocation-free once constructed.
struct pd_fdnverb {
    static constexpr int kLines = 8;
    static constexpr int kMaxDelay = 4800;          // 100 ms at 48 kHz
    double sampleRate;
    float lineBuf[kLines][kMaxDelay] = {};
    int writePos = 0;
    int baseLen[kLines] = {};
    float dampState[kLines] = {};
    float lfoPhase[kLines] = {};
    float size = 0.6f, decay = 0.6f, damp = 0.5f, mix = 0.3f;

    explicit pd_fdnverb(double sr) : sampleRate(sr) {
        // Mutually-prime-ish base lengths, scaled to ~20..90 ms by `size`.
        static constexpr int seed[kLines] = {1153, 1327, 1523, 1721, 1949, 2113, 2333, 2521};
        const double scale = sr / 48'000.0;
        for (int i = 0; i < kLines; ++i) {
            baseLen[i] = std::max(1, std::min(kMaxDelay - 2,
                static_cast<int>(std::lround(seed[i] * scale))));
            lfoPhase[i] = static_cast<float>(i) * 0.37f;
        }
    }

    static void hadamard8(float* v) {
        // In-place fast Walsh–Hadamard transform, then 1/sqrt(8) normalise.
        for (int step = 1; step < 8; step <<= 1) {
            for (int i = 0; i < 8; i += step << 1) {
                for (int j = i; j < i + step; ++j) {
                    const float a = v[j], b = v[j + step];
                    v[j] = a + b;
                    v[j + step] = a - b;
                }
            }
        }
        const float n = 0.35355339059f;  // 1/sqrt(8)
        for (int i = 0; i < 8; ++i) v[i] *= n;
    }
};
pd_reverb* pd_reverb_create(double sample_rate) {
    if (!std::isfinite(sample_rate) || sample_rate <= 0.0) return nullptr;
    try {
        pd_reverb* reverb = new (std::nothrow) pd_reverb(sample_rate);
        if (reverb == nullptr || !reverb->initialize()) {
            delete reverb;
            return nullptr;
        }
        return reverb;
    } catch (...) {
        return nullptr;
    }
}

void pd_reverb_set(pd_reverb* reverb, float room, float damp, float width, float mix) {
    if (reverb == nullptr) return;
    reverb->targetRoom = std::isfinite(room) ? std::fmax(0.0f, std::fmin(1.0f, room)) : 0.5f;
    reverb->targetDamp = std::isfinite(damp) ? std::fmax(0.0f, std::fmin(1.0f, damp)) : 0.5f;
    reverb->targetWidth = std::isfinite(width) ? std::fmax(0.0f, std::fmin(1.0f, width)) : 1.0f;
    reverb->targetMix = std::isfinite(mix) ? std::fmax(0.0f, std::fmin(1.0f, mix)) : 0.3f;
    if (!reverb->hasProcessed) {
        reverb->room = reverb->targetRoom;
        reverb->damp = reverb->targetDamp;
        reverb->width = reverb->targetWidth;
        reverb->mix = reverb->targetMix;
    }
}

void pd_reverb_process(pd_reverb* reverb, const float* in_left, const float* in_right,
                       float* out_left, float* out_right, int frames) {
    if (reverb == nullptr || out_left == nullptr || out_right == nullptr || frames <= 0) return;
    reverb->hasProcessed = true;
    for (int frame = 0; frame < frames; ++frame) {
        reverb->room += static_cast<float>((reverb->targetRoom - reverb->room) * reverb->smoothing);
        reverb->damp += static_cast<float>((reverb->targetDamp - reverb->damp) * reverb->smoothing);
        reverb->width += static_cast<float>((reverb->targetWidth - reverb->width) * reverb->smoothing);
        reverb->mix += static_cast<float>((reverb->targetMix - reverb->mix) * reverb->smoothing);

        const float feedback = 0.7f + reverb->room * 0.28f;
        const float damp = reverb->damp * 0.4f;
        for (int i = 0; i < 8; ++i) {
            reverb->combLeft[i].feedback = feedback;
            reverb->combLeft[i].damp = damp;
            reverb->combRight[i].feedback = feedback;
            reverb->combRight[i].damp = damp;
        }

        const float left = in_left == nullptr ? 0.0f : in_left[frame];
        const float right = in_right == nullptr ? 0.0f : in_right[frame];
        const float input = (left + right) * 0.5f * 0.015f;
        float wetLeft = 0.0f;
        float wetRight = 0.0f;
        for (int i = 0; i < 8; ++i) {
            wetLeft += reverb->combLeft[i].process(input);
            wetRight += reverb->combRight[i].process(input);
        }
        for (int i = 0; i < 4; ++i) {
            wetLeft = reverb->allpassLeft[i].process(wetLeft);
            wetRight = reverb->allpassRight[i].process(wetRight);
        }

        const float wetLeftStereo = 0.5f * ((1.0f + reverb->width) * wetLeft +
                                            (1.0f - reverb->width) * wetRight);
        const float wetRightStereo = 0.5f * ((1.0f + reverb->width) * wetRight +
                                             (1.0f - reverb->width) * wetLeft);
        out_left[frame] = left * (1.0f - reverb->mix) + wetLeftStereo * reverb->mix;
        out_right[frame] = right * (1.0f - reverb->mix) + wetRightStereo * reverb->mix;
    }
}

void pd_reverb_destroy(pd_reverb* reverb) { delete reverb; }

pd_fdnverb* pd_fdnverb_create(double sample_rate) {
    if (!std::isfinite(sample_rate) || sample_rate <= 0.0) return nullptr;
    return new (std::nothrow) pd_fdnverb(sample_rate);
}

void pd_fdnverb_set(pd_fdnverb* r, float size, float decay, float damp, float mix) {
    if (!r) return;
    auto clamp01 = [](float x) { return std::isfinite(x) ? std::max(0.0f, std::min(1.0f, x)) : 0.0f; };
    r->size = clamp01(size);
    r->decay = clamp01(decay);
    r->damp = clamp01(damp);
    r->mix = clamp01(mix);
}

void pd_fdnverb_process(pd_fdnverb* r, const float* in_l, const float* in_r,
                        float* out_l, float* out_r, int frames) {
    if (!r || frames <= 0) return;
    const int L = pd_fdnverb::kLines;
    const int maxD = pd_fdnverb::kMaxDelay;
    // Feedback gain from `decay`: 0 -> short, 1 -> ~6 s RT60-ish.
    const float g = 0.55f + 0.44f * r->decay;
    const float dampCoef = 0.05f + 0.9f * r->damp;   // one-pole lowpass amount
    const float sizeScale = 0.35f + 0.65f * r->size;
    const float lfoInc = 0.6f / static_cast<float>(r->sampleRate);
    for (int n = 0; n < frames; ++n) {
        const float dryL = in_l ? in_l[n] : 0.0f;
        const float dryR = in_r ? in_r[n] : (in_l ? in_l[n] : 0.0f);
        const float inMono = 0.5f * (dryL + dryR);

        float taps[8];
        for (int i = 0; i < L; ++i) {
            r->lfoPhase[i] += lfoInc;
            if (r->lfoPhase[i] > 1.0f) r->lfoPhase[i] -= 1.0f;
            const float mod = 12.0f * std::sin(6.2831853f * r->lfoPhase[i]);
            int d = static_cast<int>(std::lround(r->baseLen[i] * sizeScale + mod));
            d = std::max(1, std::min(maxD - 1, d));
            int rp = r->writePos - d;
            if (rp < 0) rp += maxD;
            taps[i] = r->lineBuf[i][rp];
        }

        float mixed[8];
        for (int i = 0; i < L; ++i) mixed[i] = taps[i];
        pd_fdnverb::hadamard8(mixed);

        for (int i = 0; i < L; ++i) {
            float v = inMono + g * mixed[i];
            // per-line damping (one-pole lowpass in the feedback path)
            r->dampState[i] += dampCoef * (v - r->dampState[i]);
            v = r->dampState[i];
            if (!std::isfinite(v)) v = 0.0f;
            r->lineBuf[i][r->writePos] = v;
        }
        r->writePos = (r->writePos + 1) % maxD;

        // Even lines -> left, odd -> right; light cross-feed for width.
        float wetL = 0.0f, wetR = 0.0f;
        for (int i = 0; i < L; ++i) {
            if (i & 1) wetR += taps[i]; else wetL += taps[i];
        }
        wetL *= 0.5f; wetR *= 0.5f;
        const float outL = dryL * (1.0f - r->mix) + wetL * r->mix;
        const float outR = dryR * (1.0f - r->mix) + wetR * r->mix;
        if (out_l) out_l[n] = outL;
        if (out_r) out_r[n] = outR;
    }
}

void pd_fdnverb_destroy(pd_fdnverb* r) { delete r; }


} // extern "C"

