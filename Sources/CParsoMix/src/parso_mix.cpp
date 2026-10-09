// CParsoMix real-time core. See parso_mix.h for the contract.
#include "parso_mix.h"
#include "parso_dsp.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <limits>
#include <new>
#include <vector>

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr double kCrossoverHz = 150.0;
constexpr double kKeylockThreshold = 0.002;   // |tempo - 1| above this time-stretches
constexpr double kCutRampSeconds = 0.003;

struct Biquad {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    double z1 = 0, z2 = 0;
    void butterworth(double sr, double hz, bool high) {
        const double w0 = 2.0 * kPi * hz / sr;
        const double c = std::cos(w0), alpha = std::sin(w0) / (2.0 * std::sqrt(0.5));
        const double a0 = 1.0 + alpha;
        if (high) {
            b0 = (1.0 + c) / 2.0 / a0; b1 = -(1.0 + c) / a0; b2 = b0;
        } else {
            b0 = (1.0 - c) / 2.0 / a0; b1 = (1.0 - c) / a0; b2 = b0;
        }
        a1 = -2.0 * c / a0; a2 = (1.0 - alpha) / a0;
        z1 = z2 = 0;
    }
    inline double process(double x) {           // transposed direct form II
        const double y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }
};

// 4th-order Linkwitz-Riley: each band is a squared 2nd-order Butterworth, so the
// two bands are in phase and sum to an all-pass with a flat magnitude.
struct Crossover {
    Biquad lp1, lp2, hp1, hp2;
    void setup(double sr) {
        lp1.butterworth(sr, kCrossoverHz, false); lp2.butterworth(sr, kCrossoverHz, false);
        hp1.butterworth(sr, kCrossoverHz, true);  hp2.butterworth(sr, kCrossoverHz, true);
    }
    inline void split(double x, double& lo, double& hi) {
        lo = lp2.process(lp1.process(x));
        hi = hp2.process(hp1.process(x));
    }
};

inline double smoothstep(double x) {
    x = std::min(1.0, std::max(0.0, x));
    return x * x * (3.0 - 2.0 * x);
}

inline float sourceAt(const float* channel, int64_t frames, int64_t index) {
    return (index < 0 || index >= frames) ? 0.0f : channel[index];
}

inline float hermite(const float* channel, int64_t frames, double position) {
    const double base = std::floor(position);
    const int64_t i = static_cast<int64_t>(base);
    const double t = position - base;
    const double xm1 = sourceAt(channel, frames, i - 1), x0 = sourceAt(channel, frames, i);
    const double x1 = sourceAt(channel, frames, i + 1), x2 = sourceAt(channel, frames, i + 2);
    const double c1 = 0.5 * (x1 - xm1);
    const double c2 = xm1 - 2.5 * x0 + 2.0 * x1 - 0.5 * x2;
    const double c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1);
    return static_cast<float>(((c3 * t + c2) * t + c1) * t + x0);
}

enum RecipeKind { kNone = 0, kBassSwap = 1, kCut = 2 };

struct Recipe {
    int kind = kNone;
    int outgoing = -1, incoming = -1;
    double start = 0, framesPerBeat = 1;   // bass swap
    int overlapBeats = 64;
    double cut = 0, fade = 0;              // cut
};

struct Deck {
    std::atomic<int> state{PM_DECK_IDLE};
    std::atomic<int> stopRequested{0};
    std::atomic<double> position{std::numeric_limits<double>::quiet_NaN()};
    const float* channel[2] = {nullptr, nullptr};
    int64_t frames = 0;
    double startPosition = 0, tempo = 1;
    float gain = 1;
    bool keylock = false;
    int64_t startFrame = 0;
    // Keylock: integer source frame fed so far and the exact-clock origin.
    int64_t fed = 0;
    double inputOrigin = 0;          // source frame of input at the start frame (after the seek block)
    pd_stretch* stretch = nullptr;
    std::vector<float> inL, inR, outL, outR;
    Crossover xo[2];
};

} // namespace

struct pm_engine {
    double sampleRate = 48000;
    int maxFrames = 512;
    int maxInput = 0;
    std::atomic<int64_t> masterFrame{0};
    Deck decks[PM_MAX_DECKS];
    // Recipe hand-off: control writes the slot it is not publishing, then bumps the version.
    Recipe slots[2];
    std::atomic<uint32_t> recipeVersion{0};
    uint32_t seenVersion = 0;         // render thread
    Recipe active;                    // render thread
};

namespace {

bool validDeck(const pm_engine* e, int d) { return e != nullptr && d >= 0 && d < PM_MAX_DECKS; }

// Copies source frames [first, first + count) of both channels into the deck's
// input scratch, zero outside the track.
void gather(Deck& deck, int64_t first, int count) {
    for (int i = 0; i < count; ++i) {
        deck.inL[static_cast<size_t>(i)] = sourceAt(deck.channel[0], deck.frames, first + i);
        deck.inR[static_cast<size_t>(i)] = sourceAt(deck.channel[1], deck.frames, first + i);
    }
}

// Band gains (low, high) for `deck` at master frame m under the active recipe.
inline void bandGains(const Recipe& r, int deck, double m, double sampleRate, double& low, double& high) {
    low = high = 1.0;
    if (r.kind == kBassSwap) {
        const double b = (m - r.start) / r.framesPerBeat;
        const double q = r.overlapBeats / 4.0;
        const double swap = smoothstep((b - (2.0 * q - 0.25)) / 0.25);
        if (deck == r.outgoing) {
            low = 1.0 - swap;
            high = 1.0 - smoothstep((b - 3.0 * q) / q);
        } else if (deck == r.incoming) {
            low = swap;
            high = smoothstep(b / q);
        }
    } else if (r.kind == kCut) {
        if (deck == r.outgoing) {
            const double from = r.cut - r.fade;
            const double g = m < from ? 1.0 : (m < r.cut ? std::cos(0.5 * kPi * (m - from) / r.fade) : 0.0);
            low = high = g;
        } else if (deck == r.incoming) {
            const double ramp = kCutRampSeconds * sampleRate;
            const double g = m < r.cut - ramp ? 0.0 : (m < r.cut ? (m - (r.cut - ramp)) / ramp : 1.0);
            low = high = g;
        }
    }
}

double recipeEnd(const Recipe& r) {
    if (r.kind == kBassSwap) return r.start + r.overlapBeats * r.framesPerBeat;
    if (r.kind == kCut) return r.cut;
    return 0;
}

void publish(pm_engine* e, const Recipe& r) {
    const uint32_t next = e->recipeVersion.load(std::memory_order_relaxed) + 1;
    e->slots[next & 1] = r;
    e->recipeVersion.store(next, std::memory_order_release);
}

// Renders `count` frames of the deck's source (before crossover) into deck.outL/outR
// starting at output index `offset`, for master frames [m, m + count).
void readDeck(pm_engine* e, Deck& deck, int64_t m, int offset, int count) {
    if (!deck.keylock) {
        for (int i = 0; i < count; ++i) {
            const double pos = deck.startPosition + static_cast<double>(m + i - deck.startFrame) * deck.tempo;
            deck.outL[static_cast<size_t>(offset + i)] = hermite(deck.channel[0], deck.frames, pos);
            deck.outR[static_cast<size_t>(offset + i)] = hermite(deck.channel[1], deck.frames, pos);
        }
        return;
    }
    // Exact clock: input fed by the end of this block is origin + elapsed * tempo.
    const double end = deck.inputOrigin + static_cast<double>(m + count - deck.startFrame) * deck.tempo;
    int64_t target = static_cast<int64_t>(std::floor(end));
    int need = static_cast<int>(std::min<int64_t>(std::max<int64_t>(0, target - deck.fed), e->maxInput));
    gather(deck, deck.fed, need);
    deck.fed += need;
    const float* in[2] = {deck.inL.data(), deck.inR.data()};
    float* out[2] = {deck.outL.data() + offset, deck.outR.data() + offset};
    pd_stretch_process(deck.stretch, in, need, out, count);
}

} // namespace

extern "C" {

pm_engine* pm_create(double sample_rate, int max_frames) {
    if (!std::isfinite(sample_rate) || sample_rate <= 0 || max_frames <= 0) return nullptr;
    pm_engine* e = new (std::nothrow) pm_engine;
    if (e == nullptr) return nullptr;
    e->sampleRate = sample_rate;
    e->maxFrames = max_frames;
    // Room for a render block at up to 4x tempo, or a stretcher seek block.
    e->maxInput = std::max(max_frames * 4 + 16, static_cast<int>(sample_rate * 0.5));
    try {
        for (Deck& d : e->decks) {
            d.stretch = pd_stretch_create(sample_rate, 2, e->maxInput, max_frames);
            d.inL.assign(static_cast<size_t>(e->maxInput), 0.0f);
            d.inR.assign(static_cast<size_t>(e->maxInput), 0.0f);
            d.outL.assign(static_cast<size_t>(max_frames), 0.0f);
            d.outR.assign(static_cast<size_t>(max_frames), 0.0f);
            if (d.stretch == nullptr) { pm_destroy(e); return nullptr; }
        }
    } catch (...) {
        pm_destroy(e);
        return nullptr;
    }
    return e;
}

void pm_destroy(pm_engine* e) {
    if (e == nullptr) return;
    for (Deck& d : e->decks) pd_stretch_destroy(d.stretch);
    delete e;
}

int pm_deck_prepare(pm_engine* e, int deck, const float* left, const float* right,
                    int64_t frames, double source_position, double tempo, float gain) {
    if (!validDeck(e, deck) || left == nullptr || frames <= 0 || !std::isfinite(source_position) ||
        !std::isfinite(tempo) || tempo <= 0.25 || tempo > 4.0 || !std::isfinite(gain)) return -1;
    Deck& d = e->decks[deck];
    const int state = d.state.load(std::memory_order_acquire);
    if (state != PM_DECK_IDLE && state != PM_DECK_FINISHED) return -1;
    d.channel[0] = left;
    d.channel[1] = right != nullptr ? right : left;
    d.frames = frames;
    d.startPosition = source_position;
    d.tempo = tempo;
    d.gain = gain;
    d.keylock = std::fabs(tempo - 1.0) > kKeylockThreshold;
    d.xo[0].setup(e->sampleRate);
    d.xo[1].setup(e->sampleRate);
    d.stopRequested.store(0, std::memory_order_relaxed);
    d.position.store(std::numeric_limits<double>::quiet_NaN(), std::memory_order_relaxed);
    if (d.keylock) {
        const int seek = std::min(pd_stretch_seek_length(d.stretch, tempo), e->maxInput);
        const int64_t first = static_cast<int64_t>(std::llround(source_position));
        gather(d, first, seek);
        const float* in[2] = {d.inL.data(), d.inR.data()};
        pd_stretch_output_seek(d.stretch, in, seek);
        d.fed = first + seek;
        d.inputOrigin = static_cast<double>(first + seek);
    }
    d.state.store(PM_DECK_IDLE, std::memory_order_release);
    return 0;
}

int pm_deck_start(pm_engine* e, int deck, int64_t start_frame) {
    if (!validDeck(e, deck) || e->decks[deck].channel[0] == nullptr) return -1;
    Deck& d = e->decks[deck];
    if (d.state.load(std::memory_order_acquire) != PM_DECK_IDLE) return -1;
    d.startFrame = start_frame;
    d.state.store(PM_DECK_ARMED, std::memory_order_release);
    return 0;
}

void pm_deck_stop(pm_engine* e, int deck) {
    if (validDeck(e, deck)) e->decks[deck].stopRequested.store(1, std::memory_order_release);
}

int pm_deck_reset(pm_engine* e, int deck) {
    if (!validDeck(e, deck)) return -1;
    Deck& d = e->decks[deck];
    int expected = PM_DECK_FINISHED;
    return d.state.compare_exchange_strong(expected, PM_DECK_IDLE, std::memory_order_acq_rel) ? 0 : -1;
}

int pm_deck_state_of(pm_engine* e, int deck) {
    return validDeck(e, deck) ? e->decks[deck].state.load(std::memory_order_acquire) : -1;
}

double pm_deck_position(pm_engine* e, int deck) {
    return validDeck(e, deck) ? e->decks[deck].position.load(std::memory_order_relaxed)
                              : std::numeric_limits<double>::quiet_NaN();
}

int pm_deck_keylocked(pm_engine* e, int deck) {
    return validDeck(e, deck) && e->decks[deck].keylock ? 1 : 0;
}

void pm_schedule_bass_swap(pm_engine* e, int outgoing, int incoming, double start_frame,
                           double frames_per_beat, int overlap_beats) {
    if (!validDeck(e, outgoing) || !validDeck(e, incoming) || outgoing == incoming ||
        !(frames_per_beat > 0) || overlap_beats < 4) return;
    Recipe r;
    r.kind = kBassSwap; r.outgoing = outgoing; r.incoming = incoming;
    r.start = start_frame; r.framesPerBeat = frames_per_beat; r.overlapBeats = overlap_beats;
    publish(e, r);
}

void pm_schedule_cut(pm_engine* e, int outgoing, int incoming, double cut_frame, double fade_frames) {
    if (!validDeck(e, outgoing) || !validDeck(e, incoming) || outgoing == incoming || !(fade_frames > 0)) return;
    Recipe r;
    r.kind = kCut; r.outgoing = outgoing; r.incoming = incoming;
    r.cut = cut_frame; r.fade = fade_frames;
    publish(e, r);
}

void pm_clear_recipe(pm_engine* e) {
    if (e != nullptr) publish(e, Recipe{});
}

int64_t pm_master_frame(pm_engine* e) {
    return e != nullptr ? e->masterFrame.load(std::memory_order_relaxed) : 0;
}

void pm_render(pm_engine* e, float* left, float* right, int frames) {
    if (left == nullptr || right == nullptr || frames <= 0) return;
    std::fill(left, left + frames, 0.0f);
    std::fill(right, right + frames, 0.0f);
    if (e == nullptr) return;
    frames = std::min(frames, e->maxFrames);
    const int64_t m0 = e->masterFrame.load(std::memory_order_relaxed);

    const uint32_t version = e->recipeVersion.load(std::memory_order_acquire);
    if (version != e->seenVersion) {
        e->seenVersion = version;
        e->active = e->slots[version & 1];
    }
    Recipe& r = e->active;

    for (int index = 0; index < PM_MAX_DECKS; ++index) {
        Deck& d = e->decks[index];
        int state = d.state.load(std::memory_order_acquire);
        if (state == PM_DECK_ARMED || state == PM_DECK_PLAYING) {
            if (d.stopRequested.exchange(0, std::memory_order_acq_rel) != 0) {
                d.position.store(std::numeric_limits<double>::quiet_NaN(), std::memory_order_relaxed);
                d.state.store(PM_DECK_FINISHED, std::memory_order_release);
                continue;
            }
        }
        if (state == PM_DECK_ARMED && m0 + frames > d.startFrame) {
            state = PM_DECK_PLAYING;
            d.state.store(PM_DECK_PLAYING, std::memory_order_release);
        }
        if (state != PM_DECK_PLAYING) continue;

        const int offset = static_cast<int>(std::max<int64_t>(0, d.startFrame - m0));
        const int count = frames - offset;
        std::fill(d.outL.begin(), d.outL.begin() + offset, 0.0f);
        std::fill(d.outR.begin(), d.outR.begin() + offset, 0.0f);
        readDeck(e, d, m0 + offset, offset, count);

        for (int i = offset; i < frames; ++i) {
            const double m = static_cast<double>(m0 + i);
            double gl, gh;
            bandGains(r, index, m, e->sampleRate, gl, gh);
            double lo, hi;
            d.xo[0].split(d.outL[static_cast<size_t>(i)], lo, hi);
            left[i] += static_cast<float>(d.gain * (lo * gl + hi * gh));
            d.xo[1].split(d.outR[static_cast<size_t>(i)], lo, hi);
            right[i] += static_cast<float>(d.gain * (lo * gl + hi * gh));
        }

        const double endPosition = d.startPosition + static_cast<double>(m0 + frames - d.startFrame) * d.tempo;
        d.position.store(endPosition, std::memory_order_relaxed);
        // Keylock output lags its input by the stretcher's latency; allow a tail.
        const double tail = d.keylock ? 0.25 * e->sampleRate * d.tempo : 4.0;
        if (endPosition >= static_cast<double>(d.frames) + tail) {
            d.state.store(PM_DECK_FINISHED, std::memory_order_release);
        }
    }

    // Recipe completion: release the outgoing deck, then play flat.
    if (r.kind != kNone && static_cast<double>(m0 + frames) >= recipeEnd(r)) {
        Deck& out = e->decks[r.outgoing];
        if (out.state.load(std::memory_order_acquire) == PM_DECK_PLAYING) {
            out.position.store(std::numeric_limits<double>::quiet_NaN(), std::memory_order_relaxed);
            out.state.store(PM_DECK_FINISHED, std::memory_order_release);
        }
        r = Recipe{};
    }
    e->masterFrame.store(m0 + frames, std::memory_order_relaxed);
}

int pm_render_tempo(double sample_rate, const float* in_left, const float* in_right, int64_t frames,
                    double tempo, float* out_left, float* out_right, int64_t out_frames) {
    if (in_left == nullptr || out_left == nullptr || out_right == nullptr || frames <= 0 || out_frames <= 0 ||
        !std::isfinite(tempo) || tempo <= 0.25 || tempo > 4.0) return -1;
    constexpr int kBlock = 4096;
    pm_engine* e = pm_create(sample_rate, kBlock);
    if (e == nullptr) return -1;
    Deck& d = e->decks[0];
    if (pm_deck_prepare(e, 0, in_left, in_right != nullptr ? in_right : in_left, frames, 0.0, tempo, 1.0f) != 0) {
        pm_destroy(e);
        return -1;
    }
    for (int64_t m = 0; m < out_frames; m += kBlock) {
        const int count = static_cast<int>(std::min<int64_t>(kBlock, out_frames - m));
        d.startFrame = 0;
        readDeck(e, d, m, 0, count);
        std::copy(d.outL.begin(), d.outL.begin() + count, out_left + m);
        std::copy(d.outR.begin(), d.outR.begin() + count, out_right + m);
    }
    pm_destroy(e);
    return 0;
}

} // extern "C"
