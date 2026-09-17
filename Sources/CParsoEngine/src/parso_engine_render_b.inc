static void applyScheduledTransition(pe_engine* engine) {
    if (engine->transitionActive.load(std::memory_order_acquire) == 0) return;
    const int64_t start = engine->transitionStart.load(std::memory_order_relaxed);
    const int64_t end = engine->transitionEnd.load(std::memory_order_relaxed);
    const int64_t frame = engine->masterFrame.load(std::memory_order_relaxed);
    if (end <= start || frame < start) return;
    const int out = engine->transitionOutgoing.load(std::memory_order_relaxed);
    const int in = engine->transitionIncoming.load(std::memory_order_relaxed);
    if (!validDeck(engine, out) || !validDeck(engine, in) || out == in) {
        engine->transitionActive.store(0, std::memory_order_release);
        return;
    }
    const double p = std::max(0.0, std::min(1.0,
        static_cast<double>(frame - start) / static_cast<double>(end - start)));
    const double eased = 0.5 - 0.5 * std::cos(kPi * p);
    const float startX = out <= in ? -1.0f : 1.0f;
    const float endX = -startX;
    engine->control.crossfader.store(
        static_cast<float>(startX + (endX - startX) * eased), std::memory_order_relaxed);
    const int technique = std::max(0, std::min(4,
        engine->transitionTechnique.load(std::memory_order_relaxed)));
    const double incomingWindow = technique == 4 ? 0.35 : 0.60;
    const double incoming = std::min(1.0, p / incomingWindow);
    const double outgoing = p > 0.60 ? (p - 0.60) / 0.40 : 0.0;
    engine->control.eqLow[in].store(static_cast<float>(incoming >= 1.0 ? 0.0 : -24.0 * (1.0 - incoming)),
                                    std::memory_order_relaxed);
    engine->control.eqLow[out].store(static_cast<float>(-24.0 * outgoing),
                                     std::memory_order_relaxed);
    if (p >= 0.70 && engine->transitionTail.load(std::memory_order_relaxed) != 0) {
        engine->control.beatFXKind.store(
            engine->transitionTail.load(std::memory_order_relaxed) == 1 ? 0.0f : 2.0f,
            std::memory_order_relaxed);
        engine->control.beatFXAssign.store(out == 0 ? 0.0f : (out == 1 ? 1.0f : 3.0f),
                                           std::memory_order_relaxed);
        engine->control.beatFXDepth.store(0.6f, std::memory_order_relaxed);
        engine->control.beatFXOn.store(1.0f, std::memory_order_relaxed);
    }
    if (p >= 1.0) {
        engine->control.eqLow[in].store(0.0f, std::memory_order_relaxed);
        engine->control.eqLow[out].store(0.0f, std::memory_order_relaxed);
        engine->transitionActive.store(0, std::memory_order_release);
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
    applyScheduledTransition(engine);

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
            assignedGain;
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
        const float trim = engine->control.trim[deckIndex].load(std::memory_order_relaxed);
        channelGains[deckIndex] = trim * assignedGain;
        cueGains[deckIndex] = trim;
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
            const float fader = smoothedChannelFader(engine, deckIndex);
            masterSignal += sample * channelGains[deckIndex] * fader;
            if (engine->control.cuePFL[deckIndex].load(std::memory_order_relaxed) > 0.5f) {
                cueSignal += sample * cueGains[deckIndex] * fader;
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
