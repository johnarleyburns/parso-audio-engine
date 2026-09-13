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
