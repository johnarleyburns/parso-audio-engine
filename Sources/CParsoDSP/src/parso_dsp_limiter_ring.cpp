#include "parso_dsp.h"

#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>
#include <vector>

#if defined(__SSE__)
#include <xmmintrin.h>
#if defined(__SSE3__)
#include <pmmintrin.h>
#endif
#endif

extern "C" {

struct pd_limiter {
    double sampleRate;
    float ceiling;
    float gain = 1.0f;
    float release;
    std::vector<float> leftDelay;
    std::vector<float> rightDelay;
    size_t index = 0;

    pd_limiter(double sr, float ceilingDB)
        : sampleRate(sr),
          ceiling(std::pow(10.0f, ceilingDB / 20.0f)),
          release(static_cast<float>(1.0 - std::exp(-1.0 / (sr * 0.075)))) {}

    bool initialize() {
        // Two milliseconds gives the detector time to react while keeping
        // master-output latency below the specified 1–5 ms range.
        const double delayFrames = std::ceil(sampleRate * 0.002);
        if (!std::isfinite(delayFrames) || delayFrames < 1.0 || delayFrames > 1'000'000.0) {
            return false;
        }
        const size_t length = static_cast<size_t>(delayFrames) + 1;
        leftDelay.assign(length, 0.0f);
        rightDelay.assign(length, 0.0f);
        return true;
    }
};

struct pd_ring {
    size_t elementSize;
    size_t capacity;
    size_t mask;
    std::vector<unsigned char> storage;
    std::atomic<size_t> writeIndex{0};
    std::atomic<size_t> readIndex{0};

    pd_ring(size_t element_size, size_t capacity_pow2)
        : elementSize(element_size), capacity(capacity_pow2), mask(capacity_pow2 - 1),
          storage(element_size * capacity_pow2) {}
};
pd_limiter* pd_limiter_create(double sample_rate, float ceiling_db) {
    if (!std::isfinite(sample_rate) || sample_rate <= 0.0) return nullptr;
    if (!std::isfinite(ceiling_db)) ceiling_db = -0.3f;
    ceiling_db = std::fmax(-60.0f, std::fmin(0.0f, ceiling_db));
    try {
        pd_limiter* limiter = new (std::nothrow) pd_limiter(sample_rate, ceiling_db);
        if (limiter == nullptr || !limiter->initialize()) {
            delete limiter;
            return nullptr;
        }
        return limiter;
    } catch (...) {
        return nullptr;
    }
}

void pd_limiter_set_ceiling(pd_limiter* limiter, float ceiling_db) {
    if (limiter == nullptr) return;
    if (!std::isfinite(ceiling_db)) ceiling_db = -0.3f;
    ceiling_db = std::fmax(-60.0f, std::fmin(0.0f, ceiling_db));
    limiter->ceiling = std::pow(10.0f, ceiling_db / 20.0f);
}

void pd_limiter_process(pd_limiter* limiter, float* left, float* right, int frames) {
    if (limiter == nullptr || frames <= 0 || limiter->leftDelay.empty() ||
        limiter->rightDelay.empty()) return;
    for (int frame = 0; frame < frames; ++frame) {
        const float inputLeft = left == nullptr ? 0.0f : left[frame];
        const float inputRight = right == nullptr ? 0.0f : right[frame];
        const float peak = std::fmax(std::fabs(inputLeft), std::fabs(inputRight));
        const float desiredGain = peak > limiter->ceiling ? limiter->ceiling / peak : 1.0f;
        if (desiredGain < limiter->gain) {
            limiter->gain = desiredGain;
        } else {
            limiter->gain += (1.0f - limiter->gain) * limiter->release;
        }

        const float delayedLeft = limiter->leftDelay[limiter->index];
        const float delayedRight = limiter->rightDelay[limiter->index];
        limiter->leftDelay[limiter->index] = inputLeft;
        limiter->rightDelay[limiter->index] = inputRight;
        limiter->index = limiter->index + 1 < limiter->leftDelay.size()
            ? limiter->index + 1 : 0;

        const float delayedPeak = std::fmax(std::fabs(delayedLeft), std::fabs(delayedRight));
        const float outputGain = delayedPeak > limiter->ceiling
            ? std::fmin(limiter->gain, limiter->ceiling / delayedPeak) : limiter->gain;
        if (left != nullptr) left[frame] = delayedLeft * outputGain;
        if (right != nullptr) right[frame] = delayedRight * outputGain;
    }
}

void pd_limiter_destroy(pd_limiter* limiter) { delete limiter; }

pd_ring* pd_ring_create(size_t element_size, size_t capacity_pow2) {
    if (element_size == 0 || capacity_pow2 == 0 ||
        (capacity_pow2 & (capacity_pow2 - 1)) != 0 ||
        element_size > std::numeric_limits<size_t>::max() / capacity_pow2) {
        return nullptr;
    }
    try {
        return new (std::nothrow) pd_ring(element_size, capacity_pow2);
    } catch (...) {
        return nullptr;
    }
}

int pd_ring_push(pd_ring* ring, const void* element) {
    if (ring == nullptr || element == nullptr) return 0;
    const size_t write = ring->writeIndex.load(std::memory_order_relaxed);
    const size_t read = ring->readIndex.load(std::memory_order_acquire);
    if (write - read >= ring->capacity) return 0;
    const size_t offset = (write & ring->mask) * ring->elementSize;
    std::memcpy(ring->storage.data() + offset, element, ring->elementSize);
    ring->writeIndex.store(write + 1, std::memory_order_release);
    return 1;
}

int pd_ring_pop(pd_ring* ring, void* element) {
    if (ring == nullptr || element == nullptr) return 0;
    const size_t read = ring->readIndex.load(std::memory_order_relaxed);
    const size_t write = ring->writeIndex.load(std::memory_order_acquire);
    if (read == write) return 0;
    const size_t offset = (read & ring->mask) * ring->elementSize;
    std::memcpy(element, ring->storage.data() + offset, ring->elementSize);
    ring->readIndex.store(read + 1, std::memory_order_release);
    return 1;
}

void pd_ring_destroy(pd_ring* ring) { delete ring; }

void pd_enable_ftz(void) {
#if defined(__SSE__)
    _MM_SET_FLUSH_ZERO_MODE(_MM_FLUSH_ZERO_ON);
#if defined(__SSE3__)
    _MM_SET_DENORMALS_ZERO_MODE(_MM_DENORMALS_ZERO_ON);
#endif
#elif defined(__aarch64__) || defined(__arm64__)
    // ARM64 exposes flush-to-zero through FPCR bit 24. This is thread-local
    // state, matching the scope of the x86 MXCSR controls above.
    uint64_t fpcr = 0;
    __asm__ volatile("mrs %0, fpcr" : "=r"(fpcr));
    fpcr |= (uint64_t(1) << 24);
    __asm__ volatile("msr fpcr, %0" : : "r"(fpcr));
#endif
}


} // extern "C"
