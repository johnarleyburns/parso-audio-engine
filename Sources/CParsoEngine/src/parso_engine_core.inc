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

// Four-point Catmull-Rom/Hermite interpolation for varispeed and vinyl
// scratching. The endpoint clamps keep the reader allocation-free and avoid
// the edge overshoot that a wrapped table lookup would introduce at a cue or
// track boundary. Normal transport keeps the cheaper linear reader below.
static float sampleAtScratch(const DeckState& deck, int channel, double position) {
    if (deck.frames <= 0 || channel < 0 || channel >= deck.channelCount || !deck.channels[channel]) {
        return 0.0f;
    }
    if (position <= 0.0) return deck.channels[channel][0];
    const int64_t last = deck.frames - 1;
    if (position >= static_cast<double>(last)) return deck.channels[channel][last];

    const int64_t center = static_cast<int64_t>(position);
    const int64_t p0 = center > 0 ? center - 1 : 0;
    const int64_t p1 = center;
    const int64_t p2 = center + 1 < last ? center + 1 : last;
    const int64_t p3 = center + 2 < last ? center + 2 : last;
    const float a = deck.channels[channel][p0];
    const float b = deck.channels[channel][p1];
    const float c = deck.channels[channel][p2];
    const float d = deck.channels[channel][p3];
    const float t = static_cast<float>(position - static_cast<double>(center));
    const float c0 = -0.5f * a + 1.5f * b - 1.5f * c + 0.5f * d;
    const float c1 = a - 2.5f * b + 2.0f * c - 0.5f * d;
    const float c2 = -0.5f * a + 0.5f * c;
    return ((c0 * t + c1) * t + c2) * t + b;
}

static float sampleAtScratch(const StemVoice& voice, int channel, double position) {
    if (!voice.present || voice.frames <= 0 || channel < 0 || channel >= voice.channelCount ||
        !voice.channels[channel]) {
        return 0.0f;
    }
    if (position <= 0.0) return voice.channels[channel][0];
    const int64_t last = voice.frames - 1;
    if (position >= static_cast<double>(last)) return voice.channels[channel][last];

    const int64_t center = static_cast<int64_t>(position);
    const int64_t p0 = center > 0 ? center - 1 : 0;
    const int64_t p1 = center;
    const int64_t p2 = center + 1 < last ? center + 1 : last;
    const int64_t p3 = center + 2 < last ? center + 2 : last;
    const float a = voice.channels[channel][p0];
    const float b = voice.channels[channel][p1];
    const float c = voice.channels[channel][p2];
    const float d = voice.channels[channel][p3];
    const float t = static_cast<float>(position - static_cast<double>(center));
    const float c0 = -0.5f * a + 1.5f * b - 1.5f * c + 0.5f * d;
    const float c1 = a - 2.5f * b + 2.0f * c - 0.5f * d;
    const float c2 = -0.5f * a + 0.5f * c;
    return ((c0 * t + c1) * t + c2) * t + b;
}

// Channel faders are continuous controls. Smoothing them on the render thread
// keeps scratch clicks musically percussive instead of turning a control jump
// into a full-scale sample discontinuity. The first render adopts the current
// target exactly so a newly-created engine does not fade in unexpectedly.
static float smoothedChannelFader(pe_engine* engine, int deckIndex) {
    DeckState& deck = engine->decks[deckIndex];
    const float rawTarget = engine->control.fader[deckIndex].load(std::memory_order_relaxed);
    const float target = std::isfinite(rawTarget)
        ? std::max(0.0f, std::min(1.0f, rawTarget)) : 0.0f;
    if (!deck.faderInitialized) {
        deck.smoothedFader = target;
        deck.faderInitialized = true;
        return target;
    }
    const float sampleRate = static_cast<float>(engine->sampleRate);
    // Human channel moves get a musical 10 ms glide. During a vinyl scratch,
    // fader clicks are part of the technique, so use a much shorter cut ramp
    // while still avoiding a discontinuous full-scale multiplication step.
    const float smoothingSeconds = deck.jogTouched && deck.jogVinylMode ? 0.002f : 0.010f;
    const float smoothing = 1.0f - std::exp(-1.0f / (sampleRate * smoothingSeconds));
    deck.smoothedFader += smoothing * (target - deck.smoothedFader);
    return deck.smoothedFader;
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
