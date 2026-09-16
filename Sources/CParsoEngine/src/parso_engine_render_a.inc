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
            const bool scratching = deck.jogTouched && deck.jogVinylMode;
            const bool jogBending = deck.jogTouched && !deck.jogVinylMode;
            if ((!deck.playing && !coasting && !scratching) || deck.frames <= 0 || deck.sampleRate <= 0.0) {
                dry[deckIndex][frame] = 0.0f;
                continue;
            }
            if (scratching && std::fabs(deck.jogVelocity) < 0.0001) {
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
                    const double readerPosition = scratching && deck.jogAudioInitialized
                        ? deck.jogAudioPosition : deck.position;
                    const double pos = std::min(readerPosition, static_cast<double>(v.frames - 1));
                    const int64_t lower = static_cast<int64_t>(pos < 0.0 ? 0.0 : pos);
                    const int64_t upper = lower + 1 < v.frames ? lower + 1 : lower;
                    const float frac = static_cast<float>(pos - static_cast<double>(lower));
                    const float voiceLeft = scratching
                        ? sampleAtScratch(v, 0, pos)
                        : v.channels[0][lower] + (v.channels[0][upper] - v.channels[0][lower]) * frac;
                    const float voiceRight = scratching
                        ? sampleAtScratch(v, rc, pos)
                        : v.channels[rc][lower] + (v.channels[rc][upper] - v.channels[rc][lower]) * frac;
                    summed += 0.5f * (voiceLeft + voiceRight) * v.smoothedGain;
                }
                dry[deckIndex][frame] = summed;
            } else {
                const int rightChannel = deck.channelCount > 1 ? 1 : 0;
                const double readerPosition = scratching && deck.jogAudioInitialized
                    ? deck.jogAudioPosition : deck.position;
                dry[deckIndex][frame] = 0.5f * (
                    (scratching ? sampleAtScratch(deck, 0, readerPosition)
                                : sampleAt(deck, 0, readerPosition)) +
                    (scratching ? sampleAtScratch(deck, rightChannel, readerPosition)
                                : sampleAt(deck, rightChannel, readerPosition))
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
            const double bendRatio = jogBending ? 1.0 + deck.jogVelocity : 1.0;
            const double positionIncrement = scratching
                ? 0.0
                : (deck.reverse ? -forwardIncrement : forwardIncrement) * motor * bendRatio;
            deck.position += positionIncrement;
            if (scratching) {
                // Keep the platter moving for the duration of a gesture. A
                // short decay makes each hand stroke audible without turning
                // the control event itself into a permanent tone.
                deck.jogAudioPosition += deck.jogVelocity;
                deck.jogVelocity *= 0.9997;
                if (std::fabs(deck.jogVelocity) < 0.0001) deck.jogVelocity = 0.0;
                if (deck.jogAudioPosition < 0.0) deck.jogAudioPosition = 0.0;
                if (deck.jogAudioPosition > static_cast<double>(deck.frames - 1)) {
                    deck.jogAudioPosition = static_cast<double>(deck.frames - 1);
                }
                continue;
            }
            if (jogBending) {
                // Let the pitch bend return smoothly to neutral between touch
                // updates, matching a physical jog wheel's spring response.
                deck.jogVelocity *= 0.9997;
                if (std::fabs(deck.jogVelocity) < 0.0001) deck.jogVelocity = 0.0;
            }
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
            channelSignals[deckIndex] = sample * channelGains[deckIndex] *
                smoothedChannelFader(engine, deckIndex);
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
