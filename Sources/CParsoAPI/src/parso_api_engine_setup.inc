PARSO_API parso_status_t parso_engine_options_init(parso_engine_options_t *options) {
    if (!options) return fail(PARSO_STATUS_INVALID_ARGUMENT, "options is null");
    std::memset(options, 0, sizeof(*options));
    options->size = sizeof(*options);
    options->abi_version = PARSO_ABI_VERSION;
    options->sample_rate_hz = 48000;
    options->max_frames = 512;
    options->deck_count = 2;
    options->isolator_profile = PARSO_ISOLATOR_PROFILE_GENERIC;
    return PARSO_STATUS_OK;
}

PARSO_API parso_status_t parso_control_init(parso_control_t *control) {
    if (!control) return fail(PARSO_STATUS_INVALID_ARGUMENT, "control is null");
    std::memset(control, 0, sizeof(*control));
    control->size = sizeof(*control);
    control->abi_version = PARSO_ABI_VERSION;
    control->master_level = 0.8f;
    control->limiter_ceiling_db = -0.3f;
    control->limiter_enabled = 1.0f;
    control->beatfx_beats = 0.5f;
    control->beatfx_depth = 0.5f;
    control->beatfx_xpad = -1.0f;
    control->master_reverb_size = 0.6f;
    control->master_reverb_decay = 0.6f;
    control->master_reverb_damp = 0.5f;
    control->master_eq_low = 0.0f;
    control->master_eq_mid = 0.0f;
    control->master_eq_high = 0.0f;
    control->mic_talkover_depth_db = -14.0f;
    control->cue_master_mix = 0.5f;
    control->headphone_level = 0.7f;
    control->booth_level = 0.8f;
    for (uint32_t index = 0; index < PARSO_MAX_DECKS; ++index) {
        control->xfade_assign[index] = 2.0f;
        control->fader[index] = 1.0f;
        control->trim[index] = 0.5f;
        control->color_param[index] = 0.5f;
        control->deck_time_ratio[index] = 1.0f;
        control->deck_pitch[index] = 0.0f;
        control->deck_keylock[index] = 0.0f;
    }
    return PARSO_STATUS_OK;
}

PARSO_API parso_status_t parso_pcm_view_init(parso_pcm_view_t *view) {
    if (!view) return fail(PARSO_STATUS_INVALID_ARGUMENT, "PCM view is null");
    std::memset(view, 0, sizeof(*view));
    view->size = sizeof(*view);
    view->abi_version = PARSO_ABI_VERSION;
    return PARSO_STATUS_OK;
}

PARSO_API parso_status_t parso_output_view_init(parso_output_view_t *view) {
    if (!view) return fail(PARSO_STATUS_INVALID_ARGUMENT, "output view is null");
    std::memset(view, 0, sizeof(*view));
    view->size = sizeof(*view);
    view->abi_version = PARSO_ABI_VERSION;
    return PARSO_STATUS_OK;
}

PARSO_API parso_status_t parso_command_init(parso_command_t *command) {
    if (!command) return fail(PARSO_STATUS_INVALID_ARGUMENT, "command is null");
    std::memset(command, 0, sizeof(*command));
    command->size = sizeof(*command);
    command->abi_version = PARSO_ABI_VERSION;
    command->deck = -1;
    return PARSO_STATUS_OK;
}

PARSO_API parso_status_t parso_stats_init(parso_stats_t *stats) {
    if (!stats) return fail(PARSO_STATUS_INVALID_ARGUMENT, "stats is null");
    std::memset(stats, 0, sizeof(*stats));
    stats->size = sizeof(*stats);
    stats->abi_version = PARSO_ABI_VERSION;
    return PARSO_STATUS_OK;
}

PARSO_API parso_status_t parso_event_init(parso_event_t *event) {
    if (!event) return fail(PARSO_STATUS_INVALID_ARGUMENT, "event is null");
    std::memset(event, 0, sizeof(*event));
    event->size = sizeof(*event);
    event->abi_version = PARSO_ABI_VERSION;
    event->deck = -1;
    return PARSO_STATUS_OK;
}

PARSO_API parso_status_t parso_engine_create(
    const parso_engine_options_t *options,
    parso_engine_t **out_engine
) {
    try {
        if (!options || !out_engine) return fail(PARSO_STATUS_INVALID_ARGUMENT, "create arguments are null");
        *out_engine = nullptr;
        const parso_status_t headerStatus = checkHeader(
            options->size, options->abi_version, kMinimumOptionsSize
        );
        if (headerStatus != PARSO_STATUS_OK) return headerStatus;
        if (!finitePositive(options->sample_rate_hz) || options->max_frames == 0 ||
            options->deck_count < 2 || options->deck_count > PARSO_MAX_DECKS ||
            options->isolator_profile > PARSO_ISOLATOR_PROFILE_WARM2) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "invalid engine options");
        }
        pe_engine *internal = pe_create_with_isolator_profile(
            static_cast<double>(options->sample_rate_hz),
            static_cast<int>(options->max_frames),
            static_cast<int>(options->deck_count),
            options->isolator_profile == PARSO_ISOLATOR_PROFILE_WARM2
                ? PE_ISOLATOR_PROFILE_WARM2 : PE_ISOLATOR_PROFILE_GENERIC
        );
        if (!internal) return fail(PARSO_STATUS_OUT_OF_MEMORY, "native engine creation failed");
        parso_engine_t *publicHandle = new (std::nothrow) parso_engine_t;
        if (!publicHandle) {
            pe_destroy(internal);
            return fail(PARSO_STATUS_OUT_OF_MEMORY, "public engine handle allocation failed");
        }
        publicHandle->handle.engine = internal;
        publicHandle->handle.maxFrames = options->max_frames;
        publicHandle->handle.deckCount = options->deck_count;
        *out_engine = publicHandle;
        lastError = "ok";
        return PARSO_STATUS_OK;
    } catch (const std::bad_alloc &) {
        return fail(PARSO_STATUS_OUT_OF_MEMORY, "allocation failed at C boundary");
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught at C boundary");
    }
}

PARSO_API parso_status_t parso_engine_destroy(parso_engine_t **engine) {
    try {
        if (!engine) return fail(PARSO_STATUS_INVALID_ARGUMENT, "engine pointer is null");
        if (!*engine) {
            lastError = "ok";
            return PARSO_STATUS_OK;
        }
        pe_destroy((*engine)->handle.engine);
        (*engine)->handle.engine = nullptr;
        delete *engine;
        *engine = nullptr;
        lastError = "ok";
        return PARSO_STATUS_OK;
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while destroying engine");
    }
}

PARSO_API parso_status_t parso_engine_set_control(
    parso_engine_t *engine,
    const parso_control_t *control
) {
    try {
        if (validateEngine(engine ? &engine->handle : nullptr) != PARSO_STATUS_OK) return PARSO_STATUS_CLOSED;
        const parso_status_t controlStatus = validateControl(control);
        if (controlStatus != PARSO_STATUS_OK) return controlStatus;
        pe_control nativeControl;
        defaultControl(nativeControl);
        nativeControl.crossfader = control->crossfader;
        nativeControl.xfade_curve = control->xfade_curve;
        nativeControl.master_level = control->master_level;
        nativeControl.limiter_ceiling_db = control->limiter_ceiling_db;
        nativeControl.limiter_enabled = control->limiter_enabled;
        nativeControl.mic_level = control->mic_level;
        nativeControl.mic_eq_low = control->mic_eq_low;
        nativeControl.mic_eq_high = control->mic_eq_high;
        nativeControl.mic_talkover_on = control->mic_talkover_on;
        nativeControl.mic_talkover_depth_db = control->mic_talkover_depth_db;
        nativeControl.mic_talkover_threshold = control->mic_talkover_threshold;
        nativeControl.mic_fx_on = control->mic_fx_on;
        nativeControl.cue_master_mix = control->cue_master_mix;
        nativeControl.master_cue = control->master_cue;
        nativeControl.headphone_level = control->headphone_level;
        nativeControl.booth_level = control->booth_level;
        nativeControl.booth_eq_low = control->booth_eq_low;
        nativeControl.booth_eq_mid = control->booth_eq_mid;
        nativeControl.booth_eq_high = control->booth_eq_high;
        for (uint32_t index = 0; index < PARSO_MAX_DECKS; ++index) {
            nativeControl.xfade_assign[index] = control->xfade_assign[index];
            nativeControl.fader[index] = control->fader[index];
            nativeControl.trim[index] = control->trim[index];
            nativeControl.eq_low[index] = control->eq_low[index];
            nativeControl.eq_mid[index] = control->eq_mid[index];
            nativeControl.eq_high[index] = control->eq_high[index];
            nativeControl.color_amount[index] = control->color_amount[index];
            nativeControl.color_kind[index] = control->color_kind[index];
            nativeControl.color_param[index] = control->color_param[index];
        }
        nativeControl.beatfx_kind = control->beatfx_kind;
        nativeControl.beatfx_beats = control->beatfx_beats;
        nativeControl.beatfx_depth = control->beatfx_depth;
        nativeControl.beatfx_assign = control->beatfx_assign;
        nativeControl.beatfx_on = control->beatfx_on;
        nativeControl.beatfx_xpad = control->beatfx_xpad;
        nativeControl.beatfx_band = control->beatfx_band;
        nativeControl.master_reverb_send = control->master_reverb_send;
        nativeControl.master_reverb_size = control->master_reverb_size;
        nativeControl.master_reverb_decay = control->master_reverb_decay;
        nativeControl.master_reverb_damp = control->master_reverb_damp;
        nativeControl.master_reverb_mode = control->master_reverb_mode;
        nativeControl.master_eq_low = control->master_eq_low;
        nativeControl.master_eq_mid = control->master_eq_mid;
        nativeControl.master_eq_high = control->master_eq_high;
        for (uint32_t index = 0; index < PARSO_MAX_DECKS; ++index) {
            nativeControl.deck_time_ratio[index] = control->deck_time_ratio[index];
            nativeControl.deck_pitch[index] = control->deck_pitch[index];
            nativeControl.deck_keylock[index] = control->deck_keylock[index];
            nativeControl.cue_pfl[index] = control->cue_pfl[index];
            nativeControl.fader_start[index] = control->fader_start[index];
        }
        pe_set_control(engine->handle.engine, &nativeControl);
        lastError = "ok";
        return PARSO_STATUS_OK;
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while setting control");
    }
}

PARSO_API parso_status_t parso_engine_set_deck_buffer(
    parso_engine_t *engine,
    uint32_t deck,
    const parso_pcm_view_t *view
) {
    try {
        if (validateEngine(engine ? &engine->handle : nullptr) != PARSO_STATUS_OK) return PARSO_STATUS_CLOSED;
        if (deck >= engine->handle.deckCount) return fail(PARSO_STATUS_INVALID_ARGUMENT, "deck is out of range");
        const parso_status_t viewStatus = validateView(view);
        if (viewStatus != PARSO_STATUS_OK) return viewStatus;
        if (view->frames > static_cast<uint64_t>(INT64_MAX)) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "PCM frame count exceeds signed 64-bit range");
        }
        pe_deck_set_buffer(
            engine->handle.engine,
            static_cast<int>(deck),
            view->planes,
            static_cast<int>(view->channel_count),
            static_cast<int64_t>(view->frames),
            static_cast<double>(view->sample_rate_hz)
        );
        lastError = "ok";
        return PARSO_STATUS_OK;
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while setting deck buffer");
    }
}

PARSO_API parso_status_t parso_engine_set_stem_buffer(
    parso_engine_t *engine, uint32_t deck, uint32_t voice,
    const parso_pcm_view_t *view
) {
    try {
        if (validateEngine(engine ? &engine->handle : nullptr) != PARSO_STATUS_OK)
            return PARSO_STATUS_CLOSED;
        if (deck >= engine->handle.deckCount || voice >= 4u)
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "stem deck or voice is out of range");
        const parso_status_t viewStatus = validateView(view);
        if (viewStatus != PARSO_STATUS_OK) return viewStatus;
        if (view->frames > static_cast<uint64_t>(INT64_MAX))
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "stem frame count exceeds signed 64-bit range");
        pe_deck_set_stem_buffer(
            engine->handle.engine, static_cast<int>(deck), static_cast<int>(voice),
            view->planes, static_cast<int>(view->channel_count),
            static_cast<int64_t>(view->frames)
        );
        lastError = "ok";
        return PARSO_STATUS_OK;
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while setting stem buffer");
    }
}

PARSO_API parso_status_t parso_engine_clear_stems(
    parso_engine_t *engine, uint32_t deck
) {
    try {
        if (validateEngine(engine ? &engine->handle : nullptr) != PARSO_STATUS_OK)
            return PARSO_STATUS_CLOSED;
        if (deck >= engine->handle.deckCount)
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "stem deck is out of range");
        pe_deck_clear_stems(engine->handle.engine, static_cast<int>(deck));
        lastError = "ok";
        return PARSO_STATUS_OK;
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while clearing stems");
    }
}

PARSO_API parso_status_t parso_engine_set_sampler_slot(
    parso_engine_t *engine, uint32_t slot, const parso_pcm_view_t *view
) {
    try {
        if (validateEngine(engine ? &engine->handle : nullptr) != PARSO_STATUS_OK)
            return PARSO_STATUS_CLOSED;
        if (slot >= 16u) return fail(PARSO_STATUS_INVALID_ARGUMENT, "sampler slot is out of range");
        const parso_status_t viewStatus = validateView(view);
        if (viewStatus != PARSO_STATUS_OK) return viewStatus;
        if (view->frames > static_cast<uint64_t>(INT64_MAX))
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "sampler frame count exceeds signed 64-bit range");
        pe_sampler_set_slot(
            engine->handle.engine, static_cast<int>(slot), view->planes,
            static_cast<int>(view->channel_count), static_cast<int64_t>(view->frames)
        );
        lastError = "ok";
        return PARSO_STATUS_OK;
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while setting sampler slot");
    }
}

PARSO_API parso_status_t parso_engine_set_mic_buffer(
    parso_engine_t *engine,
    const parso_pcm_view_t *view
) {
    try {
        if (validateEngine(engine ? &engine->handle : nullptr) != PARSO_STATUS_OK) return PARSO_STATUS_CLOSED;
        const parso_status_t viewStatus = validateView(view);
        if (viewStatus != PARSO_STATUS_OK) return viewStatus;
        if (view->frames > static_cast<uint64_t>(INT64_MAX)) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "PCM frame count exceeds signed 64-bit range");
        }
        pe_mic_set_buffer(
            engine->handle.engine,
            view->planes,
            static_cast<int>(view->channel_count),
            static_cast<int64_t>(view->frames),
            static_cast<double>(view->sample_rate_hz)
        );
        lastError = "ok";
        return PARSO_STATUS_OK;
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while setting mic buffer");
    }
}

PARSO_API parso_status_t parso_engine_post_command(
    parso_engine_t *engine,
    const parso_command_t *command
) {
    try {
        if (validateEngine(engine ? &engine->handle : nullptr) != PARSO_STATUS_OK) return PARSO_STATUS_CLOSED;
        if (!command) return fail(PARSO_STATUS_INVALID_ARGUMENT, "command is null");
        const parso_status_t headerStatus = checkHeader(
            command->size, command->abi_version, kMinimumCommandSize
        );
        if (headerStatus != PARSO_STATUS_OK) return headerStatus;
        pe_command nativeCommand{};
        switch (command->type) {
            case PARSO_COMMAND_PLAY: nativeCommand.type = PE_CMD_PLAY; break;
            case PARSO_COMMAND_PAUSE: nativeCommand.type = PE_CMD_PAUSE; break;
            case PARSO_COMMAND_SET_CUE: nativeCommand.type = PE_CMD_SET_CUE; break;
            case PARSO_COMMAND_JUMP_CUE: nativeCommand.type = PE_CMD_JUMP_CUE; break;
            case PARSO_COMMAND_HOTCUE_SET: nativeCommand.type = PE_CMD_HOTCUE_SET; break;
            case PARSO_COMMAND_HOTCUE_JUMP: nativeCommand.type = PE_CMD_HOTCUE_JUMP; break;
            case PARSO_COMMAND_HOTCUE_DELETE: nativeCommand.type = PE_CMD_HOTCUE_DELETE; break;
            case PARSO_COMMAND_LOOP_IN: nativeCommand.type = PE_CMD_LOOP_IN; break;
            case PARSO_COMMAND_LOOP_OUT: nativeCommand.type = PE_CMD_LOOP_OUT; break;
            case PARSO_COMMAND_RELOOP_EXIT: nativeCommand.type = PE_CMD_RELOOP_EXIT; break;
            case PARSO_COMMAND_BEATLOOP: nativeCommand.type = PE_CMD_BEATLOOP; break;
            case PARSO_COMMAND_LOOP_SCALE: nativeCommand.type = PE_CMD_LOOP_SCALE; break;
            case PARSO_COMMAND_LOOP_MOVE: nativeCommand.type = PE_CMD_LOOP_MOVE; break;
            case PARSO_COMMAND_SET_LOOP: nativeCommand.type = PE_CMD_SET_LOOP; break;
            case PARSO_COMMAND_SET_LOOP_ACTIVE: nativeCommand.type = PE_CMD_SET_LOOP_ACTIVE; break;
            case PARSO_COMMAND_BEATJUMP: nativeCommand.type = PE_CMD_BEATJUMP; break;
            case PARSO_COMMAND_SYNC: nativeCommand.type = PE_CMD_SYNC; break;
            case PARSO_COMMAND_SET_MASTER: nativeCommand.type = PE_CMD_SET_MASTER; break;
            case PARSO_COMMAND_SET_KEYLOCK: nativeCommand.type = PE_CMD_SET_KEYLOCK; break;
            case PARSO_COMMAND_SET_SLIP: nativeCommand.type = PE_CMD_SET_SLIP; break;
            case PARSO_COMMAND_JOG_TOUCH: nativeCommand.type = PE_CMD_JOG_TOUCH; break;
            case PARSO_COMMAND_JOG_MOVE: nativeCommand.type = PE_CMD_JOG_MOVE; break;
            case PARSO_COMMAND_JOG_RELEASE: nativeCommand.type = PE_CMD_JOG_RELEASE; break;
            case PARSO_COMMAND_SEEK: nativeCommand.type = PE_CMD_SEEK; break;
            case PARSO_COMMAND_UNSYNC: nativeCommand.type = PE_CMD_UNSYNC; break;
            case PARSO_COMMAND_STEM_ARM: nativeCommand.type = PE_CMD_STEM_ARM; break;
            case PARSO_COMMAND_STEM_GAIN: nativeCommand.type = PE_CMD_STEM_GAIN; break;
            case PARSO_COMMAND_STEM_MUTE: nativeCommand.type = PE_CMD_STEM_MUTE; break;
            case PARSO_COMMAND_STEM_SOLO: nativeCommand.type = PE_CMD_STEM_SOLO; break;
            case PARSO_COMMAND_SET_REVERSE: nativeCommand.type = PE_CMD_SET_REVERSE; break;
            case PARSO_COMMAND_VINYL_SPEED: nativeCommand.type = PE_CMD_VINYL_SPEED; break;
            case PARSO_COMMAND_ECHO_SET: nativeCommand.type = PE_CMD_ECHO_SET; break;
            case PARSO_COMMAND_COLORFX_KIND: nativeCommand.type = PE_CMD_COLORFX_KIND; break;
            case PARSO_COMMAND_BEATFX_KIND: nativeCommand.type = PE_CMD_BEATFX_KIND; break;
            case PARSO_COMMAND_BEATFX_ONOFF: nativeCommand.type = PE_CMD_BEATFX_ONOFF; break;
            case PARSO_COMMAND_BEATFX_RELEASE: nativeCommand.type = PE_CMD_BEATFX_RELEASE; break;
            case PARSO_COMMAND_SAMPLER_TRIGGER: nativeCommand.type = PE_CMD_SAMPLER_TRIGGER; break;
            case PARSO_COMMAND_SAMPLER_STOP: nativeCommand.type = PE_CMD_SAMPLER_STOP; break;
            case PARSO_COMMAND_SAMPLER_CONFIG: nativeCommand.type = PE_CMD_SAMPLER_CONFIG; break;
            case PARSO_COMMAND_LOAD: nativeCommand.type = PE_CMD_LOAD; break;
            default: return fail(PARSO_STATUS_UNSUPPORTED, "command selector is unsupported");
        }
        nativeCommand.deck = command->deck;
        nativeCommand.i0 = command->i0;
        nativeCommand.i1 = command->i1;
        nativeCommand.i2 = command->i2;
        nativeCommand.f0 = command->f0;
        nativeCommand.f1 = command->f1;
        if (!pe_post_command(engine->handle.engine, &nativeCommand)) {
            return fail(PARSO_STATUS_QUEUE_FULL, "command queue is full");
        }
        lastError = "ok";
        return PARSO_STATUS_OK;
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while posting command");
    }
}

PARSO_API parso_status_t parso_engine_render(
    parso_engine_t *engine,
    const parso_output_view_t *output
) {
    try {
