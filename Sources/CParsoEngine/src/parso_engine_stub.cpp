// CParsoEngine's allocation-free two-deck render core.
// Control-side setup may allocate the handle; pe_render/pe_step only consume
// resident caller-owned PCM and fixed-size command/control state.
#include "parso_engine.h"

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
    std::atomic<float> micLevel{0.0f};
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
        case PE_CMD_BEATFX_KIND:
        case PE_CMD_BEATFX_ONOFF:
        case PE_CMD_BEATFX_RELEASE:
        case PE_CMD_SAMPLER_TRIGGER:
        case PE_CMD_SAMPLER_STOP:
        case PE_CMD_LOAD:
            // These commands are reserved for subsequent engine slices;
            // ignoring them is deterministic and non-blocking.
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

static void render(pe_engine* engine, float* left, float* right, int frames) {
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
    const float master = engine->control.masterLevel.load(std::memory_order_relaxed);
    const float micLevel = engine->control.micLevel.load(std::memory_order_relaxed);
    const float channelGains[2] = {
        engine->control.trim[0].load(std::memory_order_relaxed) *
            engine->control.fader[0].load(std::memory_order_relaxed) * gainA,
        engine->control.trim[1].load(std::memory_order_relaxed) *
            engine->control.fader[1].load(std::memory_order_relaxed) * gainB
    };

    float deckPeaks[2] = {0.0f, 0.0f};
    float masterPeak = 0.0f;
    for (int frame = 0; frame < frames; ++frame) {
        float mixed = 0.0f;
        for (int deckIndex = 0; deckIndex < 2; ++deckIndex) {
            DeckState& deck = engine->decks[deckIndex];
            if (!deck.playing || deck.frames <= 0 || deck.sampleRate <= 0.0) continue;
            const double sourcePosition = deck.position;
            const int rightChannel = deck.channelCount > 1 ? 1 : 0;
            const float sample = 0.5f * (
                sampleAt(deck, 0, sourcePosition) + sampleAt(deck, rightChannel, sourcePosition)
            );
            mixed += sample * channelGains[deckIndex];
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
        if (micLevel > 0.0f && engine->mic.frames > 0 && engine->mic.sampleRate > 0.0) {
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
        const float output = mixed * master;
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
    engine->control.micLevel.store(
        std::isfinite(control->mic_level) && control->mic_level >= 0.0f ? control->mic_level : 0.0f,
        std::memory_order_relaxed
    );
    for (int index = 0; index < 2; ++index) {
        engine->control.trim[index].store(control->trim[index], std::memory_order_relaxed);
        engine->control.fader[index].store(control->fader[index], std::memory_order_relaxed);
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
    render(engine, left, right, frames);
}

void pe_step(pe_engine* engine, float* left, float* right, int frames) {
    render(engine, left, right, frames);
}

} // extern "C"
