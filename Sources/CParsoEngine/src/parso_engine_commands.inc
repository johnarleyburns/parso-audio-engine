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
            if (command.i0 != 0) {
                deck.jogTouched = true;
                deck.jogAudioPosition = deck.position;
                deck.jogTargetPosition = deck.position;
                deck.jogBlendFrames = 0;
                deck.jogAudioInitialized = true;
                if (deck.playing) {
                    deck.playing = false;
                    deck.motorTarget = 0.0f;   // brake to a stop (Vinyl Speed Adjust)
                    if (deck.brakeSeconds <= 0.0001f) deck.motorLevel = 0.0f;
                    pushStateEvent(engine, command.deck);
                }
            }
            break;
        case PE_CMD_JOG_MOVE:
            if (std::isfinite(command.f0) && deck.frames > 0) {
                if (deck.jogTouched) {
                    // Keep the logical playhead responsive for UI, but slew the
                    // audio reader to the new platter target. Applying the delta
                    // immediately and then replaying it as velocity caused a
                    // discontinuity at every scratch direction change.
                    deck.jogTargetPosition += static_cast<double>(command.f0);
                    if (deck.jogTargetPosition < 0.0) deck.jogTargetPosition = 0.0;
                    if (deck.jogTargetPosition > static_cast<double>(deck.frames - 1)) {
                        deck.jogTargetPosition = static_cast<double>(deck.frames - 1);
                    }
                    deck.position = deck.jogTargetPosition;
                    deck.shadowPosition = deck.position;
                    // A brief two-millisecond slew removes the seek edge while
                    // preserving the punch and timing of a hand-driven scratch.
                    deck.jogBlendFrames = std::max(1, static_cast<int>(deck.sampleRate * 0.002));
                } else {
                    deck.position += static_cast<double>(command.f0);
                    if (deck.position < 0.0) deck.position = 0.0;
                    if (deck.position > static_cast<double>(deck.frames)) {
                        deck.position = static_cast<double>(deck.frames);
                    }
                    deck.shadowPosition = deck.position;
                }
                pushPlayheadEvent(engine, command.deck);
            }
            break;
        case PE_CMD_JOG_RELEASE:
            if (deck.jogTouched && deck.jogAudioInitialized) {
                deck.position = deck.jogAudioPosition;
                deck.shadowPosition = deck.position;
            }
            deck.jogTouched = false;
            deck.jogBlendFrames = 0;
            deck.jogAudioInitialized = false;
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
