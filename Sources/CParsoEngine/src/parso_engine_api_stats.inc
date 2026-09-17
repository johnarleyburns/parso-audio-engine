void pe_get_stats(pe_engine* engine, pe_stats* out) {
    if (!engine || !out) return;
    out->master_frame = engine->masterFrame.load(std::memory_order_relaxed);
    out->master_bpm = engine->control.masterBpm.load(std::memory_order_relaxed);
    out->downbeat_phase = engine->control.downbeatPhase.load(std::memory_order_relaxed);
    out->render_load = engine->renderLoad.load(std::memory_order_relaxed);
    out->starved_frames = engine->starvedFrames.load(std::memory_order_relaxed);
    for (int i = 0; i < PE_MAX_DECKS; ++i) {
        out->deck_effective_bpm[i] = engine->decks[i].effectiveBpm;
        out->deck_beat_phase[i] = engine->decks[i].beatPhase;
        out->deck_synced[i] = engine->decks[i].synced ? 1 : 0;
    }
}

void pe_set_master_clock(pe_engine* engine, int32_t master_deck, double master_bpm,
                         double downbeat_phase) {
    if (!engine) return;
    engine->control.masterDeck.store(master_deck, std::memory_order_relaxed);
    engine->control.masterBpm.store(std::isfinite(master_bpm) && master_bpm > 0 ? master_bpm : 0.0,
                                    std::memory_order_relaxed);
    engine->control.downbeatPhase.store(
        std::isfinite(downbeat_phase) ? downbeat_phase - std::floor(downbeat_phase) : 0.0,
        std::memory_order_relaxed);
}

void pe_set_deck_sync(pe_engine* engine, int deck, int synced, double effective_bpm,
                      double beat_phase) {
    if (!engine || !validDeck(engine, deck)) return;
    DeckState& d = engine->decks[deck];
    d.synced = synced != 0;
    d.effectiveBpm = std::isfinite(effective_bpm) && effective_bpm > 0 ? effective_bpm : 0.0;
    d.beatPhase = std::isfinite(beat_phase) ? beat_phase - std::floor(beat_phase) : 0.0;
    d.echoBpm = d.effectiveBpm > 0 ? d.effectiveBpm : d.echoBpm;
}

void pe_schedule_transition(pe_engine* engine, int outgoing_deck, int incoming_deck,
                            int64_t outgoing_anchor, int64_t incoming_anchor,
                            int64_t start_master_frame, int64_t end_master_frame,
                            int technique, int tail) {
    if (!engine || !validDeck(engine, outgoing_deck) || !validDeck(engine, incoming_deck) ||
        outgoing_deck == incoming_deck || end_master_frame <= start_master_frame) return;
    engine->transitionOutgoing.store(outgoing_deck, std::memory_order_relaxed);
    engine->transitionIncoming.store(incoming_deck, std::memory_order_relaxed);
    engine->transitionOutgoingAnchor.store(outgoing_anchor, std::memory_order_relaxed);
    engine->transitionIncomingAnchor.store(incoming_anchor, std::memory_order_relaxed);
    engine->transitionTechnique.store(std::max(0, std::min(4, technique)), std::memory_order_relaxed);
    engine->transitionTail.store(std::max(0, std::min(2, tail)), std::memory_order_relaxed);
    engine->transitionStart.store(start_master_frame, std::memory_order_relaxed);
    engine->transitionEnd.store(end_master_frame, std::memory_order_relaxed);
    engine->transitionActive.store(1, std::memory_order_release);
}

void pe_cancel_transition(pe_engine* engine) {
    if (!engine) return;
    engine->transitionActive.store(0, std::memory_order_release);
}

void pe_record_set_active(pe_engine* engine, int active) {
    if (!engine) return;
    engine->recordActive.store(active != 0 ? 1 : 0, std::memory_order_relaxed);
}

int pe_record_drain(pe_engine* engine, float* out_l, float* out_r, int max_frames) {
    if (!engine || max_frames <= 0) return 0;
    const uint32_t cap = pe_engine::kRecordCapacity;
    uint32_t read = engine->recordRead.load(std::memory_order_relaxed);
    const uint32_t write = engine->recordWrite.load(std::memory_order_acquire);
    int count = 0;
    while (read != write && count < max_frames) {
        if (out_l) out_l[count] = engine->recordLeft[read % cap];
        if (out_r) out_r[count] = engine->recordRight[read % cap];
        ++read;
        ++count;
    }
    engine->recordRead.store(read, std::memory_order_release);
    return count;
}

int64_t pe_record_dropped_frames(pe_engine* engine) {
    return engine ? engine->recordDropped.load(std::memory_order_relaxed) : 0;
}

void pe_record_reset(pe_engine* engine) {
    if (!engine) return;
    engine->recordRead.store(engine->recordWrite.load(std::memory_order_acquire),
                             std::memory_order_release);
    engine->recordDropped.store(0, std::memory_order_relaxed);
}

void pe_render(pe_engine* engine, float* left, float* right, int frames) {
    render(engine, left, right, frames);
}

void pe_render_monitor(pe_engine* engine, float* left, float* right, int frames) {
    renderMonitor(engine, left, right, frames);
}

void pe_master_convolution_ir(pe_engine* engine, const float* ir, int ir_len) {
    if (!engine || !engine->masterConv) return;
    pd_conv_set_ir(engine->masterConv, ir, ir_len);
}

void pe_render_booth(pe_engine* engine, float* left, float* right, int frames) {
    if (!engine || frames <= 0) { clearOutput(left, right, frames); return; }
    const float level = engine->control.boothLevel.load(std::memory_order_relaxed);
    pd_eq3_set(engine->boothEq,
               engine->control.boothEqLow.load(std::memory_order_relaxed),
               engine->control.boothEqMid.load(std::memory_order_relaxed),
               engine->control.boothEqHigh.load(std::memory_order_relaxed));
    const int n = std::min({frames, engine->boothFrames, pe_engine::kBoothCapacity});
    for (int f = 0; f < frames; ++f) {
        const float l = f < n ? engine->boothLeft[f] * level : 0.0f;
        const float r = f < n ? engine->boothRight[f] * level : 0.0f;
        if (left) left[f] = l;
        if (right) right[f] = r;
    }
    // Booth EQ on the (mono) booth bus: filter left, mirror to right.
    if (left) {
        pd_eq3_process(engine->boothEq, left, left, frames);
        if (right && right != left) for (int f = 0; f < frames; ++f) right[f] = left[f];
    } else if (right) {
        pd_eq3_process(engine->boothEq, right, right, frames);
    }
}

void pe_step(pe_engine* engine, float* left, float* right, int frames) {
    render(engine, left, right, frames);
}

void pe_set_insert(pe_engine* engine, int point, pe_insert_fn fn, void* ctx) {
    if (!engine || point < 0 || point >= PE_INSERT_COUNT) return;
    if (!fn) {
        engine->insertFn[point].store(nullptr, std::memory_order_release);
        engine->insertCtx[point].store(nullptr, std::memory_order_relaxed);
        return;
    }
    engine->insertCtx[point].store(ctx, std::memory_order_relaxed);
    engine->insertFn[point].store(fn, std::memory_order_release);
}

} // extern "C"
