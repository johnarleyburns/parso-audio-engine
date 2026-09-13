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
