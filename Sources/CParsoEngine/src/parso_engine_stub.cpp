// CParsoEngine's allocation-free two-deck render core.
// Control-side setup may allocate the handle; pe_render/pe_step only consume
// resident caller-owned PCM and fixed-size command/control state.
#include "parso_engine.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <new>

namespace {

constexpr uint32_t kCommandCapacity = 256;
constexpr uint32_t kEventCapacity = 1024;

struct DeckState {
    const float* channels[2] = {nullptr, nullptr};
    int channelCount = 0;
    int64_t frames = 0;
    double sampleRate = 0.0;
    double position = 0.0;
    double shadowPosition = 0.0;
    bool playing = false;
    bool slip = false;
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
    std::atomic<float> cueMasterMix{0.5f};
    std::atomic<float> masterCue{0.0f};
    std::atomic<float> headphoneLevel{0.7f};
    std::atomic<float> cuePFL[2]{{0.0f}, {0.0f}};
    std::atomic<float> xfadeAssign[2]{{2.0f}, {2.0f}};
    std::atomic<float> faderStart[2]{{0.0f}, {0.0f}};
    std::atomic<float> eqLow[2]{{0.0f}, {0.0f}};
    std::atomic<float> eqMid[2]{{0.0f}, {0.0f}};
    std::atomic<float> eqHigh[2]{{0.0f}, {0.0f}};
    std::atomic<float> colorAmount[2]{{0.0f}, {0.0f}};
    std::atomic<float> colorKind[2]{{0.0f}, {0.0f}};
    std::atomic<float> beatFXKind{0.0f};
    std::atomic<float> beatFXBeats{0.5f};
    std::atomic<float> beatFXDepth{0.5f};
    std::atomic<float> beatFXAssign{0.0f};
    std::atomic<float> beatFXOn{0.0f};
    std::atomic<float> fader[2]{{1.0f}, {1.0f}};
    std::atomic<float> trim[2]{{0.5f}, {0.5f}};
    std::atomic<float> deckTimeRatio[2]{{1.0f}, {1.0f}};
    std::atomic<float> deckPitch[2]{{0.0f}, {0.0f}};
};

} // namespace

struct pe_engine {
    double sampleRate;
    int maxFrames;
    DeckState decks[2];
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
    float limiterGain = 1.0f;
};

namespace {

static bool validDeck(int deck) {
    return deck >= 0 && deck < 2;
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

static float dbToGain(float db) {
    if (std::isnan(db) || db <= -90.0f) return 0.0f;
    if (!std::isfinite(db)) return 1.0f;
    return std::pow(10.0f, db / 20.0f);
}

static float processLimiter(pe_engine* engine, float input) {
    const float ceilingDB = engine->control.limiterCeilingDB.load(std::memory_order_relaxed);
    const float safeDB = std::isfinite(ceilingDB) ? std::max(-90.0f, std::min(0.0f, ceilingDB)) : -0.3f;
    const float ceiling = dbToGain(safeDB);
    const float magnitude = std::fabs(input);
    const float targetGain = magnitude > ceiling && magnitude > 0.0f ? ceiling / magnitude : 1.0f;
    if (targetGain < engine->limiterGain) {
        engine->limiterGain = targetGain;
    } else {
        const float release = 1.0f - std::exp(-1.0f / static_cast<float>(engine->sampleRate * 0.050));
        engine->limiterGain += release * (targetGain - engine->limiterGain);
    }
    float output = input * engine->limiterGain;
    if (std::fabs(output) > ceiling) output = std::copysign(ceiling, output);
    return output;
}

static float processEQ(DeckState& deck, float sample, double sampleRate, int deckIndex,
                       const ControlState& control) {
    const float lowTarget = dbToGain(control.eqLow[deckIndex].load(std::memory_order_relaxed));
    const float midTarget = dbToGain(control.eqMid[deckIndex].load(std::memory_order_relaxed));
    const float highTarget = dbToGain(control.eqHigh[deckIndex].load(std::memory_order_relaxed));
    const float smoothing = 1.0f - std::exp(-1.0f / static_cast<float>(sampleRate * 0.010));
    deck.eqLowGain += smoothing * (lowTarget - deck.eqLowGain);
    deck.eqMidGain += smoothing * (midTarget - deck.eqMidGain);
    deck.eqHighGain += smoothing * (highTarget - deck.eqHighGain);

    const float lowAlpha = 1.0f - std::exp(-2.0f * static_cast<float>(M_PI) * 200.0f /
                                             static_cast<float>(sampleRate));
    const float highAlpha = 1.0f - std::exp(-2.0f * static_cast<float>(M_PI) * 2000.0f /
                                              static_cast<float>(sampleRate));
    deck.lowState += lowAlpha * (sample - deck.lowState);
    deck.highState += highAlpha * (sample - deck.highState);
    const float low = deck.lowState;
    const float high = sample - deck.highState;
    const float mid = deck.highState - deck.lowState;
    return low * deck.eqLowGain + mid * deck.eqMidGain + high * deck.eqHighGain;
}

static float processColorFX(DeckState& deck, float input, double sampleRate, int deckIndex,
                            const ControlState& control) {
    const float rawAmount = control.colorAmount[deckIndex].load(std::memory_order_relaxed);
    const float amount = std::isfinite(rawAmount) ? std::max(-1.0f, std::min(1.0f, rawAmount)) : 0.0f;
    const float wet = std::fabs(amount);
    const float lowAlpha = 1.0f - std::exp(-2.0f * static_cast<float>(M_PI) * 250.0f /
                                             static_cast<float>(sampleRate));
    const float highAlpha = 1.0f - std::exp(-2.0f * static_cast<float>(M_PI) * 1800.0f /
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
        } else if (command.type == PE_CMD_BEATFX_KIND && std::isfinite(command.f0)) {
            engine->beatFXKind = std::max(0, std::min(13, static_cast<int>(std::lround(command.f0))));
        } else if (command.type == PE_CMD_BEATFX_ONOFF) {
            engine->beatFXOn = command.f0 > 0.5f;
            if (engine->beatFXOn) engine->beatFXTail = false;
        } else if (command.type == PE_CMD_BEATFX_RELEASE) {
            engine->beatFXOn = false;
            engine->beatFXTail = true;
            engine->beatFXTailFrames = static_cast<int>(engine->sampleRate * 2.0);
        }
        return;
    }
    if (!validDeck(command.deck)) return;
    DeckState& deck = engine->decks[command.deck];
    switch (command.type) {
        case PE_CMD_PLAY:
            deck.playing = true;
            deck.shadowPosition = deck.position;
            pushStateEvent(engine, command.deck);
            break;
        case PE_CMD_PAUSE:
            deck.playing = false;
            pushStateEvent(engine, command.deck);
            break;
        case PE_CMD_SET_CUE:
            deck.cueFrame = static_cast<int64_t>(deck.position);
            deck.cueSet = true;
            break;
        case PE_CMD_JUMP_CUE:
            if (deck.cueSet) {
                deck.position = static_cast<double>(deck.cueFrame);
                deck.shadowPosition = deck.position;
                pushPlayheadEvent(engine, command.deck);
            }
            break;
        case PE_CMD_SET_MASTER:
        case PE_CMD_SET_KEYLOCK:
        case PE_CMD_COLORFX_KIND:
        case PE_CMD_SAMPLER_TRIGGER:
        case PE_CMD_SAMPLER_STOP:
        case PE_CMD_LOAD:
            // These commands are reserved for subsequent engine slices;
            // ignoring them is deterministic and non-blocking.
            break;
        case PE_CMD_BEATFX_KIND:
            if (std::isfinite(command.f0)) {
                engine->beatFXKind = std::max(0, std::min(13, static_cast<int>(std::lround(command.f0))));
            }
            break;
        case PE_CMD_BEATFX_ONOFF:
            engine->beatFXOn = command.f0 > 0.5f;
            if (engine->beatFXOn) engine->beatFXTail = false;
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
                pushStateEvent(engine, command.deck);
            }
            break;
        case PE_CMD_SEEK:
            if (std::isfinite(command.f0) && deck.frames > 0) {
                const double target = std::max(0.0, std::min(
                    static_cast<double>(deck.frames), static_cast<double>(command.f0)
                ));
                deck.position = target;
                deck.shadowPosition = target;
                pushPlayheadEvent(engine, command.deck);
            }
            break;
        case PE_CMD_BEATJUMP:
            if (std::isfinite(command.f0)) {
                deck.position += static_cast<double>(command.f0) * deck.sampleRate;
                if (deck.position < 0.0) deck.position = 0.0;
                if (deck.position >= static_cast<double>(deck.frames)) {
                    deck.position = static_cast<double>(deck.frames > 0 ? deck.frames - 1 : 0);
                }
                deck.shadowPosition = deck.position;
                pushPlayheadEvent(engine, command.deck);
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
        case PE_CMD_LOOP_IN:
            deck.loopIn = deck.position;
            deck.loopInSet = true;
            break;
        case PE_CMD_LOOP_OUT:
            if (deck.loopInSet) {
                setLoop(deck, deck.loopIn, deck.position);
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
                double start = deck.position;
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
            if (std::isfinite(command.f0) && std::isfinite(command.f1) && deck.sampleRate > 0.0) {
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
                deck.hotCueFrames[slot] = static_cast<int64_t>(deck.position);
                deck.hotCueSet[slot] = true;
            }
            break;
        case PE_CMD_HOTCUE_JUMP:
            if (command.i0 >= 0 && command.i0 < 8 && deck.hotCueSet[command.i0]) {
                deck.position = static_cast<double>(deck.hotCueFrames[command.i0]);
                deck.shadowPosition = deck.position;
                pushPlayheadEvent(engine, command.deck);
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
        const float angle = normalized * static_cast<float>(M_PI_2);
        gainA = std::cos(angle);
        gainB = std::sin(angle);
    } else if (curve < 0.75f) {
        gainA = 1.0f - normalized;
        gainB = normalized;
    } else {
        gainA = normalized < 0.5f ? 1.0f : 0.0f;
        gainB = normalized < 0.5f ? 0.0f : 1.0f;
    }
}

static float processBeatFX(pe_engine* engine, float input) {
    const bool active = engine->beatFXOn || engine->beatFXTail;
    if (!active) return input;

    const float rawBeats = engine->control.beatFXBeats.load(std::memory_order_relaxed);
    const float beats = std::isfinite(rawBeats) ? std::max(0.0625f, std::min(8.0f, rawBeats)) : 0.5f;
    const int kind = engine->beatFXKind;
    int delaySamples = std::max(1, std::min(47999, static_cast<int>(engine->sampleRate * beats * 0.5f)));
    if (kind == 2) delaySamples = std::max(1, std::min(47999, static_cast<int>(engine->sampleRate * 0.08)));
    if (kind == 5 || kind == 6) delaySamples = std::max(1, std::min(47999, static_cast<int>(engine->sampleRate * 0.005)));

    const uint32_t index = engine->beatFXDelayIndex;
    const uint32_t delayedIndex = (index + 48000u - static_cast<uint32_t>(delaySamples)) % 48000u;
    const float delayed = engine->beatFXDelay[delayedIndex];
    const float rawDepth = engine->control.beatFXDepth.load(std::memory_order_relaxed);
    const float depth = std::isfinite(rawDepth) ? std::max(0.0f, std::min(1.0f, rawDepth)) : 0.5f;
    float wet = delayed;
    float feedback = 0.55f;
    switch (kind) {
        case 2: // Reverb.
            feedback = 0.72f;
            wet = delayed + input * 0.35f;
            break;
        case 5: // Flanger.
            wet = delayed;
            feedback = 0.4f;
            break;
        case 6: // Phaser approximation with a short all-pass-like blend.
            wet = input - delayed;
            feedback = 0.35f;
            break;
        case 7: // Trans.
            wet = delayed;
            feedback = 0.25f;
            break;
        case 8: // Roll.
            wet = delayed;
            feedback = 0.75f;
            break;
        default:
            break;
    }
    engine->beatFXDelay[index] = input + wet * feedback;
    engine->beatFXDelayIndex = (index + 1) % 48000u;
    const float output = input * (1.0f - depth) + wet * depth;
    if (engine->beatFXTail) {
        if (engine->beatFXTailFrames > 0) --engine->beatFXTailFrames;
        if (engine->beatFXTailFrames == 0) engine->beatFXTail = false;
    }
    return output;
}

static void render(pe_engine* engine, float* left, float* right, int frames) {
    if (!engine || frames <= 0) {
        clearOutput(left, right, frames);
        return;
    }

    clearOutput(left, right, frames);
    drainCommands(engine);

    const float rawBeatKind = engine->control.beatFXKind.load(std::memory_order_relaxed);
    if (std::isfinite(rawBeatKind)) {
        engine->beatFXKind = std::max(0, std::min(13, static_cast<int>(std::lround(rawBeatKind))));
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
        for (int deckIndex = 0; deckIndex < 2; ++deckIndex) {
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
    float channelGains[2] = {
        engine->control.trim[0].load(std::memory_order_relaxed) *
            engine->control.fader[0].load(std::memory_order_relaxed) * gainA,
        engine->control.trim[1].load(std::memory_order_relaxed) *
            engine->control.fader[1].load(std::memory_order_relaxed) * gainB
    };
    for (int deckIndex = 0; deckIndex < 2; ++deckIndex) {
        const float assignment = engine->control.xfadeAssign[deckIndex].load(std::memory_order_relaxed);
        const float assignedGain = assignment < 0.5f ? gainA :
            (assignment < 1.5f ? gainB : (deckIndex == 0 ? gainA : gainB));
        channelGains[deckIndex] = engine->control.trim[deckIndex].load(std::memory_order_relaxed) *
            engine->control.fader[deckIndex].load(std::memory_order_relaxed) * assignedGain;
    }

    float deckPeaks[2] = {0.0f, 0.0f};
    float masterPeak = 0.0f;
    for (int frame = 0; frame < frames; ++frame) {
        float channelSignals[2] = {0.0f, 0.0f};
        for (int deckIndex = 0; deckIndex < 2; ++deckIndex) {
            DeckState& deck = engine->decks[deckIndex];
            if (!deck.playing || deck.frames <= 0 || deck.sampleRate <= 0.0) continue;
            const double sourcePosition = deck.position;
            const int rightChannel = deck.channelCount > 1 ? 1 : 0;
            float sample = 0.5f * (
                sampleAt(deck, 0, sourcePosition) + sampleAt(deck, rightChannel, sourcePosition)
            );
            sample = processEQ(deck, sample, deck.sampleRate, deckIndex, engine->control);
            sample = processColorFX(deck, sample, deck.sampleRate, deckIndex, engine->control);
            channelSignals[deckIndex] += sample * channelGains[deckIndex];
            const float channelSample = sample * channelGains[deckIndex];
            const float channelPeak = std::fabs(channelSample);
            if (channelPeak > deckPeaks[deckIndex]) deckPeaks[deckIndex] = channelPeak;
            const float tempoRatio = engine->control.deckTimeRatio[deckIndex].load(std::memory_order_relaxed);
            const double positionIncrement = deck.sampleRate / engine->sampleRate *
                (std::isfinite(tempoRatio) && tempoRatio > 0.0f ? tempoRatio : 1.0f);
            if (deck.slip) deck.shadowPosition += positionIncrement;
            deck.position += positionIncrement;
            if (deck.loopActive && deck.loopEnd > deck.loopStart && deck.position >= deck.loopEnd) {
                const double loopLength = deck.loopEnd - deck.loopStart;
                while (deck.position >= deck.loopEnd) {
                    deck.position -= loopLength;
                }
            } else if (deck.position >= static_cast<double>(deck.frames)) {
                deck.position = static_cast<double>(deck.frames);
                deck.shadowPosition = deck.position;
                deck.playing = false;
                pushEvent(engine, pe_event{
                    PE_EVT_END_OF_TRACK,
                    deckIndex,
                    deck.frames,
                    0.0f,
                    0.0f
                });
                pushStateEvent(engine, deckIndex);
            }
        }
        float mixed = channelSignals[0] + channelSignals[1];
        if (micLevel > 0.0f && engine->mic.position < static_cast<double>(engine->mic.frames) &&
            engine->mic.frames > 0 && engine->mic.sampleRate > 0.0) {
            const int rightChannel = engine->mic.channelCount > 1 ? 1 : 0;
            const float micSample = 0.5f * (
                sampleAt(engine->mic, 0, engine->mic.position) +
                sampleAt(engine->mic, rightChannel, engine->mic.position)
            );
            mixed += micSample * micLevel;
            engine->mic.position += engine->mic.sampleRate / engine->sampleRate;
            if (engine->mic.position >= static_cast<double>(engine->mic.frames)) {
                engine->mic.position = static_cast<double>(engine->mic.frames);
            }
        }
        for (int slotIndex = 0; slotIndex < 16; ++slotIndex) {
            SamplerSlot& slot = engine->sampler[slotIndex];
            if (!slot.playing || slot.frames <= 0) continue;
            const int rightChannel = slot.channelCount > 1 ? 1 : 0;
            mixed += 0.5f * (
                sampleAt(slot, 0, slot.position) + sampleAt(slot, rightChannel, slot.position)
            ) * 0.8f;
            ++slot.position;
            if (slot.position >= slot.frames) slot.playing = false;
        }
        if (engine->beatFXOn || engine->beatFXTail) {
            const float extraSignal = mixed - channelSignals[0] - channelSignals[1];
            if (engine->beatFXAssign == 0) {
                channelSignals[0] = processBeatFX(engine, channelSignals[0]);
                mixed = channelSignals[0] + channelSignals[1] + extraSignal;
            } else if (engine->beatFXAssign == 1) {
                channelSignals[1] = processBeatFX(engine, channelSignals[1]);
                mixed = channelSignals[0] + channelSignals[1] + extraSignal;
            } else if (engine->beatFXAssign == 2) {
                mixed = processBeatFX(engine, channelSignals[0] + channelSignals[1]) + extraSignal;
            } else {
                mixed = processBeatFX(engine, mixed);
            }
        }
        const float output = processLimiter(engine, mixed * master);
        const float outputPeak = std::fabs(output);
        if (outputPeak > masterPeak) masterPeak = outputPeak;
        if (left) left[frame] = output;
        if (right) right[frame] = output;
    }

    for (int deckIndex = 0; deckIndex < 2; ++deckIndex) {
        pushPlayheadEvent(engine, deckIndex);
        pushPeakEvent(engine, deckIndex, deckPeaks[deckIndex]);
    }
    pushPeakEvent(engine, -1, masterPeak);
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
    float channelGains[2] = {
        engine->control.trim[0].load(std::memory_order_relaxed) *
            engine->control.fader[0].load(std::memory_order_relaxed) * gainA,
        engine->control.trim[1].load(std::memory_order_relaxed) *
            engine->control.fader[1].load(std::memory_order_relaxed) * gainB
    };
    for (int deckIndex = 0; deckIndex < 2; ++deckIndex) {
        const float assignment = engine->control.xfadeAssign[deckIndex].load(std::memory_order_relaxed);
        const float assignedGain = assignment < 0.5f ? gainA :
            (assignment < 1.5f ? gainB : (deckIndex == 0 ? gainA : gainB));
        channelGains[deckIndex] = engine->control.trim[deckIndex].load(std::memory_order_relaxed) *
            engine->control.fader[deckIndex].load(std::memory_order_relaxed) * assignedGain;
    }
    const float cueGains[2] = {
        engine->control.trim[0].load(std::memory_order_relaxed) *
            engine->control.fader[0].load(std::memory_order_relaxed),
        engine->control.trim[1].load(std::memory_order_relaxed) *
            engine->control.fader[1].load(std::memory_order_relaxed)
    };

    for (int frame = 0; frame < frames; ++frame) {
        float cueSignal = 0.0f;
        float masterSignal = 0.0f;
        for (int deckIndex = 0; deckIndex < 2; ++deckIndex) {
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
        const float output = ((1.0f - mix) * cueSignal + mix * masterSignal) * headphoneLevel;
        if (left) left[frame] = output;
        if (right) right[frame] = output;
    }
}

} // namespace

extern "C" {

pe_engine* pe_create(double sample_rate, int max_frames) {
    if (!(sample_rate > 0.0) || max_frames <= 0) return nullptr;
    return new (std::nothrow) pe_engine{sample_rate, max_frames};
}

void pe_destroy(pe_engine* engine) {
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
    for (int index = 0; index < 2; ++index) {
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
        const float ratio = control->deck_time_ratio[index];
        engine->control.deckTimeRatio[index].store(
            std::isfinite(ratio) && ratio > 0.0f ? ratio : 1.0f,
            std::memory_order_relaxed
        );
        engine->control.deckPitch[index].store(control->deck_pitch[index], std::memory_order_relaxed);
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
    if (!engine || !validDeck(deck) || !channels || channel_count <= 0 || frames < 0 || !(sample_rate > 0.0)) return;
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

void pe_render(pe_engine* engine, float* left, float* right, int frames) {
    render(engine, left, right, frames);
}

void pe_render_monitor(pe_engine* engine, float* left, float* right, int frames) {
    renderMonitor(engine, left, right, frames);
}

void pe_step(pe_engine* engine, float* left, float* right, int frames) {
    render(engine, left, right, frames);
}

} // extern "C"
