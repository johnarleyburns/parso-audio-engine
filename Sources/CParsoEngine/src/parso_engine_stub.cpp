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

struct DeckState {
    const float* channels[2] = {nullptr, nullptr};
    int channelCount = 0;
    int64_t frames = 0;
    double sampleRate = 0.0;
    double position = 0.0;
    bool playing = false;
};

struct CommandQueue {
    pe_command commands[kCommandCapacity]{};
    std::atomic<uint32_t> writeIndex{0};
    std::atomic<uint32_t> readIndex{0};
};

struct ControlState {
    std::atomic<float> crossfader{0.0f};
    std::atomic<float> curve{0.0f};
    std::atomic<float> masterLevel{0.8f};
    std::atomic<float> fader[2]{{1.0f}, {1.0f}};
    std::atomic<float> trim[2]{{0.5f}, {0.5f}};
};

} // namespace

struct pe_engine {
    double sampleRate;
    int maxFrames;
    DeckState decks[2];
    ControlState control;
    CommandQueue queue;
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

static void applyCommand(pe_engine* engine, const pe_command& command) {
    if (!validDeck(command.deck)) return;
    DeckState& deck = engine->decks[command.deck];
    switch (command.type) {
        case PE_CMD_PLAY:
            deck.playing = true;
            break;
        case PE_CMD_PAUSE:
            deck.playing = false;
            break;
        case PE_CMD_SET_CUE:
        case PE_CMD_JUMP_CUE:
        case PE_CMD_HOTCUE_SET:
        case PE_CMD_HOTCUE_JUMP:
        case PE_CMD_HOTCUE_DELETE:
        case PE_CMD_LOOP_IN:
        case PE_CMD_LOOP_OUT:
        case PE_CMD_RELOOP_EXIT:
        case PE_CMD_BEATLOOP:
        case PE_CMD_LOOP_SCALE:
        case PE_CMD_BEATJUMP:
        case PE_CMD_SYNC:
        case PE_CMD_SET_MASTER:
        case PE_CMD_SET_KEYLOCK:
        case PE_CMD_SET_SLIP:
        case PE_CMD_JOG_TOUCH:
        case PE_CMD_JOG_MOVE:
        case PE_CMD_JOG_RELEASE:
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
    const float channelGains[2] = {
        engine->control.trim[0].load(std::memory_order_relaxed) *
            engine->control.fader[0].load(std::memory_order_relaxed) * gainA,
        engine->control.trim[1].load(std::memory_order_relaxed) *
            engine->control.fader[1].load(std::memory_order_relaxed) * gainB
    };

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
            deck.position += deck.sampleRate / engine->sampleRate;
            if (deck.position >= static_cast<double>(deck.frames)) {
                deck.position = static_cast<double>(deck.frames);
                deck.playing = false;
            }
        }
        const float output = mixed * master;
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
    for (int index = 0; index < 2; ++index) {
        engine->control.trim[index].store(control->trim[index], std::memory_order_relaxed);
        engine->control.fader[index].store(control->fader[index], std::memory_order_relaxed);
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

int pe_poll_events(pe_engine*, pe_event*, int) {
    return 0;
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
    state.playing = false;
}

void pe_sampler_set_slot(pe_engine*, int, const float* const*, int, int64_t) {}

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
