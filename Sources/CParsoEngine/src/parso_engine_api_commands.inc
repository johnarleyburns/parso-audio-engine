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
    state.jogTouched = false;
    state.jogVinylMode = false;
    state.jogVelocity = 0.0;
    state.jogPressure = 1.0;
    state.jogAudioPosition = 0.0;
    state.jogTargetPosition = 0.0;
    state.jogAudioInitialized = false;
    state.smoothedFader = 1.0f;
    state.faderInitialized = false;
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
