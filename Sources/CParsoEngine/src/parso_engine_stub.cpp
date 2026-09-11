// CParsoEngine's allocation-free two-deck render core.
// Control-side setup may allocate the handle; pe_render/pe_step only consume
// resident caller-owned PCM and fixed-size command/control state.
#include "parso_engine.h"
#include "parso_dsp.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <new>

namespace {

constexpr uint32_t kCommandCapacity = 256;
constexpr uint32_t kEventCapacity = 1024;
constexpr float kPi = 3.14159265358979323846f;
constexpr float kHalfPi = kPi * 0.5f;

// Per-deck 4-voice stem overlay (Phase 6b item 1). When armed, the deck's
// source sample is the gain-weighted sum of the present voices instead of the
// single full-mix reader. Gains are one-pole smoothed so arming/muting a voice
// never clicks.
struct StemVoice {
    const float* channels[2] = {nullptr, nullptr};
    int channelCount = 0;
    int64_t frames = 0;
    bool present = false;
    bool muted = false;
    bool soloed = false;
    float gain = 1.0f;
    float smoothedGain = 1.0f;
};

struct DeckState {
    const float* channels[2] = {nullptr, nullptr};
    int channelCount = 0;
    int64_t frames = 0;
    double sampleRate = 0.0;
    double position = 0.0;
    double shadowPosition = 0.0;
    bool playing = false;
    bool slip = false;
    bool reverse = false;   // CDJ3000 parity C2 — REV / Slip Reverse
    // Vinyl Speed Adjust (CDJ3000 parity C2): motorLevel eases toward motorTarget
    // (0 = stopped, 1 = full speed) at brake / spin-up rates. Zero seconds == the
    // classic instant start/stop.
    float motorLevel = 1.0f;
    float motorTarget = 1.0f;
    float brakeSeconds = 0.0f;
    float spinupSeconds = 0.0f;
    // Fade-in cue (CDJ3000 parity C6): one-shot gain ramp 0->1 after a cue jump.
    float cueFadeGain = 1.0f;
    float cueFadeRate = 0.0f;
    // Stems (item 1).
    StemVoice stems[4];
    bool stemsArmed = false;
    // Per-deck beat echo (item 3): post-fader / pre-crossfader delay line.
    bool echoOn = false;
    bool echoTail = false;
    int echoTailFrames = 0;
    float echoBeats = 1.0f;
    float echoDepth = 0.5f;
    float echoFeedback = 0.4f;
    double echoBpm = 120.0;
    // Per-deck sync + effective rate published from the control side (item 2).
    bool synced = false;
    double effectiveBpm = 0.0;
    double beatPhase = 0.0;
    // Deferred grid-quantized jump (CDJ3000 parity C1b): when a jump command
    // arrives with i2 == 2 the target is stashed and applied when the deck's
    // playhead next crosses a grid line (grain in beats, default 1).
    bool pendingJump = false;
    double pendingJumpTarget = 0.0;
    double pendingJumpCountdown = 0.0;   // frames until the jump fires
    int64_t cueFrame = 0;
    bool cueSet = false;
    int64_t hotCueFrames[8] = {};
    bool hotCueSet[8] = {};
    double loopIn = 0.0;
    double loopStart = 0.0;
    double loopEnd = 0.0;
    bool loopInSet = false;
    bool loopAvailable = false;
    bool loopActive = false;
    float eqLowGain = 1.0f;
    float eqMidGain = 1.0f;
    float eqHighGain = 1.0f;
    float lowState = 0.0f;
    float highState = 0.0f;
    float colorLowState = 0.0f;
    float colorHighState = 0.0f;
    float colorDelay[24000] = {};
    uint32_t colorDelayIndex = 0;
    uint32_t colorNoiseState = 0x13579BDFu;
};

struct SamplerSlot {
    const float* channels[2] = {nullptr, nullptr};
    int channelCount = 0;
    int64_t frames = 0;
    int64_t position = 0;
    bool playing = false;
    int mode = 0;          // 0 one-shot, 1 loop, 2 gate
    float gain = 1.0f;
};

struct MicState {
    const float* channels[2] = {nullptr, nullptr};
    int channelCount = 0;
    int64_t frames = 0;
    double sampleRate = 0.0;
    double position = 0.0;
};

struct CommandQueue {
    pe_command commands[kCommandCapacity]{};
    std::atomic<uint32_t> writeIndex{0};
    std::atomic<uint32_t> readIndex{0};
};

struct EventQueue {
    pe_event events[kEventCapacity]{};
    std::atomic<uint32_t> writeIndex{0};
    std::atomic<uint32_t> readIndex{0};
};

struct ControlState {
    std::atomic<float> crossfader{0.0f};
    std::atomic<float> curve{0.0f};
    std::atomic<float> masterLevel{0.8f};
    std::atomic<float> limiterCeilingDB{-0.3f};
    std::atomic<float> micLevel{0.0f};
    std::atomic<float> micEqLow{0.0f};
    std::atomic<float> micEqHigh{0.0f};
    std::atomic<float> micTalkoverOn{0.0f};
    std::atomic<float> micTalkoverDepthDb{-14.0f};
    std::atomic<float> micTalkoverThreshold{0.02f};
    std::atomic<float> micFxOn{0.0f};
    std::atomic<float> cueMasterMix{0.5f};
    std::atomic<float> masterCue{0.0f};
    std::atomic<float> headphoneLevel{0.7f};
    std::atomic<float> cuePFL[PE_MAX_DECKS]{{0.0f}, {0.0f}, {0.0f}, {0.0f}};
    std::atomic<float> xfadeAssign[PE_MAX_DECKS]{{2.0f}, {2.0f}, {2.0f}, {2.0f}};
    std::atomic<float> faderStart[PE_MAX_DECKS]{{0.0f}, {0.0f}, {0.0f}, {0.0f}};
    std::atomic<float> eqLow[PE_MAX_DECKS]{{0.0f}, {0.0f}, {0.0f}, {0.0f}};
    std::atomic<float> eqMid[PE_MAX_DECKS]{{0.0f}, {0.0f}, {0.0f}, {0.0f}};
    std::atomic<float> eqHigh[PE_MAX_DECKS]{{0.0f}, {0.0f}, {0.0f}, {0.0f}};
    std::atomic<float> colorAmount[PE_MAX_DECKS]{{0.0f}, {0.0f}, {0.0f}, {0.0f}};
    std::atomic<float> colorKind[PE_MAX_DECKS]{{0.0f}, {0.0f}, {0.0f}, {0.0f}};
    std::atomic<float> beatFXKind{0.0f};
    std::atomic<float> beatFXBeats{0.5f};
    std::atomic<float> beatFXDepth{0.5f};
    std::atomic<float> beatFXAssign{0.0f};
    std::atomic<float> beatFXOn{0.0f};
    std::atomic<float> beatFXXpad{-1.0f};
    std::atomic<float> beatFXBand{0.0f};
    std::atomic<float> colorParam[PE_MAX_DECKS]{{0.5f}, {0.5f}, {0.5f}, {0.5f}};
    std::atomic<float> fader[PE_MAX_DECKS]{{1.0f}, {1.0f}, {1.0f}, {1.0f}};
    std::atomic<float> trim[PE_MAX_DECKS]{{0.5f}, {0.5f}, {0.5f}, {0.5f}};
    std::atomic<float> deckTimeRatio[PE_MAX_DECKS]{{1.0f}, {1.0f}, {1.0f}, {1.0f}};
    std::atomic<float> deckPitch[PE_MAX_DECKS]{{0.0f}, {0.0f}, {0.0f}, {0.0f}};
    std::atomic<float> deckKeylock[PE_MAX_DECKS]{{0.0f}, {0.0f}, {0.0f}, {0.0f}};
    std::atomic<float> limiterEnabled{1.0f};
    std::atomic<float> cueMode{0.0f};
    std::atomic<float> masterEqLow{0.0f};
    std::atomic<float> masterEqMid{0.0f};
    std::atomic<float> masterEqHigh{0.0f};
    std::atomic<float> masterReverbSend{0.0f};
    std::atomic<float> masterReverbSize{0.6f};
    std::atomic<float> masterReverbDecay{0.6f};
    std::atomic<float> masterReverbDamp{0.5f};
    std::atomic<float> masterReverbMode{0.0f};
    std::atomic<float> boothLevel{0.8f};
    std::atomic<float> boothEqLow{0.0f};
    std::atomic<float> boothEqMid{0.0f};
    std::atomic<float> boothEqHigh{0.0f};
    // Master-clock inputs (Phase 6b item 2), published from the control actor.
    std::atomic<int32_t> masterDeck{-1};
    std::atomic<double> masterBpm{0.0};
    std::atomic<double> downbeatPhase{0.0};
};

} // namespace

struct pe_engine {
    double sampleRate;
    int maxFrames;
    int deckCount = 2;
    DeckState decks[PE_MAX_DECKS];
    SamplerSlot sampler[16];
    MicState mic;
    ControlState control;
    CommandQueue queue;
    EventQueue events;
    float previousCrossfader = 0.0f;
    bool crossfaderInitialized = false;
    int beatFXKind = 0;
    int beatFXAssign = 0;
    bool beatFXOn = false;
    bool beatFXTail = false;
    int beatFXTailFrames = 0;
    float beatFXDelay[48000] = {};
    uint32_t beatFXDelayIndex = 0;
    float beatFXBandLP = 0.0f;   // FX-input band-limit filter state (CDJ3000 C4)
    float beatFXBandHP = 0.0f;
    // Real per-sample Beat FX DSP state (CDJ3000 parity C4b).
    float bfxSvfLp = 0.0f, bfxSvfBp = 0.0f;      // TPT state-variable filter
    float bfxLfoPhase = 0.0f;                     // sweep / gate / modulation LFO
    float bfxAp[6] = {};                          // up-to-6-stage allpass phaser state
    float bfxDelay2[48000] = {};                  // ping-pong / multi-tap 2nd line
    uint32_t bfxDelay2Index = 0;
    int64_t bfxSampleClock = 0;                   // monotonic per-processBeatFX sample counter
    int64_t bfxRollAnchor = -1;                   // roll capture start (clock units), -1 = re-latch
    int bfxRollLen = 0;
    float bfxRollBuf[48000] = {};                 // dedicated roll capture buffer
    float bfxSpiralPhase = 0.0f;                  // fractional read offset for pitch kinds
    float bfxBrakeRate = 1.0f;                    // vinyl-brake read rate (1 -> 0)
    float bfxBrakeOffset = 0.0f;                  // vinyl-brake read-behind, in samples
    float bfxLowCutState = 0.0f;                  // low-cut-echo feedback high-pass state
    // Compact Schroeder reverb for the Reverb / Shimmer kinds (sized for 96 kHz).
    static constexpr int kBfxCombLen = 4800;
    static constexpr int kBfxApLen = 1600;
    float bfxComb[4][kBfxCombLen] = {};
    uint32_t bfxCombIdx[4] = {};
    float bfxCombLp[4] = {};
    float bfxAllpassBuf[2][kBfxApLen] = {};
    uint32_t bfxApIdx[2] = {};
    float limiterGain = 1.0f;
    float samplerMasterGain = 0.8f;   // CDJ3000: was a hardcoded 0.8 in the mix loop
    // CParsoDSP kernels — the shared, unit-tested DSP (docs/phase6-parity.md C1).
    // Owned by the engine: created in pe_create, freed in pe_destroy. All are
    // allocation-free once constructed, so the render path stays RT-safe.
    pd_eq3* deckEq[PE_MAX_DECKS] = {nullptr, nullptr, nullptr, nullptr};
    pd_filter* deckFilter[PE_MAX_DECKS] = {nullptr, nullptr, nullptr, nullptr};
    pd_limiter* masterLimiter = nullptr;
    pd_eq3* masterEq = nullptr;   // master isolator (CDJ3000 parity C3)
    pd_eq3* boothEq = nullptr;    // booth-output EQ (CDJ3000 parity C3)
    pd_eq3* micEq = nullptr;      // 2-band mic EQ (CDJ3000 parity C5)
    pd_fdnverb* masterReverb = nullptr;  // master reverb send (CDJ3000 parity C7)
    pd_conv* masterConv = nullptr;       // master convolution reverb (CDJ3000 parity C7c)
    float talkoverGain = 1.0f;    // smoothed music-duck under talkover
    float micBlock[512] = {};     // per-block EQ'd mono mic, filled in the mic pre-pass
    int micBlockFrames = 0;
    // Insert seam (CDJ3000 parity C3). fn cleared first / set last so the RT
    // side never calls a live fn with a stale ctx.
    std::atomic<pe_insert_fn> insertFn[PE_INSERT_COUNT]{};
    std::atomic<void*> insertCtx[PE_INSERT_COUNT]{};
    // Snapshot of the last rendered master block, for pe_render_booth.
    static constexpr int kBoothCapacity = 8192;
    float boothLeft[kBoothCapacity] = {};
    float boothRight[kBoothCapacity] = {};
    int boothFrames = 0;
    // Per-deck beat-echo delay lines (Phase 6b item 3). Sized at pe_create for
    // the worst case (8 beats at 40 BPM ≈ 12 s) so the render path never allocs.
    pd_delay* deckEcho[PE_MAX_DECKS] = {nullptr, nullptr, nullptr, nullptr};
    // Per-deck time-pitch (Phase 6b item 2a) — key-lock via signalsmith-stretch.
    pd_timepitch* deckTimePitch[PE_MAX_DECKS] = {nullptr, nullptr, nullptr, nullptr};
    // Telemetry atomics (item 2).
    std::atomic<int64_t> masterFrame{0};
    std::atomic<double> renderLoad{0.0};
    std::atomic<int64_t> starvedFrames{0};
    // Master-bus record tap (item 4). ~4 s stereo ring at the engine rate.
    static constexpr uint32_t kRecordCapacity = 1u << 18;  // 262144 frames
    float recordLeft[kRecordCapacity] = {};
    float recordRight[kRecordCapacity] = {};
    std::atomic<uint32_t> recordWrite{0};
    std::atomic<uint32_t> recordRead{0};
    std::atomic<int32_t> recordActive{0};
    std::atomic<int64_t> recordDropped{0};
};

namespace {

static bool validDeck(const pe_engine* engine, int deck) {
    return engine && deck >= 0 && deck < engine->deckCount;
}

static void clearOutput(float* left, float* right, int frames) {
    if (frames <= 0) return;
    for (int frame = 0; frame < frames; ++frame) {
        if (left) left[frame] = 0.0f;
        if (right) right[frame] = 0.0f;
    }
}

static float sampleAt(const DeckState& deck, int channel, double position) {
    if (deck.frames <= 0 || channel < 0 || channel >= deck.channelCount || !deck.channels[channel]) {
        return 0.0f;
    }
    if (position < 0.0) position = 0.0;
    const double last = static_cast<double>(deck.frames - 1);
    if (position >= last) return deck.channels[channel][deck.frames - 1];

    const int64_t lower = static_cast<int64_t>(position);
    const int64_t upper = lower + 1;
    const float fraction = static_cast<float>(position - static_cast<double>(lower));
    const float a = deck.channels[channel][lower];
    const float b = deck.channels[channel][upper];
    return a + (b - a) * fraction;
}

// EQ (3-band RBJ isolator) and the master brickwall limiter are now the
// CParsoDSP kernels — see render(). The hand-rolled one-pole EQ, the
// approximate soft limiter and their `dbToGain` helper were removed in
// Phase 6b item 0 (docs/phase6-parity.md C1).

static float processColorFX(DeckState& deck, float input, double sampleRate, int deckIndex,
                            const ControlState& control) {
    const float rawAmount = control.colorAmount[deckIndex].load(std::memory_order_relaxed);
    const float amount = std::isfinite(rawAmount) ? std::max(-1.0f, std::min(1.0f, rawAmount)) : 0.0f;
    // Sound Color FX PARAMETER knob (CDJ3000 C4): scales the effect intensity.
    // 0.5 is neutral (×1.0), so a default engine matches pre-C4 output exactly.
    const float param = control.colorParam[deckIndex].load(std::memory_order_relaxed);
    const float wet = std::min(1.0f, std::fabs(amount) * (param / 0.5f));
    const float lowAlpha = 1.0f - std::exp(-2.0f * kPi * 250.0f /
        static_cast<float>(sampleRate));
    const float highAlpha = 1.0f - std::exp(-2.0f * kPi * 1800.0f /
        static_cast<float>(sampleRate));
    deck.colorLowState += lowAlpha * (input - deck.colorLowState);
    deck.colorHighState += highAlpha * (input - deck.colorHighState);
    const uint32_t index = deck.colorDelayIndex;
    const int delaySamples = std::max(1, std::min(23999, static_cast<int>(sampleRate * 0.25)));
    const uint32_t delayedIndex = (index + 24000u - static_cast<uint32_t>(delaySamples)) % 24000u;
    const float delayed = deck.colorDelay[delayedIndex];
    deck.colorDelay[index] = input;
    deck.colorDelayIndex = (index + 1) % 24000u;

    if (wet < 0.0001f) return input;
    const int kind = std::max(0, std::min(6, static_cast<int>(std::lround(
        control.colorKind[deckIndex].load(std::memory_order_relaxed)))));
    switch (kind) {
        case 0: // Filter: negative is low-pass, positive is high-pass.
            return amount < 0.0f ? input * (1.0f - wet) + deck.colorLowState * wet
                                 : input * (1.0f - wet) + (input - deck.colorHighState) * wet;
        case 1: // Space: a short, smooth diffusion.
            return input * (1.0f - wet) + deck.colorLowState * wet;
        case 2: // Dub Echo.
            deck.colorDelay[index] = input + delayed * (0.35f + 0.4f * wet);
            return input * (1.0f - wet) + delayed * wet;
        case 3: // Sweep: emphasize the moving mid band.
            return input * (1.0f - wet) + (deck.colorHighState - deck.colorLowState) * wet * 1.6f;
        case 4: { // Noise: deterministic, bounded texture for RT-safe operation.
            deck.colorNoiseState = deck.colorNoiseState * 1664525u + 1013904223u;
            const float noise = static_cast<float>((deck.colorNoiseState >> 8) & 0x00FFFFFFu) /
                8388607.5f - 1.0f;
            return input + noise * wet * 0.18f;
        }
        case 5: { // Crush.
            const int bits = std::max(4, 12 - static_cast<int>(wet * 8.0f));
            const float steps = static_cast<float>(1 << bits);
            const float crushed = std::round(input * steps) / steps;
            return input * (1.0f - wet) + crushed * wet;
        }
        case 6: // Pitch: short comb-like modulation, keeping the path bounded.
            return input * (1.0f - wet) + delayed * wet;
        default:
            return input;
    }
}

static float sampleAt(const SamplerSlot& slot, int channel, int64_t position) {
    if (slot.frames <= 0 || channel < 0 || channel >= slot.channelCount || !slot.channels[channel]) {
        return 0.0f;
    }
    if (position < 0) position = 0;
    if (position >= slot.frames) position = slot.frames - 1;
    return slot.channels[channel][position];
}

static float sampleAt(const MicState& mic, int channel, double position) {
    if (mic.frames <= 0 || channel < 0 || channel >= mic.channelCount || !mic.channels[channel]) {
        return 0.0f;
    }
    if (position < 0.0) position = 0.0;
    const double last = static_cast<double>(mic.frames - 1);
    if (position >= last) return mic.channels[channel][mic.frames - 1];
    const int64_t lower = static_cast<int64_t>(position);
    const int64_t upper = lower + 1;
    const float fraction = static_cast<float>(position - static_cast<double>(lower));
    return mic.channels[channel][lower] +
        (mic.channels[channel][upper] - mic.channels[channel][lower]) * fraction;
}

static void pushEvent(pe_engine* engine, pe_event event) {
    const uint32_t write = engine->events.writeIndex.load(std::memory_order_relaxed);
    const uint32_t read = engine->events.readIndex.load(std::memory_order_acquire);
    if (write - read >= kEventCapacity) return;
    engine->events.events[write % kEventCapacity] = event;
    engine->events.writeIndex.store(write + 1, std::memory_order_release);
}

static void pushStateEvent(pe_engine* engine, int deckIndex) {
    const DeckState& deck = engine->decks[deckIndex];
    pushEvent(engine, pe_event{
        PE_EVT_STATE,
        deckIndex,
        static_cast<int64_t>(deck.position),
        deck.playing ? 1.0f : 0.0f,
        0.0f
    });
}

static void pushPlayheadEvent(pe_engine* engine, int deckIndex) {
    const DeckState& deck = engine->decks[deckIndex];
    pushEvent(engine, pe_event{
        PE_EVT_PLAYHEAD,
        deckIndex,
        static_cast<int64_t>(deck.position),
        deck.playing ? 1.0f : 0.0f,
        static_cast<float>(deck.shadowPosition)
    });
}

static void pushPeakEvent(pe_engine* engine, int deckIndex, float peak) {
    pushEvent(engine, pe_event{PE_EVT_PEAK, deckIndex, 0, peak, 0.0f});
}

static void setLoop(DeckState& deck, double start, double end) {
    if (deck.frames <= 0) return;
    if (start > end) {
        const double temporary = start;
        start = end;
        end = temporary;
    }
    start = start < 0.0 ? 0.0 : start;
    end = end > static_cast<double>(deck.frames) ? static_cast<double>(deck.frames) : end;
    if (end <= start) return;
    deck.loopStart = start;
    deck.loopEnd = end;
    deck.loopAvailable = true;
    deck.loopActive = true;
}

// Schedule a jump to `target` on the next grid line (CDJ3000 parity C1b).
// `grainBeats` is the quantize grain; the deck's beatPhase / effectiveBpm come
// from the control side and (for a synced deck) are locked to the master grid.
// Falls back to an immediate jump when there is no usable tempo.
static void scheduleQuantizedJump(pe_engine* engine, DeckState& deck, int deckIndex,
                                  double target, double grainBeats) {
    if (grainBeats <= 0.0) grainBeats = 1.0;
    if (deck.effectiveBpm <= 0.0 || deck.sampleRate <= 0.0) {
        deck.position = target;
        deck.shadowPosition = target;
        deck.pendingJump = false;
        pushPlayheadEvent(engine, deckIndex);
        return;
    }
    const double beatFrames = deck.sampleRate * 60.0 / deck.effectiveBpm;
    const double grainFrames = beatFrames * grainBeats;
    // Phase within the current grain: reuse the beat phase, scaled.
    const double phaseInGrain = std::fmod(deck.beatPhase / grainBeats, 1.0);
    double wait = (1.0 - phaseInGrain) * grainFrames;
    if (wait < 1.0) wait += grainFrames;   // never fire "now"; next line
    deck.pendingJump = true;
    deck.pendingJumpTarget = target;
    deck.pendingJumpCountdown = wait;
}

static void applyCommand(pe_engine* engine, const pe_command& command) {
    if (command.deck == -1) {
        if (command.type == PE_CMD_SAMPLER_TRIGGER && command.i0 >= 0 && command.i0 < 16) {
            SamplerSlot& slot = engine->sampler[command.i0];
            if (slot.frames > 0) {
                slot.position = 0;
                slot.playing = true;
            }
        } else if (command.type == PE_CMD_SAMPLER_STOP && command.i0 >= 0 && command.i0 < 16) {
            engine->sampler[command.i0].playing = false;
        } else if (command.type == PE_CMD_SAMPLER_CONFIG) {
            if (command.i0 < 0) {
                if (std::isfinite(command.f0)) engine->samplerMasterGain = std::max(0.0f, command.f0);
            } else if (command.i0 < 16) {
                SamplerSlot& slot = engine->sampler[command.i0];
                slot.mode = std::max(0, std::min(2, command.i1));
                if (std::isfinite(command.f0)) slot.gain = std::max(0.0f, command.f0);
            }
        } else if (command.type == PE_CMD_BEATFX_KIND && std::isfinite(command.f0)) {
            engine->beatFXKind = std::max(0, std::min(19, static_cast<int>(std::lround(command.f0))));
        } else if (command.type == PE_CMD_BEATFX_ONOFF) {
            engine->beatFXOn = command.f0 > 0.5f;
            if (engine->beatFXOn) engine->beatFXTail = false;
            if (engine->beatFXOn) { engine->bfxRollAnchor = -1; engine->bfxLfoPhase = 0.0f; engine->bfxBrakeRate = 1.0f; engine->bfxBrakeOffset = 0.0f; }
        } else if (command.type == PE_CMD_BEATFX_RELEASE) {
            engine->beatFXOn = false;
            engine->beatFXTail = true;
            engine->beatFXTailFrames = static_cast<int>(engine->sampleRate * 2.0);
        }
        return;
    }
    if (!validDeck(engine, command.deck)) return;
    DeckState& deck = engine->decks[command.deck];
    switch (command.type) {
        case PE_CMD_PLAY:
            deck.playing = true;
            deck.motorTarget = 1.0f;
            if (deck.spinupSeconds <= 0.0001f) deck.motorLevel = 1.0f;  // instant start
            deck.shadowPosition = deck.position;
            pushStateEvent(engine, command.deck);
            break;
        case PE_CMD_PAUSE:
            deck.playing = false;
            deck.motorTarget = 0.0f;
            if (deck.brakeSeconds <= 0.0001f) deck.motorLevel = 0.0f;   // instant stop
            pushStateEvent(engine, command.deck);
            break;
        case PE_CMD_VINYL_SPEED:
            if (std::isfinite(command.f0)) deck.brakeSeconds = std::max(0.0f, std::min(10.0f, command.f0));
            if (std::isfinite(command.f1)) deck.spinupSeconds = std::max(0.0f, std::min(10.0f, command.f1));
            break;
        case PE_CMD_SET_CUE:
            if (deck.frames > 0) {
                const double target = command.i2 == 1
                    ? static_cast<double>(command.i1)
                    : (std::isfinite(command.f0)
                        ? static_cast<double>(command.f0) * deck.sampleRate
                        : deck.position);
                deck.cueFrame = static_cast<int64_t>(std::max(
                    0.0, std::min(static_cast<double>(deck.frames), target)
                ));
                deck.cueSet = true;
            }
            break;
        case PE_CMD_JUMP_CUE:
            if (deck.cueSet) {
                if (command.i2 == 2) {
                    scheduleQuantizedJump(engine, deck, command.deck,
                                          static_cast<double>(deck.cueFrame),
                                          static_cast<double>(command.f1));
                } else {
                    deck.position = static_cast<double>(deck.cueFrame);
                    deck.shadowPosition = deck.position;
                    deck.pendingJump = false;
                    pushPlayheadEvent(engine, command.deck);
                }
            }
            break;
        case PE_CMD_SET_MASTER:
        case PE_CMD_SET_KEYLOCK:
        case PE_CMD_COLORFX_KIND:
        case PE_CMD_SAMPLER_TRIGGER:
        case PE_CMD_SAMPLER_STOP:
        case PE_CMD_SAMPLER_CONFIG:
        case PE_CMD_LOAD:
            // Deck-agnostic or redundant here: the sampler / master / key-lock /
            // color-kind state is owned by the deck == -1 branch or by the
            // control-atom path in pe_set_control. Ignoring them for a specific
            // deck is deterministic and non-blocking.
            break;
        case PE_CMD_BEATFX_KIND:
            if (std::isfinite(command.f0)) {
                engine->beatFXKind = std::max(0, std::min(19, static_cast<int>(std::lround(command.f0))));
            }
            break;
        case PE_CMD_BEATFX_ONOFF:
            engine->beatFXOn = command.f0 > 0.5f;
            if (engine->beatFXOn) engine->beatFXTail = false;
            if (engine->beatFXOn) { engine->bfxRollAnchor = -1; engine->bfxLfoPhase = 0.0f; engine->bfxBrakeRate = 1.0f; engine->bfxBrakeOffset = 0.0f; }
            break;
        case PE_CMD_BEATFX_RELEASE:
            engine->beatFXOn = false;
            engine->beatFXTail = true;
            engine->beatFXTailFrames = static_cast<int>(engine->sampleRate * 2.0);
            break;
        case PE_CMD_JOG_TOUCH:
            // i0 is vinyl mode. A vinyl touch pauses transport while preserving
            // the pre-touch play state in i1 for the matching release command.
            if (command.i0 != 0 && deck.playing) {
                deck.playing = false;
                deck.motorTarget = 0.0f;   // brake to a stop (Vinyl Speed Adjust)
                if (deck.brakeSeconds <= 0.0001f) deck.motorLevel = 0.0f;
                pushStateEvent(engine, command.deck);
            }
            break;
        case PE_CMD_JOG_MOVE:
            if (std::isfinite(command.f0) && deck.frames > 0) {
                deck.position += static_cast<double>(command.f0);
                if (deck.position < 0.0) deck.position = 0.0;
                if (deck.position > static_cast<double>(deck.frames)) {
                    deck.position = static_cast<double>(deck.frames);
                }
                deck.shadowPosition = deck.position;
                pushPlayheadEvent(engine, command.deck);
            }
            break;
        case PE_CMD_JOG_RELEASE:
            if (command.i0 != 0 && command.i1 != 0 && deck.position < static_cast<double>(deck.frames)) {
                deck.playing = true;
                deck.motorTarget = 1.0f;   // spin back up (Vinyl Speed Adjust)
                if (deck.spinupSeconds <= 0.0001f) deck.motorLevel = 1.0f;
                pushStateEvent(engine, command.deck);
            }
            break;
        case PE_CMD_SEEK:
            if (deck.frames > 0) {
                const bool integerMode = command.i2 == 1;
                const double raw = integerMode ? static_cast<double>(command.i1)
                                               : static_cast<double>(command.f0);
                if (integerMode || std::isfinite(command.f0)) {
                    const double target = std::max(0.0, std::min(
                        static_cast<double>(deck.frames), raw));
                    deck.position = target;
                    deck.shadowPosition = target;
                    deck.pendingJump = false;   // an explicit seek cancels a pending quantized jump
                    if (engine->deckTimePitch[command.deck]) {
                        pd_tp_reset(engine->deckTimePitch[command.deck]);
                    }
                    pushPlayheadEvent(engine, command.deck);
                }
            }
            break;
        case PE_CMD_UNSYNC:
            deck.synced = false;
            break;
        case PE_CMD_STEM_ARM:
            deck.stemsArmed = command.i0 != 0;
            break;
        case PE_CMD_STEM_GAIN:
            if (command.i0 >= 0 && command.i0 < 4 && std::isfinite(command.f0)) {
                deck.stems[command.i0].gain = std::max(0.0f, std::min(4.0f, command.f0));
            }
            break;
        case PE_CMD_STEM_MUTE:
            if (command.i0 >= 0 && command.i0 < 4) deck.stems[command.i0].muted = command.i1 != 0;
            break;
        case PE_CMD_STEM_SOLO:
            if (command.i0 >= 0 && command.i0 < 4) deck.stems[command.i0].soloed = command.i1 != 0;
            break;
        case PE_CMD_ECHO_SET:
            deck.echoOn = command.i0 != 0;
            if (deck.echoOn) {
                deck.echoTail = false;
            } else if (command.i2 != 0) {  // release: keep the tail decaying
                deck.echoTail = true;
                deck.echoTailFrames = static_cast<int>(engine->sampleRate * 3.0);
            }
            if (std::isfinite(command.f0) && command.f0 > 0.0f) {
                deck.echoBeats = std::max(0.0625f, std::min(8.0f, command.f0));
            }
            if (std::isfinite(command.f1)) deck.echoDepth = std::max(0.0f, std::min(1.0f, command.f1));
            deck.echoFeedback = std::max(0.0f, std::min(0.95f, static_cast<float>(command.i1) / 1000.0f));
            break;
        case PE_CMD_BEATJUMP:
            if (std::isfinite(command.f0)) {
                double dest = deck.position + static_cast<double>(command.f0) * deck.sampleRate;
                if (dest < 0.0) dest = 0.0;
                if (dest >= static_cast<double>(deck.frames)) {
                    dest = static_cast<double>(deck.frames > 0 ? deck.frames - 1 : 0);
                }
                if (command.i2 == 2) {   // grid-quantized (C1b), grain = f1 beats
                    scheduleQuantizedJump(engine, deck, command.deck, dest,
                                          static_cast<double>(command.f1));
                } else {
                    deck.position = dest;
                    deck.shadowPosition = dest;
                    deck.pendingJump = false;
                    pushPlayheadEvent(engine, command.deck);
                }
            }
            break;
        case PE_CMD_SYNC:
            // The control actor computes the source position that matches the
            // master beat phase. Applying it here keeps seeking on the RT side
            // and makes pe_step and pe_render use identical transport state.
            if (std::isfinite(command.f0) && command.f0 >= 0.0f && deck.frames > 0) {
                const double target = static_cast<double>(command.f0);
                deck.position = target < static_cast<double>(deck.frames)
                    ? target : static_cast<double>(deck.frames - 1);
                deck.shadowPosition = deck.position;
            }
            pushPlayheadEvent(engine, command.deck);
            break;
        case PE_CMD_SET_SLIP:
            deck.slip = command.f0 > 0.5f;
            if (deck.slip) deck.shadowPosition = deck.position;
            break;
        case PE_CMD_SET_REVERSE: {
            const bool wantReverse = command.i0 != 0;
            if (deck.reverse && !wantReverse && deck.slip) {
                // Slip Reverse release: jump forward to the shadow playhead.
                deck.position = deck.shadowPosition;
                if (deck.position >= static_cast<double>(deck.frames)) {
                    deck.position = static_cast<double>(deck.frames);
                    deck.playing = false;
                }
                pushPlayheadEvent(engine, command.deck);
            }
            if (wantReverse && deck.slip) deck.shadowPosition = deck.position;
            deck.reverse = wantReverse;
            break;
        }
        case PE_CMD_LOOP_IN:
            deck.loopIn = std::isfinite(command.f0)
                ? static_cast<double>(command.f0) * deck.sampleRate
                : deck.position;
            deck.loopIn = std::max(0.0, std::min(static_cast<double>(deck.frames), deck.loopIn));
            deck.loopInSet = true;
            break;
        case PE_CMD_LOOP_OUT:
            if (deck.loopInSet) {
                const double loopOut = std::isfinite(command.f0)
                    ? static_cast<double>(command.f0) * deck.sampleRate
                    : deck.position;
                setLoop(deck, deck.loopIn, loopOut);
                deck.loopInSet = false;
            }
            break;
        case PE_CMD_RELOOP_EXIT:
            if (deck.loopActive) {
                deck.loopActive = false;
                if (deck.slip) {
                    deck.position = deck.shadowPosition;
                    if (deck.position >= static_cast<double>(deck.frames)) {
                        deck.position = static_cast<double>(deck.frames);
                        deck.playing = false;
                    }
                    pushPlayheadEvent(engine, command.deck);
                }
            } else if (deck.loopAvailable) {
                deck.loopActive = true;
            }
            break;
        case PE_CMD_BEATLOOP:
            if (command.f0 > 0.0f) {
                double length = static_cast<double>(command.f0) * deck.sampleRate;
                double start = std::isfinite(command.f1)
                    ? static_cast<double>(command.f1) * deck.sampleRate
                    : deck.position;
                start = std::max(0.0, std::min(static_cast<double>(deck.frames), start));
                if (length > static_cast<double>(deck.frames)) length = static_cast<double>(deck.frames);
                if (start + length > static_cast<double>(deck.frames)) {
                    start = static_cast<double>(deck.frames) - length;
                }
                setLoop(deck, start, start + length);
            }
            break;
        case PE_CMD_LOOP_SCALE:
            if (deck.loopAvailable && command.f0 > 0.0f) {
                const double center = 0.5 * (deck.loopStart + deck.loopEnd);
                const double halfLength = 0.5 * (deck.loopEnd - deck.loopStart) * static_cast<double>(command.f0);
                setLoop(deck, center - halfLength, center + halfLength);
            }
            break;
        case PE_CMD_LOOP_MOVE:
            if (deck.loopAvailable) {
                const double length = deck.loopEnd - deck.loopStart;
                double start = deck.loopStart + static_cast<double>(command.f0) * deck.sampleRate;
                if (start < 0.0) start = 0.0;
                if (start + length > static_cast<double>(deck.frames)) {
                    start = static_cast<double>(deck.frames) - length;
                }
                setLoop(deck, start, start + length);
            }
            break;
        case PE_CMD_SET_LOOP:
            if (command.f0 == -1.0f) {
                // Integer-sample mode: i1 = start, i2 = end, i0 = active.
                setLoop(deck, static_cast<double>(command.i1), static_cast<double>(command.i2));
                deck.loopActive = deck.loopAvailable && command.i0 != 0;
            } else if (std::isfinite(command.f0) && std::isfinite(command.f1) && deck.sampleRate > 0.0) {
                const double start = command.f0 * deck.sampleRate;
                const double end = command.f1 * deck.sampleRate;
                setLoop(deck, start, end);
                deck.loopActive = command.i0 != 0;
            }
            break;
        case PE_CMD_SET_LOOP_ACTIVE:
            if (deck.loopAvailable) deck.loopActive = command.f0 > 0.5f;
            break;
        case PE_CMD_HOTCUE_SET:
            if (command.i0 >= 0 && command.i0 < 8) {
                const int slot = command.i0;
                const double target = command.i2 == 1
                    ? static_cast<double>(command.i1)
                    : (std::isfinite(command.f0)
                        ? static_cast<double>(command.f0) * deck.sampleRate
                        : deck.position);
                deck.hotCueFrames[slot] = static_cast<int64_t>(std::max(
                    0.0, std::min(static_cast<double>(deck.frames), target)
                ));
                deck.hotCueSet[slot] = true;
            }
            break;
        case PE_CMD_HOTCUE_JUMP:
            if (command.i0 >= 0 && command.i0 < 8 && deck.hotCueSet[command.i0]) {
                // Fade-in cue (CDJ3000 parity C6): f0 > 0 ramps the deck up from
                // silence over f0 seconds.
                if (std::isfinite(command.f0) && command.f0 > 0.0f) {
                    deck.cueFadeGain = 0.0f;
                    deck.cueFadeRate = 1.0f / (command.f0 * static_cast<float>(engine->sampleRate));
                } else {
                    deck.cueFadeGain = 1.0f;
                    deck.cueFadeRate = 0.0f;
                }
                const double target = static_cast<double>(deck.hotCueFrames[command.i0]);
                if (command.i2 == 2) {   // grid-quantized jump (C1b), grain = f1 beats
                    scheduleQuantizedJump(engine, deck, command.deck, target,
                                          static_cast<double>(command.f1));
                } else {
                    deck.position = target;
                    deck.shadowPosition = target;
                    deck.pendingJump = false;
                    pushPlayheadEvent(engine, command.deck);
                }
            }
            break;
        case PE_CMD_HOTCUE_DELETE:
            if (command.i0 >= 0 && command.i0 < 8) {
                deck.hotCueSet[command.i0] = false;
            }
            break;
    }
}

static void drainCommands(pe_engine* engine) {
    uint32_t read = engine->queue.readIndex.load(std::memory_order_relaxed);
    const uint32_t write = engine->queue.writeIndex.load(std::memory_order_acquire);
    while (read != write) {
        applyCommand(engine, engine->queue.commands[read % kCommandCapacity]);
        ++read;
    }
    engine->queue.readIndex.store(read, std::memory_order_release);
}

static void crossfadeGains(float crossfader, float curve, float& gainA, float& gainB) {
    const float x = crossfader < -1.0f ? -1.0f : (crossfader > 1.0f ? 1.0f : crossfader);
    const float normalized = (x + 1.0f) * 0.5f;
    if (curve < 0.25f) {
        const float angle = normalized * kHalfPi;
        gainA = std::cos(angle);
        gainB = std::sin(angle);
    } else if (curve < 0.75f) {
        gainA = 1.0f - normalized;
        gainB = normalized;
    } else {
        // "Sharp" must be steep, not a literal zero-width step: gains are
        // computed once per render() call (block-rate, like every other
        // mixer parameter here), so a true Heaviside step here means the
        // output jump-cuts full-amplitude between two unrelated songs at
        // whatever sample lands on the boundary -- an audible click/gap on
        // real material, found via the Phase 6d A-B listening pass (see
        // current_status.md "Phase 6"). Real hardware "sharp" crossfader
        // curves are steep, not instantaneous, either. A narrow linear ramp
        // around centre keeps the cut feel while staying continuous.
        constexpr float halfWidth = 0.02f; // ~1% of full throw each side of centre
        if (normalized < 0.5f - halfWidth) {
            gainA = 1.0f;
            gainB = 0.0f;
        } else if (normalized > 0.5f + halfWidth) {
            gainA = 0.0f;
            gainB = 1.0f;
        } else {
            const float t = (normalized - (0.5f - halfWidth)) / (2.0f * halfWidth);
            gainA = 1.0f - t;
            gainB = t;
        }
    }
}

// --- Beat FX per-sample DSP primitives (CDJ3000 parity C4b) ---

// One TPT (topology-preserving transform) state-variable filter step. Returns
// the low-pass output; band-pass is kept in state for resonant sweeps.
static float bfxSvfLowpass(pe_engine* e, float in, float cutoffHz, float res) {
    const float sr = static_cast<float>(e->sampleRate);
    const float g = std::tan(kPi * std::min(cutoffHz, sr * 0.45f) / sr);
    const float k = 2.0f - 1.9f * std::min(1.0f, std::max(0.0f, res));   // damping
    const float a1 = 1.0f / (1.0f + g * (g + k));
    const float a2 = g * a1;
    const float v1 = a1 * e->bfxSvfBp + a2 * (in - e->bfxSvfLp);
    const float v2 = e->bfxSvfLp + g * v1;
    e->bfxSvfBp = 2.0f * v1 - e->bfxSvfBp;
    e->bfxSvfLp = 2.0f * v2 - e->bfxSvfLp;
    if (!std::isfinite(e->bfxSvfLp)) { e->bfxSvfLp = e->bfxSvfBp = 0.0f; }
    return e->bfxSvfLp;
}

// N-stage allpass phaser with a shared, LFO-swept coefficient + feedback.
static float bfxPhaser(pe_engine* e, float in, int stages, float coef, float feedback) {
    float x = in + e->bfxAp[std::min(stages, 6) - 1] * feedback;
    for (int s = 0; s < std::min(stages, 6); ++s) {
        const float y = -coef * x + e->bfxAp[s];
        e->bfxAp[s] = x + coef * y;
        x = y;
    }
    return x;
}

// Compact Schroeder reverb (4 damped combs in parallel -> 2 allpass in series).
static float bfxSchroeder(pe_engine* e, float in, float size, float damp, float octaveMix) {
    static constexpr int combLen[4] = {1687, 1601, 2053, 2251};
    static constexpr int apLen[2]   = {389, 307};
    const double scale = e->sampleRate / 48000.0;
    const float fb = 0.72f + 0.26f * std::min(1.0f, std::max(0.0f, size));
    const float dc = 0.15f + 0.8f * std::min(1.0f, std::max(0.0f, damp));
    const int CL = pe_engine::kBfxCombLen;
    const int AL = pe_engine::kBfxApLen;
    float combSum = 0.0f;
    for (int c = 0; c < 4; ++c) {
        int len = std::max(1, std::min(CL - 1, static_cast<int>(combLen[c] * scale)));
        uint32_t& idx = e->bfxCombIdx[c];
        const uint32_t readIdx = (idx + static_cast<uint32_t>(CL) - static_cast<uint32_t>(len)) % static_cast<uint32_t>(CL);
        float out = e->bfxComb[c][readIdx];
        if (octaveMix > 0.0f) {
            const uint32_t up = (readIdx + static_cast<uint32_t>(len / 2)) % static_cast<uint32_t>(CL);
            out += e->bfxComb[c][up] * octaveMix;
        }
        e->bfxCombLp[c] += dc * (out - e->bfxCombLp[c]);
        e->bfxComb[c][idx] = in + e->bfxCombLp[c] * fb;
        idx = (idx + 1) % static_cast<uint32_t>(CL);
        combSum += out;
    }
    float x = combSum * 0.25f;
    for (int p = 0; p < 2; ++p) {
        int len = std::max(1, std::min(AL - 1, static_cast<int>(apLen[p] * scale)));
        uint32_t& idx = e->bfxApIdx[p];
        const uint32_t readIdx = (idx + static_cast<uint32_t>(AL) - static_cast<uint32_t>(len)) % static_cast<uint32_t>(AL);
        const float buffered = e->bfxAllpassBuf[p][readIdx];
        const float y = -0.5f * x + buffered;
        e->bfxAllpassBuf[p][idx] = x + 0.5f * y;
        idx = (idx + 1) % static_cast<uint32_t>(AL);
        x = y;
    }
    return std::isfinite(x) ? x : 0.0f;
}

static float processBeatFX(pe_engine* engine, float input) {
    const bool active = engine->beatFXOn || engine->beatFXTail;
    if (!active) return input;

    // FX-input band limit (CDJ3000 C4): 0 all, 1 low, 2 mid, 3 high. One-pole
    // shelves at ~250 Hz / ~2 kHz on the FX send only — the dry path is untouched.
    const int band = std::max(0, std::min(3, static_cast<int>(std::lround(
        engine->control.beatFXBand.load(std::memory_order_relaxed)))));
    float fxIn = input;
    if (band != 0) {
        const float sr = static_cast<float>(engine->sampleRate);
        const float aLo = 1.0f - std::exp(-2.0f * kPi * 250.0f / sr);
        const float aHi = 1.0f - std::exp(-2.0f * kPi * 2000.0f / sr);
        engine->beatFXBandLP += aLo * (input - engine->beatFXBandLP);
        engine->beatFXBandHP += aHi * (input - engine->beatFXBandHP);
        if (band == 1) fxIn = engine->beatFXBandLP;                       // low
        else if (band == 3) fxIn = input - engine->beatFXBandHP;         // high
        else fxIn = engine->beatFXBandHP - engine->beatFXBandLP;         // mid
    }

    const float sr = static_cast<float>(engine->sampleRate);
    const float rawBeats = engine->control.beatFXBeats.load(std::memory_order_relaxed);
    float beats = std::isfinite(rawBeats) ? std::max(0.0625f, std::min(8.0f, rawBeats)) : 0.5f;
    // X-Pad (CDJ3000 C4): sweeps the beat division exponentially 1/16..4.
    const float xpad = engine->control.beatFXXpad.load(std::memory_order_relaxed);
    if (xpad >= 0.0f) beats = std::pow(2.0f, -4.0f + std::min(1.0f, xpad) * 6.0f);

    const int kind = engine->beatFXKind;
    const double bpm = engine->control.masterBpm.load(std::memory_order_relaxed) > 20.0
        ? engine->control.masterBpm.load(std::memory_order_relaxed) : 120.0;
    const float beatFrames = static_cast<float>(sr * 60.0 / bpm);
    // LFO advance: one cycle per `beats` (triplet kinds run 1.5x faster).
    const bool triplet = (kind == 16 || kind == 17);
    const float lfoInc = (triplet ? 1.5f : 1.0f) / std::max(1.0f, beatFrames * beats);
    engine->bfxLfoPhase += lfoInc;
    if (engine->bfxLfoPhase >= 1.0f) engine->bfxLfoPhase -= 1.0f;
    const float lfo = engine->bfxLfoPhase;
    const float lfoSin = 0.5f + 0.5f * std::sin(6.2831853f * lfo);

    int delaySamples = std::max(1, std::min(47999, static_cast<int>(sr * beats * 0.5f)));
    if (kind == 5 || kind == 6 || kind == 18) delaySamples = std::max(1, static_cast<int>(sr * 0.004f));
    if (triplet) delaySamples = std::max(1, delaySamples * 2 / 3);

    const uint32_t index = engine->beatFXDelayIndex;
    const uint32_t delayedIndex = (index + 48000u - static_cast<uint32_t>(delaySamples)) % 48000u;
    const float delayed = engine->beatFXDelay[delayedIndex];
    const float rawDepth = engine->control.beatFXDepth.load(std::memory_order_relaxed);
    const float depth = std::isfinite(rawDepth) ? std::max(0.0f, std::min(1.0f, rawDepth)) : 0.5f;

    float wet;
    float feed = fxIn;          // what gets written into the primary delay line
    float feedback = 0.55f;

    switch (kind) {
        case 2:   // Reverb — compact Schroeder.
        case 19: {// Shimmer — Schroeder + octave-up feedback.
            wet = bfxSchroeder(engine, fxIn, 0.6f + 0.35f * depth, 0.4f,
                               kind == 19 ? 0.5f : 0.0f);
            feed = 0.0f; feedback = 0.0f;   // reverb keeps its own buffers
            break;
        }
        case 5: {  // Flanger — LFO-modulated 1..5 ms delay + feedback.
            const int mod = static_cast<int>(sr * (0.001f + 0.004f * lfoSin));
            const uint32_t mi = (index + 48000u - static_cast<uint32_t>(std::max(1, mod))) % 48000u;
            wet = engine->beatFXDelay[mi];
            feed = fxIn + wet * 0.6f; feedback = 0.0f;
            break;
        }
        case 6:    // Phaser — 4-stage allpass, LFO-swept.
            wet = bfxPhaser(engine, fxIn, 4, -0.2f + 0.7f * lfoSin, 0.5f);
            feed = 0.0f; feedback = 0.0f;
            break;
        case 18:   // Enigma — deeper 6-stage phaser, more resonance + feedback.
            wet = bfxPhaser(engine, fxIn, 6, -0.1f + 0.85f * lfoSin, 0.72f);
            feed = 0.0f; feedback = 0.0f;
            break;
        case 7: {  // Trans — hard amplitude gate (50% duty square at the beat rate).
            const float gate = lfo < 0.5f ? 1.0f : 0.06f;
            wet = fxIn * gate; feed = 0.0f; feedback = 0.0f;
            break;
        }
        case 8:    // Roll
        case 17: { // Triplet Roll — capture one division into a dedicated buffer,
                   // then loop it. Fresh audio passes through during capture.
            const int rollLen = std::max(1, std::min(47999, delaySamples));
            if (engine->bfxRollAnchor < 0 || engine->bfxRollLen != rollLen) {
                engine->bfxRollAnchor = engine->bfxSampleClock;
                engine->bfxRollLen = rollLen;
            }
            const int64_t age = engine->bfxSampleClock - engine->bfxRollAnchor;
            if (age < rollLen) {
                engine->bfxRollBuf[age] = fxIn;   // still capturing
                wet = fxIn;
            } else {
                wet = engine->bfxRollBuf[age % rollLen];   // loop the captured bar
            }
            feed = fxIn; feedback = 0.0f;
            break;
        }
        case 16: { // Triplet Filter — resonant LP swept by the triplet LFO.
            const float cutoff = 150.0f * std::pow(60.0f, lfoSin);   // ~150 Hz..9 kHz
            wet = bfxSvfLowpass(engine, fxIn, cutoff, 0.85f);
            feed = 0.0f; feedback = 0.0f;
            break;
        }
        case 9:    // Spiral
        case 10:   // Pitch
        case 13:   // Helix
        case 15: { // Mobius — pitched feedback via a drifting fractional read.
            const float rate = (kind == 10) ? 1.06f
                             : (kind == 15) ? (1.0f + 0.04f * std::sin(6.2831853f * lfo))
                             : 1.03f;   // spiral / helix rise
            engine->bfxSpiralPhase += (rate - 1.0f);
            if (engine->bfxSpiralPhase > static_cast<float>(delaySamples)) engine->bfxSpiralPhase -= static_cast<float>(delaySamples);
            const float readPos = static_cast<float>(delaySamples) + engine->bfxSpiralPhase;
            const int r0 = static_cast<int>(readPos);
            const float frac = readPos - static_cast<float>(r0);
            const uint32_t i0 = (index + 96000u - static_cast<uint32_t>(r0)) % 48000u;
            const uint32_t i1 = (i0 + 47999u) % 48000u;
            wet = engine->beatFXDelay[i0] * (1.0f - frac) + engine->beatFXDelay[i1] * frac;
            feed = fxIn + wet * (kind == 13 ? 0.85f : 0.7f);  // helix sustains
            feedback = 0.0f;
            break;
        }
        case 14: { // Ping Pong — two cross-fed delay lines (folded to mono).
            const uint32_t j = engine->bfxDelay2Index;
            const uint32_t d2 = static_cast<uint32_t>(std::max(1, delaySamples * 3 / 2));
            const float tapA = delayed;
            const float tapB = engine->bfxDelay2[(j + 48000u - d2) % 48000u];
            engine->beatFXDelay[index] = fxIn + tapB * 0.62f;
            engine->bfxDelay2[j] = tapA * 0.62f;
            engine->bfxDelay2Index = (j + 1) % 48000u;
            engine->beatFXDelayIndex = (index + 1) % 48000u;
            const float out = input * (1.0f - depth) + (tapA + tapB) * depth;
            if (engine->beatFXTail) {
                engine->beatFXTailFrames -= 1;
                if (engine->beatFXTailFrames <= 0) engine->beatFXTail = false;
            }
            return out;
        }
        case 12: { // Vinyl Brake — decelerating variable-rate read of the live
            // history buffer: the read rate falls 1 -> 0 over ~0.8 s, so the
            // read point drops behind the write head and the pitch bends down.
            engine->bfxBrakeRate = std::max(0.0f, engine->bfxBrakeRate - 1.0f / (sr * 0.8f));
            engine->bfxBrakeOffset = std::min(46000.0f,
                engine->bfxBrakeOffset + (1.0f - engine->bfxBrakeRate));
            const float rp = engine->bfxBrakeOffset;
            const int r0 = static_cast<int>(rp);
            const float frac = rp - static_cast<float>(r0);
            const uint32_t i0 = (index + 96000u - static_cast<uint32_t>(r0 + 1)) % 48000u;
            const uint32_t i1 = (i0 + 47999u) % 48000u;
            wet = (engine->beatFXDelay[i0] * (1.0f - frac) + engine->beatFXDelay[i1] * frac)
                  * engine->bfxBrakeRate;
            feed = fxIn; feedback = 0.0f;
            break;
        }
        case 11:   // Low-Cut Echo — echo whose feedback path is high-passed
                   // (~120 Hz), so repeats thin out instead of building mud.
            wet = delayed;
            engine->bfxLowCutState += (1.0f - std::exp(-2.0f * kPi * 120.0f / sr))
                                      * (delayed - engine->bfxLowCutState);
            feed = fxIn + (delayed - engine->bfxLowCutState) * 0.62f;
            feedback = 0.0f;
            break;
        case 4: {  // Multi-Tap Delay — three taps.
            const uint32_t t2 = (index + 48000u - static_cast<uint32_t>(delaySamples * 2 / 3)) % 48000u;
            const uint32_t t3 = (index + 48000u - static_cast<uint32_t>(delaySamples / 3)) % 48000u;
            wet = delayed + engine->beatFXDelay[t2] * 0.6f + engine->beatFXDelay[t3] * 0.35f;
            feed = fxIn + delayed * 0.45f; feedback = 0.0f;
            break;
        }
        default:   // echo (0), echo out (1), delay (3) — clean feedback delay.
            wet = delayed;
            feed = fxIn; feedback = (kind == 1) ? 0.6f : 0.45f;
            break;
    }

    if (kind != 14) {
        engine->beatFXDelay[index] = feed + wet * feedback;
        engine->beatFXDelayIndex = (index + 1) % 48000u;
    }
    ++engine->bfxSampleClock;
    const float output = input * (1.0f - depth) + wet * depth;
    if (engine->beatFXTail) {
        if (engine->beatFXTailFrames > 0) --engine->beatFXTailFrames;
        if (engine->beatFXTailFrames == 0) engine->beatFXTail = false;
    }
    return std::isfinite(output) ? output : input;
}

// The render pipeline runs in fixed-size blocks so the CParsoDSP kernels
// (block-oriented) get a bounded, stack-resident scratch. 512 frames keeps the
// scratch at 8 KB and matches the engine's typical device period.
constexpr int kRenderBlock = 512;

// App-supplied insert on a bus (CDJ3000 parity C3). RT-thread call; the app
// guarantees the callback is RT-safe. fn is loaded before ctx and cleared
// first by pe_set_insert, so a live fn never sees a stale ctx.
static void applyInsert(pe_engine* engine, int point, float* l, float* r, int frames) {
    pe_insert_fn fn = engine->insertFn[point].load(std::memory_order_acquire);
    if (!fn) return;
    void* ctx = engine->insertCtx[point].load(std::memory_order_relaxed);
    fn(l, r ? r : l, frames, ctx);
}

// One block of the deck→EQ→ColorFX→crossfader→mic/sampler→beatFX→master→limiter
// chain. `frames` is already clamped to kRenderBlock. `deckPeaks`/`masterPeak`
// accumulate across blocks. Transport (position, loops, end-of-track) advances
// here, one source frame per output frame scaled by the deck's tempo ratio.
static void renderChunk(pe_engine* engine, float* left, float* right, int frames,
                        const float* channelGains, float master, float micLevel,
                        float* deckPeaks, float& masterPeak) {
    float dry[PE_MAX_DECKS][kRenderBlock];
    float wet[PE_MAX_DECKS][kRenderBlock];

    // Pass 1 — per deck: raw mono source + transport advance.
    for (int deckIndex = 0; deckIndex < engine->deckCount; ++deckIndex) {
        DeckState& deck = engine->decks[deckIndex];
        const bool anySolo = deck.stemsArmed &&
            (deck.stems[0].soloed || deck.stems[1].soloed ||
             deck.stems[2].soloed || deck.stems[3].soloed);
        // One-pole smoothing coefficient for stem gains: ~10 ms.
        const float stemAlpha = 1.0f - std::exp(-1.0f / (static_cast<float>(engine->sampleRate) * 0.010f));
        // Vinyl Speed Adjust: per-frame linear brake / spin-up rates.
        const float sr = static_cast<float>(engine->sampleRate);
        const float brakeRate = deck.brakeSeconds > 0.0001f ? 1.0f / (deck.brakeSeconds * sr) : 1.0f;
        const float spinRate = deck.spinupSeconds > 0.0001f ? 1.0f / (deck.spinupSeconds * sr) : 1.0f;
        for (int frame = 0; frame < frames; ++frame) {
            // Deferred grid-quantized jump (CDJ3000 parity C1b): fire when the
            // countdown (frames until the next grid line) runs out.
            if (deck.pendingJump) {
                deck.pendingJumpCountdown -= 1.0;
                if (deck.pendingJumpCountdown <= 0.0) {
                    deck.position = deck.pendingJumpTarget;
                    deck.shadowPosition = deck.pendingJumpTarget;
                    deck.pendingJump = false;
                    pushPlayheadEvent(engine, deckIndex);
                }
            }
            // Ease the motor toward its target (0 stopped .. 1 full speed).
            if (deck.motorLevel < deck.motorTarget) {
                deck.motorLevel = std::min(deck.motorTarget, deck.motorLevel + spinRate);
            } else if (deck.motorLevel > deck.motorTarget) {
                deck.motorLevel = std::max(deck.motorTarget, deck.motorLevel - brakeRate);
            }
            const bool coasting = !deck.playing && deck.motorLevel > 0.0001f;
            if ((!deck.playing && !coasting) || deck.frames <= 0 || deck.sampleRate <= 0.0) {
                dry[deckIndex][frame] = 0.0f;
                continue;
            }
            if (deck.stemsArmed) {
                float summed = 0.0f;
                for (int voice = 0; voice < 4; ++voice) {
                    StemVoice& v = deck.stems[voice];
                    const float targetGain = (v.muted || (anySolo && !v.soloed)) ? 0.0f : v.gain;
                    v.smoothedGain += stemAlpha * (targetGain - v.smoothedGain);
                    if (!v.present) continue;
                    const int rc = v.channelCount > 1 ? 1 : 0;
                    // Voices share the deck playhead; clamp to each voice's length.
                    const double pos = std::min(deck.position, static_cast<double>(v.frames - 1));
                    const int64_t lower = static_cast<int64_t>(pos < 0.0 ? 0.0 : pos);
                    const int64_t upper = lower + 1 < v.frames ? lower + 1 : lower;
                    const float frac = static_cast<float>(pos - static_cast<double>(lower));
                    auto lerp = [&](int ch) {
                        return v.channels[ch][lower] + (v.channels[ch][upper] - v.channels[ch][lower]) * frac;
                    };
                    summed += 0.5f * (lerp(0) + lerp(rc)) * v.smoothedGain;
                }
                dry[deckIndex][frame] = summed;
            } else {
                const int rightChannel = deck.channelCount > 1 ? 1 : 0;
                dry[deckIndex][frame] = 0.5f * (
                    sampleAt(deck, 0, deck.position) + sampleAt(deck, rightChannel, deck.position)
                );
            }
            // Fade-in cue ramp (CDJ3000 parity C6).
            if (deck.cueFadeGain < 1.0f) {
                dry[deckIndex][frame] *= deck.cueFadeGain;
                deck.cueFadeGain = std::min(1.0f, deck.cueFadeGain + deck.cueFadeRate);
            }
            const float tempoRatio = engine->control.deckTimeRatio[deckIndex].load(std::memory_order_relaxed);
            const double forwardIncrement = deck.sampleRate / engine->sampleRate *
                (std::isfinite(tempoRatio) && tempoRatio > 0.0f ? tempoRatio : 1.0f);
            // Slip shadow always advances at the forward nominal rate — it is the
            // "where you would be if you hadn't scratched / reversed / braked" playhead.
            if (deck.slip) deck.shadowPosition += forwardIncrement;
            const double motor = static_cast<double>(deck.motorLevel);
            const double positionIncrement = (deck.reverse ? -forwardIncrement : forwardIncrement) * motor;
            deck.position += positionIncrement;
            const double loopLength = deck.loopEnd - deck.loopStart;
            if (deck.loopActive && loopLength > 0.0 && deck.position >= deck.loopEnd) {
                while (deck.position >= deck.loopEnd) deck.position -= loopLength;
            } else if (deck.loopActive && loopLength > 0.0 && deck.position < deck.loopStart) {
                while (deck.position < deck.loopStart) deck.position += loopLength;   // reverse loop wrap
            } else if (deck.position >= static_cast<double>(deck.frames)) {
                deck.position = static_cast<double>(deck.frames);
                deck.shadowPosition = deck.position;
                deck.playing = false;
                pushEvent(engine, pe_event{PE_EVT_END_OF_TRACK, deckIndex, deck.frames, 0.0f, 0.0f});
                pushStateEvent(engine, deckIndex);
            } else if (deck.reverse && deck.position <= 0.0) {
                // Reversed to the start of the track: stop at zero.
                deck.position = 0.0;
                deck.playing = false;
                deck.motorTarget = 0.0f;
                deck.motorLevel = 0.0f;
                pushStateEvent(engine, deckIndex);
            } else if (deck.position < 0.0) {
                deck.position = 0.0;
            }
        }
    }

    // Pass 1.5 — per-deck key-lock (Phase 6b item 2a). The Pass 1 reader is
    // varispeed (tempo + pitch coupled). When key-lock is engaged and the deck
    // is off nominal speed, run the block through signalsmith-stretch at unity
    // length to *undo* the varispeed pitch shift, then apply the independent key
    // shift. Flat (ratio≈1, semis≈0) or key-lock off ⇒ the block is untouched,
    // so a nominal deck is bit-for-bit identical to before.
    for (int deckIndex = 0; deckIndex < engine->deckCount; ++deckIndex) {
        const bool keylock =
            engine->control.deckKeylock[deckIndex].load(std::memory_order_relaxed) > 0.5f;
        const float ratio = engine->control.deckTimeRatio[deckIndex].load(std::memory_order_relaxed);
        const float semis = engine->control.deckPitch[deckIndex].load(std::memory_order_relaxed);
        const float safeRatio = std::isfinite(ratio) && ratio > 0.0f ? ratio : 1.0f;
        const float safeSemis = std::isfinite(semis) ? semis : 0.0f;
        const bool offNominal = std::fabs(safeRatio - 1.0f) > 0.001f || std::fabs(safeSemis) > 0.01f;
        // Reverse playback and an in-progress vinyl brake / spin-up are
        // varispeed-only (signalsmith-stretch can't run backwards, and the
        // pitch drop *is* the turntable sound).
        if (!keylock || !offNominal || !engine->decks[deckIndex].playing ||
            engine->decks[deckIndex].reverse ||
            std::fabs(engine->decks[deckIndex].motorLevel - 1.0f) > 0.001f) continue;
        pd_timepitch* tp = engine->deckTimePitch[deckIndex];
        if (!tp) continue;
        const float transpose = std::max(-12.0f, std::min(12.0f,
            -12.0f * std::log2(safeRatio) + safeSemis));
        pd_tp_set_mode(tp, PD_TP_KEYLOCK);
        pd_tp_set_time_ratio(tp, 1.0);
        pd_tp_set_pitch_semitones(tp, transpose);
        float scratch[kRenderBlock];
        const float* inPtr[1] = { dry[deckIndex] };
        float* outPtr[1] = { scratch };
        pd_tp_process(tp, inPtr, frames, outPtr, frames);
        for (int f = 0; f < frames; ++f) dry[deckIndex][f] = scratch[f];
    }

    // Pass 2 — per deck: 3-band RBJ isolator EQ, then the resonant sweep filter
    // (Color-FX "Filter", kind 0). Both kernels smooth their own control targets
    // and are unity/pass-through when flat, so an idle deck costs almost nothing.
    for (int deckIndex = 0; deckIndex < engine->deckCount; ++deckIndex) {
        pd_eq3_set(engine->deckEq[deckIndex],
                   engine->control.eqLow[deckIndex].load(std::memory_order_relaxed),
                   engine->control.eqMid[deckIndex].load(std::memory_order_relaxed),
                   engine->control.eqHigh[deckIndex].load(std::memory_order_relaxed));
        pd_eq3_process(engine->deckEq[deckIndex], dry[deckIndex], wet[deckIndex], frames);

        const int colorKind = std::max(0, std::min(6, static_cast<int>(std::lround(
            engine->control.colorKind[deckIndex].load(std::memory_order_relaxed)))));
        const float rawAmount = engine->control.colorAmount[deckIndex].load(std::memory_order_relaxed);
        const float filterKnob = (colorKind == 0 && std::isfinite(rawAmount))
            ? std::max(-1.0f, std::min(1.0f, rawAmount)) : 0.0f;
        // PARAMETER knob scales filter resonance; 0.5 -> 0.3 (the pre-C4 value).
        const float colorParam = engine->control.colorParam[deckIndex].load(std::memory_order_relaxed);
        const float resonance = std::max(0.0f, std::min(0.9f, 0.6f * colorParam));
        pd_filter_set(engine->deckFilter[deckIndex], filterKnob, resonance);
        pd_filter_process(engine->deckFilter[deckIndex], wet[deckIndex], wet[deckIndex], frames);

        // Per-deck beat echo (Phase 6b item 3) — a delay line in the deck chain,
        // period derived from the deck's (synced) effective BPM. The tail keeps
        // running after `echoOn` clears so a released echo decays audibly.
        DeckState& deck = engine->decks[deckIndex];
        if (deck.echoOn || deck.echoTail) {
            const double bpm = deck.echoBpm > 20.0 ? deck.echoBpm : 120.0;
            const double timeSeconds = static_cast<double>(deck.echoBeats) * 60.0 / bpm;
            // mix = 1.0 → pd_delay returns the wet tap (delayed + internal feedback).
            pd_delay_set(engine->deckEcho[deckIndex], timeSeconds, deck.echoFeedback, 1.0f);
            float echoIn[kRenderBlock];
            float echoWet[kRenderBlock];
            for (int f = 0; f < frames; ++f) echoIn[f] = deck.echoOn ? wet[deckIndex][f] : 0.0f;
            pd_delay_process(engine->deckEcho[deckIndex], echoIn, echoWet, frames);
            for (int f = 0; f < frames; ++f) {
                wet[deckIndex][f] = deck.echoOn
                    ? wet[deckIndex][f] + echoWet[f] * deck.echoDepth   // dry + repeats
                    : echoWet[f] * deck.echoDepth;                      // repeats-only tail
            }
            if (!deck.echoOn) {
                deck.echoTailFrames -= frames;
                if (deck.echoTailFrames <= 0) { deck.echoTail = false; deck.echoTailFrames = 0; }
            }
        }
        // Per-channel insert (CDJ3000 parity C3) — post-EQ, pre-gain. Mono bus.
        if (deckIndex < PE_INSERT_MASTER) {
            applyInsert(engine, PE_INSERT_CH0 + deckIndex, wet[deckIndex], nullptr, frames);
        }
    }

    // Mic pre-pass (CDJ3000 parity C5): resample the mic block to a mono buffer,
    // run the 2-band mic EQ, and ease the talkover music-duck toward its target.
    {
        engine->micBlockFrames = 0;
        const float micLvl = engine->control.micLevel.load(std::memory_order_relaxed);
        const bool haveMic = engine->mic.frames > 0 && engine->mic.sampleRate > 0.0 &&
                             engine->mic.position < static_cast<double>(engine->mic.frames);
        float blockRms = 0.0f;
        if (haveMic) {
            const int rc = engine->mic.channelCount > 1 ? 1 : 0;
            const int n = std::min(frames, 512);
            for (int f = 0; f < n; ++f) {
                if (engine->mic.position >= static_cast<double>(engine->mic.frames)) {
                    engine->micBlock[f] = 0.0f;
                    continue;
                }
                const float s = 0.5f * (sampleAt(engine->mic, 0, engine->mic.position) +
                                        sampleAt(engine->mic, rc, engine->mic.position));
                engine->micBlock[f] = s;
                blockRms += s * s;
                engine->mic.position += engine->mic.sampleRate / engine->sampleRate;
            }
            engine->micBlockFrames = n;
            blockRms = std::sqrt(blockRms / static_cast<float>(std::max(1, n)));
            pd_eq3_set(engine->micEq,
                       engine->control.micEqLow.load(std::memory_order_relaxed),
                       0.0f,   // 2-band mic EQ: mid stays flat
                       engine->control.micEqHigh.load(std::memory_order_relaxed));
            pd_eq3_process(engine->micEq, engine->micBlock, engine->micBlock, n);
        }
        // Talkover: duck the music while the mic signal is above threshold.
        float duckTarget = 1.0f;
        if (engine->control.micTalkoverOn.load(std::memory_order_relaxed) > 0.5f && micLvl > 0.0f &&
            blockRms > engine->control.micTalkoverThreshold.load(std::memory_order_relaxed)) {
            const float depthDb = engine->control.micTalkoverDepthDb.load(std::memory_order_relaxed);
            duckTarget = std::pow(10.0f, std::min(0.0f, depthDb) / 20.0f);
        }
        // ~60 ms attack/release smoothing.
        const float a = 1.0f - std::exp(-1.0f / (static_cast<float>(engine->sampleRate) * 0.060f) *
                                        static_cast<float>(frames));
        engine->talkoverGain += a * (duckTarget - engine->talkoverGain);
    }

    // Pass 3 — per frame: non-filter Color-FX (still per-sample stateful),
    // crossfader/fader/trim gain, sum, mic, sampler, bus beat FX, master gain.
    for (int frame = 0; frame < frames; ++frame) {
        float channelSignals[PE_MAX_DECKS] = {0.0f, 0.0f, 0.0f, 0.0f};
        for (int deckIndex = 0; deckIndex < engine->deckCount; ++deckIndex) {
            float sample = wet[deckIndex][frame];
            const int colorKind = std::max(0, std::min(6, static_cast<int>(std::lround(
                engine->control.colorKind[deckIndex].load(std::memory_order_relaxed)))));
            if (colorKind != 0 && engine->decks[deckIndex].playing) {
                sample = processColorFX(engine->decks[deckIndex], sample,
                                        engine->decks[deckIndex].sampleRate, deckIndex, engine->control);
            }
            channelSignals[deckIndex] = sample * channelGains[deckIndex];
            const float channelPeak = std::fabs(channelSignals[deckIndex]);
            if (channelPeak > deckPeaks[deckIndex]) deckPeaks[deckIndex] = channelPeak;
        }
        float channelSum = 0.0f;
        for (int d = 0; d < engine->deckCount; ++d) channelSum += channelSignals[d];
        // Talkover music-duck (CDJ3000 parity C5).
        channelSum *= engine->talkoverGain;
        // Mic (CDJ3000 parity C5): EQ'd block from the pre-pass. When mic-FX is
        // on, the mic rides in channelSum so the "all channels" / "master" Beat
        // FX assigns process it; otherwise it lands post-FX.
        const float micFxOn = engine->control.micFxOn.load(std::memory_order_relaxed);
        float micSample = 0.0f;
        if (micLevel > 0.0f && frame < engine->micBlockFrames) {
            micSample = micLevel * engine->micBlock[frame];
        }
        float mixed;
        if (micSample != 0.0f && micFxOn > 0.5f) {
            channelSum += micSample;
            mixed = channelSum;
        } else {
            mixed = channelSum + micSample;
        }
        for (int slotIndex = 0; slotIndex < 16; ++slotIndex) {
            SamplerSlot& slot = engine->sampler[slotIndex];
            if (!slot.playing || slot.frames <= 0) continue;
            const int rightChannel = slot.channelCount > 1 ? 1 : 0;
            mixed += 0.5f * (
                sampleAt(slot, 0, slot.position) + sampleAt(slot, rightChannel, slot.position)
            ) * slot.gain * engine->samplerMasterGain;
            ++slot.position;
            if (slot.position >= slot.frames) {
                if (slot.mode == 1) slot.position = 0;   // loop
                else slot.playing = false;               // one-shot / gate: play out then stop
            }
        }
        if (engine->beatFXOn || engine->beatFXTail) {
            const float extraSignal = mixed - channelSum;  // mic + sampler contribution
            const int assign = engine->beatFXAssign;
            if (assign == 0 || assign == 1) {
                // Per-channel: assign 0/1 target mixer channels A/B. C3/C4 widen
                // this to any of the (up to 4) channels + MIC.
                if (assign < engine->deckCount) {
                    const float before = channelSignals[assign];
                    channelSignals[assign] = processBeatFX(engine, before);
                    channelSum += channelSignals[assign] - before;
                }
                mixed = channelSum + extraSignal;
            } else if (assign == 2) {                       // all channels summed
                mixed = processBeatFX(engine, channelSum) + extraSignal;
            } else {                                        // master (whole mix)
                mixed = processBeatFX(engine, mixed);
            }
        }
        const float out = mixed * master;
        if (left) left[frame] = out;
        if (right) right[frame] = out;
    }

    // Master insert (CDJ3000 parity C3) — post master fader, pre isolator/limiter.
    applyInsert(engine, PE_INSERT_MASTER, left, right, frames);

    // Pass 3.5 — master isolator (CDJ3000 parity C3). Post-fader, pre-limiter.
    // pd_eq3 is unity/pass-through at 0 dB so a flat isolator is bit-transparent.
    // The engine master bus is mono (left == right), so run one channel and mirror.
    {
        const float lo = engine->control.masterEqLow.load(std::memory_order_relaxed);
        const float mid = engine->control.masterEqMid.load(std::memory_order_relaxed);
        const float hi = engine->control.masterEqHigh.load(std::memory_order_relaxed);
        pd_eq3_set(engine->masterEq, lo, mid, hi);
        float* bus = left ? left : right;
        if (bus) {
            pd_eq3_process(engine->masterEq, bus, bus, frames);
            if (left && right && left != right) {
                for (int f = 0; f < frames; ++f) right[f] = left[f];
            }
        }
    }

    // Pass 3.7 — master reverb send (CDJ3000 parity C7). The FDN produces a
    // genuine stereo tail, so left/right diverge from here on. Fully dry at
    // send 0 (the default), so a default engine is bit-transparent.
    {
        const float send = engine->control.masterReverbSend.load(std::memory_order_relaxed);
        if (send > 0.0001f && left) {
            float* r = right ? right : left;
            const bool convMode = engine->control.masterReverbMode.load(std::memory_order_relaxed) > 0.5f;
            if (convMode) {
                // Convolution reverb (C7c) — runs a real IR. Falls back to a dry
                // passthrough inside pd_conv when no IR is loaded.
                pd_conv_set_mix(engine->masterConv, send);
                pd_conv_process(engine->masterConv, left, r, left, r, frames);
            } else {
                pd_fdnverb_set(engine->masterReverb,
                               engine->control.masterReverbSize.load(std::memory_order_relaxed),
                               engine->control.masterReverbDecay.load(std::memory_order_relaxed),
                               engine->control.masterReverbDamp.load(std::memory_order_relaxed),
                               send);
                pd_fdnverb_process(engine->masterReverb, left, r, left, r, frames);
            }
        }
    }

    // Pass 4 — master look-ahead brickwall limiter (block, stereo, in-place).
    // Bypassable (Phase 6b item 8) so `WorkspaceEngine.limiterCeiling` can be nil.
    if (engine->control.limiterEnabled.load(std::memory_order_relaxed) > 0.5f) {
        pd_limiter_process(engine->masterLimiter, left, right, frames);
    }
    for (int frame = 0; frame < frames; ++frame) {
        const float peak = std::fabs(left ? left[frame] : (right ? right[frame] : 0.0f));
        if (peak > masterPeak) masterPeak = peak;
    }
}

static void render(pe_engine* engine, float* left, float* right, int frames) {
    if (!engine || frames <= 0) {
        clearOutput(left, right, frames);
        return;
    }

    const auto renderStart = std::chrono::steady_clock::now();
    clearOutput(left, right, frames);
    drainCommands(engine);

    const float rawBeatKind = engine->control.beatFXKind.load(std::memory_order_relaxed);
    if (std::isfinite(rawBeatKind)) {
        engine->beatFXKind = std::max(0, std::min(19, static_cast<int>(std::lround(rawBeatKind))));
    }
    const float rawBeatAssign = engine->control.beatFXAssign.load(std::memory_order_relaxed);
    if (std::isfinite(rawBeatAssign)) {
        engine->beatFXAssign = std::max(0, std::min(3, static_cast<int>(std::lround(rawBeatAssign))));
    }
    if (engine->control.beatFXOn.load(std::memory_order_relaxed) > 0.5f) {
        engine->beatFXOn = true;
        engine->beatFXTail = false;
    } else if (!engine->beatFXTail) {
        engine->beatFXOn = false;
    }

    const float crossfader = engine->control.crossfader.load(std::memory_order_relaxed);
    float gainA = 0.0f;
    float gainB = 0.0f;
    crossfadeGains(
        crossfader,
        engine->control.curve.load(std::memory_order_relaxed),
        gainA,
        gainB
    );
    if (!engine->crossfaderInitialized) {
        engine->previousCrossfader = crossfader;
        engine->crossfaderInitialized = true;
    } else if (std::fabs(crossfader - engine->previousCrossfader) > 0.0001f) {
        for (int deckIndex = 0; deckIndex < engine->deckCount; ++deckIndex) {
            if (engine->control.faderStart[deckIndex].load(std::memory_order_relaxed) > 0.5f &&
                !engine->decks[deckIndex].playing && engine->decks[deckIndex].frames > 0) {
                engine->decks[deckIndex].playing = true;
                pushStateEvent(engine, deckIndex);
            }
        }
        engine->previousCrossfader = crossfader;
    }
    const float master = engine->control.masterLevel.load(std::memory_order_relaxed);
    const float micLevel = engine->control.micLevel.load(std::memory_order_relaxed);
    float channelGains[PE_MAX_DECKS] = {0.0f, 0.0f, 0.0f, 0.0f};
    for (int deckIndex = 0; deckIndex < engine->deckCount; ++deckIndex) {
        const float assignment = engine->control.xfadeAssign[deckIndex].load(std::memory_order_relaxed);
        // 0 = crossfader A side, 1 = B side, 2 = thru (even decks track A, odd
        // track B — preserves the classic 2-deck default where A→gainA, B→gainB).
        const float assignedGain = assignment < 0.5f ? gainA :
            (assignment < 1.5f ? gainB : ((deckIndex % 2 == 0) ? gainA : gainB));
        channelGains[deckIndex] = engine->control.trim[deckIndex].load(std::memory_order_relaxed) *
            engine->control.fader[deckIndex].load(std::memory_order_relaxed) * assignedGain;
    }

    pd_limiter_set_ceiling(engine->masterLimiter,
                           engine->control.limiterCeilingDB.load(std::memory_order_relaxed));

    float deckPeaks[PE_MAX_DECKS] = {0.0f, 0.0f, 0.0f, 0.0f};
    float masterPeak = 0.0f;
    for (int base = 0; base < frames; base += kRenderBlock) {
        const int count = std::min(kRenderBlock, frames - base);
        renderChunk(engine,
                    left ? left + base : nullptr,
                    right ? right + base : nullptr,
                    count, channelGains, master, micLevel, deckPeaks, masterPeak);
    }

    // Master-bus record tap (Phase 6b item 4). Copy the rendered block into the
    // ring; drop-and-count if the control side has not drained it in time.
    if (engine->recordActive.load(std::memory_order_relaxed) != 0) {
        const uint32_t cap = pe_engine::kRecordCapacity;
        uint32_t write = engine->recordWrite.load(std::memory_order_relaxed);
        uint32_t read = engine->recordRead.load(std::memory_order_acquire);
        for (int frame = 0; frame < frames; ++frame) {
            if (write - read >= cap) {
                engine->recordDropped.fetch_add(1, std::memory_order_relaxed);
                engine->recordRead.fetch_add(1, std::memory_order_release);
                ++read;
            }
            engine->recordLeft[write % cap] = left ? left[frame] : 0.0f;
            engine->recordRight[write % cap] = right ? right[frame] : 0.0f;
            ++write;
        }
        engine->recordWrite.store(write, std::memory_order_release);
    }

    // Booth snapshot (CDJ3000 parity C3) — stash the final master block so the
    // next pe_render_booth call can apply the independent booth level + EQ.
    {
        const int n = std::min(frames, pe_engine::kBoothCapacity);
        for (int f = 0; f < n; ++f) {
            engine->boothLeft[f] = left ? left[f] : 0.0f;
            engine->boothRight[f] = right ? right[f] : engine->boothLeft[f];
        }
        engine->boothFrames = n;
    }

    for (int deckIndex = 0; deckIndex < engine->deckCount; ++deckIndex) {
        pushPlayheadEvent(engine, deckIndex);
        pushPeakEvent(engine, deckIndex, deckPeaks[deckIndex]);
    }
    pushPeakEvent(engine, -1, masterPeak);

    // Telemetry atomics (Phase 6b item 2). The master frame counter is the
    // authoritative clock time the control side renders all playheads against;
    // per-deck effective BPM / sync state are owned by pe_set_deck_sync.
    engine->masterFrame.fetch_add(frames, std::memory_order_relaxed);
    const double bufferPeriod = static_cast<double>(frames) / engine->sampleRate;
    const double elapsed = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - renderStart).count();
    if (bufferPeriod > 0.0) {
        engine->renderLoad.store(elapsed / bufferPeriod, std::memory_order_relaxed);
    }
}

static void renderMonitor(pe_engine* engine, float* left, float* right, int frames) {
    if (!engine || frames <= 0) {
        clearOutput(left, right, frames);
        return;
    }

    clearOutput(left, right, frames);
    drainCommands(engine);

    float gainA = 0.0f;
    float gainB = 0.0f;
    crossfadeGains(
        engine->control.crossfader.load(std::memory_order_relaxed),
        engine->control.curve.load(std::memory_order_relaxed),
        gainA,
        gainB
    );
    const float masterLevel = engine->control.masterLevel.load(std::memory_order_relaxed);
    const float micLevel = engine->control.micLevel.load(std::memory_order_relaxed);
    const float mix = engine->control.cueMasterMix.load(std::memory_order_relaxed);
    const float masterCue = engine->control.masterCue.load(std::memory_order_relaxed);
    const float headphoneLevel = engine->control.headphoneLevel.load(std::memory_order_relaxed);
    float channelGains[PE_MAX_DECKS] = {0.0f, 0.0f, 0.0f, 0.0f};
    float cueGains[PE_MAX_DECKS] = {0.0f, 0.0f, 0.0f, 0.0f};
    for (int deckIndex = 0; deckIndex < engine->deckCount; ++deckIndex) {
        const float assignment = engine->control.xfadeAssign[deckIndex].load(std::memory_order_relaxed);
        const float assignedGain = assignment < 0.5f ? gainA :
            (assignment < 1.5f ? gainB : ((deckIndex % 2 == 0) ? gainA : gainB));
        const float trimFader = engine->control.trim[deckIndex].load(std::memory_order_relaxed) *
            engine->control.fader[deckIndex].load(std::memory_order_relaxed);
        channelGains[deckIndex] = trimFader * assignedGain;
        cueGains[deckIndex] = trimFader;
    }

    for (int frame = 0; frame < frames; ++frame) {
        float cueSignal = 0.0f;
        float masterSignal = 0.0f;
        for (int deckIndex = 0; deckIndex < engine->deckCount; ++deckIndex) {
            const DeckState& deck = engine->decks[deckIndex];
            if (!deck.playing || deck.frames <= 0 || deck.sampleRate <= 0.0) continue;
            const int rightChannel = deck.channelCount > 1 ? 1 : 0;
            const float sample = 0.5f * (
                sampleAt(deck, 0, deck.position) + sampleAt(deck, rightChannel, deck.position)
            );
            masterSignal += sample * channelGains[deckIndex];
            if (engine->control.cuePFL[deckIndex].load(std::memory_order_relaxed) > 0.5f) {
                cueSignal += sample * cueGains[deckIndex];
            }
        }
        if (masterCue > 0.5f) {
            masterSignal *= masterLevel;
            if (micLevel > 0.0f && engine->mic.position < static_cast<double>(engine->mic.frames) &&
                engine->mic.frames > 0 && engine->mic.sampleRate > 0.0) {
                const int rightChannel = engine->mic.channelCount > 1 ? 1 : 0;
                masterSignal += micLevel * 0.5f * (
                    sampleAt(engine->mic, 0, engine->mic.position) +
                    sampleAt(engine->mic, rightChannel, engine->mic.position)
                );
            }
        } else {
            masterSignal = 0.0f;
        }
        const int cueMode = static_cast<int>(std::lround(
            engine->control.cueMode.load(std::memory_order_relaxed)));
        if (cueMode == 1) {
            // splitOutput (§44.2a): master summed to mono-left, cue to mono-right.
            if (left) left[frame] = masterSignal * headphoneLevel;
            if (right) right[frame] = cueSignal * headphoneLevel;
        } else {
            // off / cueInPlace / multichannel: the existing blended mono bus.
            const float output = ((1.0f - mix) * cueSignal + mix * masterSignal) * headphoneLevel;
            if (left) left[frame] = output;
            if (right) right[frame] = output;
        }
    }
}

} // namespace

extern "C" {

pe_engine* pe_create_with_isolator_profile(double sample_rate, int max_frames, int deck_count,
                                           pe_isolator_profile profile) {
    if (!(sample_rate > 0.0) || max_frames <= 0) return nullptr;
    pe_engine* engine = new (std::nothrow) pe_engine{};
    if (!engine) return nullptr;
    engine->sampleRate = sample_rate;
    engine->maxFrames = max_frames;
    engine->deckCount = deck_count < 2 ? 2 : (deck_count > PE_MAX_DECKS ? PE_MAX_DECKS : deck_count);
    for (int i = 0; i < PE_INSERT_COUNT; ++i) {
        engine->insertFn[i].store(nullptr, std::memory_order_relaxed);
        engine->insertCtx[i].store(nullptr, std::memory_order_relaxed);
    }
    // The SPEC §35.2 isolator: low/high shelf + mid peak, crossovers 200 Hz /
    // 2 kHz, −∞(kill)…+6 dB. Master: SPEC §35.5 look-ahead brickwall.
    bool ok = true;
    for (int deckIndex = 0; deckIndex < engine->deckCount; ++deckIndex) {
        engine->deckEq[deckIndex] = pd_eq3_create(sample_rate, 200.0, 2000.0);
        engine->deckFilter[deckIndex] = pd_filter_create(sample_rate);
        engine->deckEcho[deckIndex] = pd_delay_create(sample_rate, 13.0);
        engine->deckTimePitch[deckIndex] = pd_tp_create(sample_rate, 1, max_frames);
        ok = ok && engine->deckEq[deckIndex] && engine->deckFilter[deckIndex] &&
             engine->deckEcho[deckIndex] && engine->deckTimePitch[deckIndex];
    }
    engine->masterLimiter = pd_limiter_create(sample_rate, -0.3f);
    engine->masterEq = pd_eq3_create(sample_rate, 200.0, 2000.0);
    engine->boothEq = pd_eq3_create(sample_rate, 200.0, 2000.0);
    engine->micEq = pd_eq3_create(sample_rate, 200.0, 3000.0);
    engine->masterReverb = pd_fdnverb_create(sample_rate);
    engine->masterConv = pd_conv_create(sample_rate);
    ok = ok && engine->masterLimiter && engine->masterEq && engine->boothEq &&
         engine->micEq && engine->masterReverb && engine->masterConv;
    if (!ok) {
        pe_destroy(engine);
        return nullptr;
    }
    pd_eq3_set_profile(engine->masterEq,
                       profile == PE_ISOLATOR_PROFILE_WARM2
                           ? PD_EQ3_PROFILE_WARM2 : PD_EQ3_PROFILE_GENERIC);
    return engine;
}

pe_engine* pe_create(double sample_rate, int max_frames, int deck_count) {
    return pe_create_with_isolator_profile(sample_rate, max_frames, deck_count,
                                            PE_ISOLATOR_PROFILE_GENERIC);
}

void pe_destroy(pe_engine* engine) {
    if (!engine) return;
    for (int deckIndex = 0; deckIndex < PE_MAX_DECKS; ++deckIndex) {
        pd_eq3_destroy(engine->deckEq[deckIndex]);
        pd_filter_destroy(engine->deckFilter[deckIndex]);
        pd_delay_destroy(engine->deckEcho[deckIndex]);
        pd_tp_destroy(engine->deckTimePitch[deckIndex]);
    }
    pd_limiter_destroy(engine->masterLimiter);
    pd_eq3_destroy(engine->masterEq);
    pd_eq3_destroy(engine->boothEq);
    pd_eq3_destroy(engine->micEq);
    pd_fdnverb_destroy(engine->masterReverb);
    pd_conv_destroy(engine->masterConv);
    delete engine;
}

void pe_set_control(pe_engine* engine, const pe_control* control) {
    if (!engine || !control) return;
    engine->control.crossfader.store(control->crossfader, std::memory_order_relaxed);
    engine->control.curve.store(control->xfade_curve, std::memory_order_relaxed);
    engine->control.masterLevel.store(control->master_level, std::memory_order_relaxed);
    engine->control.limiterCeilingDB.store(
        std::isfinite(control->limiter_ceiling_db) ? control->limiter_ceiling_db : -0.3f,
        std::memory_order_relaxed
    );
    engine->control.micLevel.store(
        std::isfinite(control->mic_level) && control->mic_level >= 0.0f ? control->mic_level : 0.0f,
        std::memory_order_relaxed
    );
    engine->control.micEqLow.store(std::isnan(control->mic_eq_low) ? 0.0f : control->mic_eq_low,
                                   std::memory_order_relaxed);
    engine->control.micEqHigh.store(std::isnan(control->mic_eq_high) ? 0.0f : control->mic_eq_high,
                                    std::memory_order_relaxed);
    engine->control.micTalkoverOn.store(control->mic_talkover_on > 0.5f ? 1.0f : 0.0f,
                                        std::memory_order_relaxed);
    engine->control.micTalkoverDepthDb.store(
        std::isfinite(control->mic_talkover_depth_db) ? control->mic_talkover_depth_db : -14.0f,
        std::memory_order_relaxed);
    engine->control.micTalkoverThreshold.store(
        std::isfinite(control->mic_talkover_threshold) && control->mic_talkover_threshold >= 0.0f
            ? control->mic_talkover_threshold : 0.02f,
        std::memory_order_relaxed);
    engine->control.micFxOn.store(control->mic_fx_on > 0.5f ? 1.0f : 0.0f, std::memory_order_relaxed);
    auto clamp01f = [](float x, float d) { return std::isfinite(x) ? std::max(0.0f, std::min(1.0f, x)) : d; };
    engine->control.masterReverbSend.store(clamp01f(control->master_reverb_send, 0.0f), std::memory_order_relaxed);
    engine->control.masterReverbSize.store(clamp01f(control->master_reverb_size, 0.6f), std::memory_order_relaxed);
    engine->control.masterReverbDecay.store(clamp01f(control->master_reverb_decay, 0.6f), std::memory_order_relaxed);
    engine->control.masterReverbDamp.store(clamp01f(control->master_reverb_damp, 0.5f), std::memory_order_relaxed);
    engine->control.masterReverbMode.store(control->master_reverb_mode > 0.5f ? 1.0f : 0.0f,
                                           std::memory_order_relaxed);
    engine->control.cueMasterMix.store(
        std::isfinite(control->cue_master_mix) ?
            std::max(0.0f, std::min(1.0f, control->cue_master_mix)) : 0.5f,
        std::memory_order_relaxed
    );
    engine->control.masterCue.store(control->master_cue > 0.5f ? 1.0f : 0.0f, std::memory_order_relaxed);
    engine->control.headphoneLevel.store(
        std::isfinite(control->headphone_level) ?
            std::max(0.0f, std::min(1.0f, control->headphone_level)) : 0.7f,
        std::memory_order_relaxed
    );
    engine->control.beatFXKind.store(control->beatfx_kind, std::memory_order_relaxed);
    engine->control.beatFXBeats.store(
        std::isfinite(control->beatfx_beats) && control->beatfx_beats > 0.0f ? control->beatfx_beats : 0.5f,
        std::memory_order_relaxed
    );
    engine->control.beatFXDepth.store(
        std::isfinite(control->beatfx_depth) ? std::max(0.0f, std::min(1.0f, control->beatfx_depth)) : 0.5f,
        std::memory_order_relaxed
    );
    engine->control.beatFXAssign.store(
        std::isfinite(control->beatfx_assign) ? std::max(0.0f, std::min(3.0f, control->beatfx_assign)) : 0.0f,
        std::memory_order_relaxed
    );
    engine->control.beatFXOn.store(control->beatfx_on > 0.5f ? 1.0f : 0.0f, std::memory_order_relaxed);
    engine->control.beatFXXpad.store(
        std::isfinite(control->beatfx_xpad) ? std::min(1.0f, control->beatfx_xpad) : -1.0f,
        std::memory_order_relaxed);
    engine->control.beatFXBand.store(
        std::isfinite(control->beatfx_band) ? std::max(0.0f, std::min(3.0f, control->beatfx_band)) : 0.0f,
        std::memory_order_relaxed);
    engine->control.limiterEnabled.store(control->limiter_enabled > 0.5f ? 1.0f : 0.0f,
                                         std::memory_order_relaxed);
    engine->control.cueMode.store(
        std::isfinite(control->cue_mode) ? std::max(0.0f, std::min(3.0f, control->cue_mode)) : 0.0f,
        std::memory_order_relaxed);
    engine->control.masterEqLow.store(std::isnan(control->master_eq_low) ? 0.0f : control->master_eq_low,
                                      std::memory_order_relaxed);
    engine->control.masterEqMid.store(std::isnan(control->master_eq_mid) ? 0.0f : control->master_eq_mid,
                                      std::memory_order_relaxed);
    engine->control.masterEqHigh.store(std::isnan(control->master_eq_high) ? 0.0f : control->master_eq_high,
                                       std::memory_order_relaxed);
    engine->control.boothLevel.store(
        std::isfinite(control->booth_level) && control->booth_level >= 0.0f ? control->booth_level : 0.8f,
        std::memory_order_relaxed);
    engine->control.boothEqLow.store(std::isnan(control->booth_eq_low) ? 0.0f : control->booth_eq_low,
                                     std::memory_order_relaxed);
    engine->control.boothEqMid.store(std::isnan(control->booth_eq_mid) ? 0.0f : control->booth_eq_mid,
                                     std::memory_order_relaxed);
    engine->control.boothEqHigh.store(std::isnan(control->booth_eq_high) ? 0.0f : control->booth_eq_high,
                                      std::memory_order_relaxed);
    for (int index = 0; index < PE_MAX_DECKS; ++index) {
        engine->control.trim[index].store(control->trim[index], std::memory_order_relaxed);
        engine->control.fader[index].store(control->fader[index], std::memory_order_relaxed);
        engine->control.cuePFL[index].store(control->cue_pfl[index] > 0.5f ? 1.0f : 0.0f, std::memory_order_relaxed);
        const float assignment = control->xfade_assign[index];
        engine->control.xfadeAssign[index].store(
            std::isfinite(assignment) ? std::max(0.0f, std::min(2.0f, assignment)) : 2.0f,
            std::memory_order_relaxed
        );
        engine->control.faderStart[index].store(control->fader_start[index] > 0.5f ? 1.0f : 0.0f, std::memory_order_relaxed);
        const float low = control->eq_low[index];
        const float mid = control->eq_mid[index];
        const float high = control->eq_high[index];
        engine->control.eqLow[index].store(std::isnan(low) ? 0.0f : low, std::memory_order_relaxed);
        engine->control.eqMid[index].store(std::isnan(mid) ? 0.0f : mid, std::memory_order_relaxed);
        engine->control.eqHigh[index].store(std::isnan(high) ? 0.0f : high, std::memory_order_relaxed);
        const float colorAmount = control->color_amount[index];
        const float colorKind = control->color_kind[index];
        engine->control.colorAmount[index].store(
            std::isfinite(colorAmount) ? std::max(-1.0f, std::min(1.0f, colorAmount)) : 0.0f,
            std::memory_order_relaxed
        );
        engine->control.colorKind[index].store(
            std::isfinite(colorKind) ? std::max(0.0f, std::min(6.0f, colorKind)) : 0.0f,
            std::memory_order_relaxed
        );
        const float colorParam = control->color_param[index];
        engine->control.colorParam[index].store(
            std::isfinite(colorParam) ? std::max(0.0f, std::min(1.0f, colorParam)) : 0.5f,
            std::memory_order_relaxed);
        const float ratio = control->deck_time_ratio[index];
        engine->control.deckTimeRatio[index].store(
            std::isfinite(ratio) && ratio > 0.0f ? ratio : 1.0f,
            std::memory_order_relaxed
        );
        engine->control.deckPitch[index].store(control->deck_pitch[index], std::memory_order_relaxed);
        engine->control.deckKeylock[index].store(
            control->deck_keylock[index] > 0.5f ? 1.0f : 0.0f, std::memory_order_relaxed);
    }
}

int pe_post_command(pe_engine* engine, const pe_command* command) {
    if (!engine || !command) return 0;
    const uint32_t write = engine->queue.writeIndex.load(std::memory_order_relaxed);
    const uint32_t read = engine->queue.readIndex.load(std::memory_order_acquire);
    if (write - read >= kCommandCapacity) return 0;
    engine->queue.commands[write % kCommandCapacity] = *command;
    engine->queue.writeIndex.store(write + 1, std::memory_order_release);
    return 1;
}

int pe_poll_events(pe_engine* engine, pe_event* out, int max) {
    if (!engine || !out || max <= 0) return 0;
    uint32_t read = engine->events.readIndex.load(std::memory_order_relaxed);
    const uint32_t write = engine->events.writeIndex.load(std::memory_order_acquire);
    int count = 0;
    while (read != write && count < max) {
        out[count] = engine->events.events[read % kEventCapacity];
        ++read;
        ++count;
    }
    engine->events.readIndex.store(read, std::memory_order_release);
    return count;
}

void pe_deck_set_buffer(
    pe_engine* engine,
    int deck,
    const float* const* channels,
    int channel_count,
    int64_t frames,
    double sample_rate
) {
    if (!engine || !validDeck(engine, deck) || !channels || channel_count <= 0 || frames < 0 || !(sample_rate > 0.0)) return;
    DeckState& state = engine->decks[deck];
    state.channels[0] = channels[0];
    state.channels[1] = channel_count > 1 ? channels[1] : channels[0];
    state.channelCount = channel_count > 1 ? 2 : 1;
    state.frames = frames;
    state.sampleRate = sample_rate;
    state.position = 0.0;
    state.shadowPosition = 0.0;
    state.playing = false;
    state.slip = false;
    state.reverse = false;
    state.motorLevel = 0.0f;   // a paused platter is stopped; PLAY spins it up
    state.motorTarget = 0.0f;
    state.cueFadeGain = 1.0f;
    state.cueFadeRate = 0.0f;
    state.pendingJump = false;
    state.cueFrame = 0;
    state.cueSet = false;
    state.eqLowGain = 1.0f;
    state.eqMidGain = 1.0f;
    state.eqHighGain = 1.0f;
    state.lowState = 0.0f;
    state.highState = 0.0f;
    state.colorLowState = 0.0f;
    state.colorHighState = 0.0f;
    state.colorDelayIndex = 0;
    state.colorNoiseState = 0x13579BDFu;
    for (float& sample : state.colorDelay) sample = 0.0f;
    for (int slot = 0; slot < 8; ++slot) {
        state.hotCueFrames[slot] = 0;
        state.hotCueSet[slot] = false;
    }
    state.loopIn = 0.0;
    state.loopStart = 0.0;
    state.loopEnd = 0.0;
    state.loopInSet = false;
    state.loopAvailable = false;
    state.loopActive = false;
}

void pe_sampler_set_slot(
    pe_engine* engine,
    int slot,
    const float* const* channels,
    int channel_count,
    int64_t frames
) {
    if (!engine || slot < 0 || slot >= 16 || !channels || channel_count <= 0 || frames < 0) return;
    SamplerSlot& state = engine->sampler[slot];
    state.channels[0] = channels[0];
    state.channels[1] = channel_count > 1 ? channels[1] : channels[0];
    state.channelCount = channel_count > 1 ? 2 : 1;
    state.frames = frames;
    state.position = 0;
    state.playing = false;
}

void pe_mic_set_buffer(
    pe_engine* engine,
    const float* const* channels,
    int channel_count,
    int64_t frames,
    double sample_rate
) {
    if (!engine || !channels || channel_count <= 0 || frames < 0 || !(sample_rate > 0.0)) return;
    engine->mic.channels[0] = channels[0];
    engine->mic.channels[1] = channel_count > 1 ? channels[1] : channels[0];
    engine->mic.channelCount = channel_count > 1 ? 2 : 1;
    engine->mic.frames = frames;
    engine->mic.sampleRate = sample_rate;
    engine->mic.position = 0.0;
}

void pe_deck_set_stem_buffer(
    pe_engine* engine, int deck, int voice, const float* const* channels,
    int channel_count, int64_t frames
) {
    if (!engine || !validDeck(engine, deck) || voice < 0 || voice >= 4) return;
    StemVoice& v = engine->decks[deck].stems[voice];
    if (!channels || channel_count <= 0 || frames <= 0) {
        v.present = false;
        v.channels[0] = v.channels[1] = nullptr;
        v.channelCount = 0;
        v.frames = 0;
        return;
    }
    v.channels[0] = channels[0];
    v.channels[1] = channel_count > 1 ? channels[1] : channels[0];
    v.channelCount = channel_count > 1 ? 2 : 1;
    v.frames = frames;
    v.present = true;
    v.gain = 1.0f;
    v.smoothedGain = 1.0f;
    v.muted = false;
    v.soloed = false;
    engine->decks[deck].stemsArmed = true;
}

void pe_deck_clear_stems(pe_engine* engine, int deck) {
    if (!engine || !validDeck(engine, deck)) return;
    DeckState& d = engine->decks[deck];
    d.stemsArmed = false;
    for (StemVoice& v : d.stems) {
        v.present = false;
        v.channels[0] = v.channels[1] = nullptr;
        v.channelCount = 0;
        v.frames = 0;
        v.smoothedGain = 1.0f;
        v.gain = 1.0f;
        v.muted = false;
        v.soloed = false;
    }
}

void pe_get_stats(pe_engine* engine, pe_stats* out) {
    if (!engine || !out) return;
    out->master_frame = engine->masterFrame.load(std::memory_order_relaxed);
    out->master_bpm = engine->control.masterBpm.load(std::memory_order_relaxed);
    out->downbeat_phase = engine->control.downbeatPhase.load(std::memory_order_relaxed);
    out->render_load = engine->renderLoad.load(std::memory_order_relaxed);
    out->starved_frames = engine->starvedFrames.load(std::memory_order_relaxed);
    for (int i = 0; i < PE_MAX_DECKS; ++i) {
        out->deck_effective_bpm[i] = engine->decks[i].effectiveBpm;
        out->deck_beat_phase[i] = engine->decks[i].beatPhase;
        out->deck_synced[i] = engine->decks[i].synced ? 1 : 0;
    }
}

void pe_set_master_clock(pe_engine* engine, int32_t master_deck, double master_bpm,
                         double downbeat_phase) {
    if (!engine) return;
    engine->control.masterDeck.store(master_deck, std::memory_order_relaxed);
    engine->control.masterBpm.store(std::isfinite(master_bpm) && master_bpm > 0 ? master_bpm : 0.0,
                                    std::memory_order_relaxed);
    engine->control.downbeatPhase.store(
        std::isfinite(downbeat_phase) ? downbeat_phase - std::floor(downbeat_phase) : 0.0,
        std::memory_order_relaxed);
}

void pe_set_deck_sync(pe_engine* engine, int deck, int synced, double effective_bpm,
                      double beat_phase) {
    if (!engine || !validDeck(engine, deck)) return;
    DeckState& d = engine->decks[deck];
    d.synced = synced != 0;
    d.effectiveBpm = std::isfinite(effective_bpm) && effective_bpm > 0 ? effective_bpm : 0.0;
    d.beatPhase = std::isfinite(beat_phase) ? beat_phase - std::floor(beat_phase) : 0.0;
    d.echoBpm = d.effectiveBpm > 0 ? d.effectiveBpm : d.echoBpm;
}

void pe_record_set_active(pe_engine* engine, int active) {
    if (!engine) return;
    engine->recordActive.store(active != 0 ? 1 : 0, std::memory_order_relaxed);
}

int pe_record_drain(pe_engine* engine, float* out_l, float* out_r, int max_frames) {
    if (!engine || max_frames <= 0) return 0;
    const uint32_t cap = pe_engine::kRecordCapacity;
    uint32_t read = engine->recordRead.load(std::memory_order_relaxed);
    const uint32_t write = engine->recordWrite.load(std::memory_order_acquire);
    int count = 0;
    while (read != write && count < max_frames) {
        if (out_l) out_l[count] = engine->recordLeft[read % cap];
        if (out_r) out_r[count] = engine->recordRight[read % cap];
        ++read;
        ++count;
    }
    engine->recordRead.store(read, std::memory_order_release);
    return count;
}

int64_t pe_record_dropped_frames(pe_engine* engine) {
    return engine ? engine->recordDropped.load(std::memory_order_relaxed) : 0;
}

void pe_record_reset(pe_engine* engine) {
    if (!engine) return;
    engine->recordRead.store(engine->recordWrite.load(std::memory_order_acquire),
                             std::memory_order_release);
    engine->recordDropped.store(0, std::memory_order_relaxed);
}

void pe_render(pe_engine* engine, float* left, float* right, int frames) {
    render(engine, left, right, frames);
}

void pe_render_monitor(pe_engine* engine, float* left, float* right, int frames) {
    renderMonitor(engine, left, right, frames);
}

void pe_master_convolution_ir(pe_engine* engine, const float* ir, int ir_len) {
    if (!engine || !engine->masterConv) return;
    pd_conv_set_ir(engine->masterConv, ir, ir_len);
}

void pe_render_booth(pe_engine* engine, float* left, float* right, int frames) {
    if (!engine || frames <= 0) { clearOutput(left, right, frames); return; }
    const float level = engine->control.boothLevel.load(std::memory_order_relaxed);
    pd_eq3_set(engine->boothEq,
               engine->control.boothEqLow.load(std::memory_order_relaxed),
               engine->control.boothEqMid.load(std::memory_order_relaxed),
               engine->control.boothEqHigh.load(std::memory_order_relaxed));
    const int n = std::min({frames, engine->boothFrames, pe_engine::kBoothCapacity});
    for (int f = 0; f < frames; ++f) {
        const float l = f < n ? engine->boothLeft[f] * level : 0.0f;
        const float r = f < n ? engine->boothRight[f] * level : 0.0f;
        if (left) left[f] = l;
        if (right) right[f] = r;
    }
    // Booth EQ on the (mono) booth bus: filter left, mirror to right.
    if (left) {
        pd_eq3_process(engine->boothEq, left, left, frames);
        if (right && right != left) for (int f = 0; f < frames; ++f) right[f] = left[f];
    } else if (right) {
        pd_eq3_process(engine->boothEq, right, right, frames);
    }
}

void pe_step(pe_engine* engine, float* left, float* right, int frames) {
    render(engine, left, right, frames);
}

void pe_set_insert(pe_engine* engine, int point, pe_insert_fn fn, void* ctx) {
    if (!engine || point < 0 || point >= PE_INSERT_COUNT) return;
    if (!fn) {
        engine->insertFn[point].store(nullptr, std::memory_order_release);
        engine->insertCtx[point].store(nullptr, std::memory_order_relaxed);
        return;
    }
    engine->insertCtx[point].store(ctx, std::memory_order_relaxed);
    engine->insertFn[point].store(fn, std::memory_order_release);
}

} // extern "C"
