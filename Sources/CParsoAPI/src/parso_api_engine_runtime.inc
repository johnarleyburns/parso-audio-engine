        if (validateEngine(engine ? &engine->handle : nullptr) != PARSO_STATUS_OK) return PARSO_STATUS_CLOSED;
        if (!output) return fail(PARSO_STATUS_INVALID_ARGUMENT, "output is null");
        const parso_status_t headerStatus = checkHeader(
            output->size, output->abi_version, kMinimumOutputSize
        );
        if (headerStatus != PARSO_STATUS_OK) return headerStatus;
        if (output->frames == 0 || output->frames > engine->handle.maxFrames ||
            (!output->left && !output->right)) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "invalid output view");
        }
        pe_render(engine->handle.engine, output->left, output->right, static_cast<int>(output->frames));
        lastError = "ok";
        return PARSO_STATUS_OK;
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while rendering");
    }
}

PARSO_API parso_status_t parso_engine_render_monitor(
    parso_engine_t *engine,
    const parso_output_view_t *output
) {
    try {
        if (validateEngine(engine ? &engine->handle : nullptr) != PARSO_STATUS_OK)
            return PARSO_STATUS_CLOSED;
        if (!output) return fail(PARSO_STATUS_INVALID_ARGUMENT, "output is null");
        const parso_status_t headerStatus = checkHeader(
            output->size, output->abi_version, kMinimumOutputSize
        );
        if (headerStatus != PARSO_STATUS_OK) return headerStatus;
        if (output->frames == 0 || output->frames > engine->handle.maxFrames ||
            (!output->left && !output->right)) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "invalid output view");
        }
        pe_render_monitor(engine->handle.engine, output->left, output->right,
                          static_cast<int>(output->frames));
        lastError = "ok";
        return PARSO_STATUS_OK;
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while rendering monitor");
    }
}

PARSO_API parso_status_t parso_engine_render_booth(
    parso_engine_t *engine,
    const parso_output_view_t *output
) {
    try {
        if (validateEngine(engine ? &engine->handle : nullptr) != PARSO_STATUS_OK)
            return PARSO_STATUS_CLOSED;
        if (!output) return fail(PARSO_STATUS_INVALID_ARGUMENT, "output is null");
        const parso_status_t headerStatus = checkHeader(
            output->size, output->abi_version, kMinimumOutputSize
        );
        if (headerStatus != PARSO_STATUS_OK) return headerStatus;
        if (output->frames == 0 || output->frames > engine->handle.maxFrames ||
            (!output->left && !output->right)) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "invalid output view");
        }
        pe_render_booth(engine->handle.engine, output->left, output->right,
                        static_cast<int>(output->frames));
        lastError = "ok";
        return PARSO_STATUS_OK;
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while rendering booth");
    }
}

PARSO_API parso_status_t parso_engine_poll_events(
    parso_engine_t *engine, parso_event_t *events, uint32_t maxEvents,
    uint32_t *outEvents
) {
    try {
        if (validateEngine(engine ? &engine->handle : nullptr) != PARSO_STATUS_OK)
            return PARSO_STATUS_CLOSED;
        if (!outEvents) return fail(PARSO_STATUS_INVALID_ARGUMENT, "event count output is null");
        *outEvents = 0;
        if (maxEvents == 0) return PARSO_STATUS_OK;
        if (!events) return fail(PARSO_STATUS_INVALID_ARGUMENT, "event storage is null");
        if (maxEvents > static_cast<uint32_t>(INT_MAX))
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "event count is too large");
        for (uint32_t index = 0; index < maxEvents; ++index) {
            const parso_status_t headerStatus = checkHeader(
                events[index].size, events[index].abi_version, kMinimumEventSize
            );
            if (headerStatus != PARSO_STATUS_OK) return headerStatus;
        }
        pe_event nativeEvents[64]{};
        uint32_t remaining = maxEvents;
        uint32_t written = 0;
        while (remaining > 0) {
            const uint32_t batch = std::min<uint32_t>(remaining, 64u);
            const int count = pe_poll_events(
                engine->handle.engine, nativeEvents, static_cast<int>(batch));
            if (count <= 0) break;
            for (int index = 0; index < count; ++index) {
                events[written].type = static_cast<uint32_t>(nativeEvents[index].type);
                events[written].deck = nativeEvents[index].deck;
                events[written].frame = nativeEvents[index].frame;
                events[written].f0 = nativeEvents[index].f0;
                events[written].f1 = nativeEvents[index].f1;
                ++written;
            }
            written += 0;
            remaining -= static_cast<uint32_t>(count);
            if (static_cast<uint32_t>(count) < batch) break;
        }
        *outEvents = written;
        lastError = "ok";
        return PARSO_STATUS_OK;
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while polling events");
    }
}

PARSO_API parso_status_t parso_engine_get_stats(
    const parso_engine_t *engine,
    parso_stats_t *stats
) {
    try {
        if (validateEngine(engine ? &engine->handle : nullptr) != PARSO_STATUS_OK) return PARSO_STATUS_CLOSED;
        if (!stats) return fail(PARSO_STATUS_INVALID_ARGUMENT, "stats is null");
        const parso_status_t headerStatus = checkHeader(
            stats->size, stats->abi_version, kMinimumStatsSize
        );
        if (headerStatus != PARSO_STATUS_OK) return headerStatus;
        pe_stats nativeStats{};
        pe_get_stats(engine->handle.engine, &nativeStats);
        stats->master_frame = nativeStats.master_frame < 0 ? 0 : static_cast<uint64_t>(nativeStats.master_frame);
        stats->starved_frames = nativeStats.starved_frames < 0 ? 0 : static_cast<uint64_t>(nativeStats.starved_frames);
        stats->deck_count = engine->handle.deckCount;
        lastError = "ok";
        return PARSO_STATUS_OK;
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while reading stats");
    }
}

PARSO_API parso_status_t parso_engine_record_set_active(
    parso_engine_t *engine, uint32_t active
) {
    try {
        if (validateEngine(engine ? &engine->handle : nullptr) != PARSO_STATUS_OK)
            return PARSO_STATUS_CLOSED;
        if (active > 1) return fail(PARSO_STATUS_INVALID_ARGUMENT, "record active flag is invalid");
        pe_record_set_active(engine->handle.engine, active != 0 ? 1 : 0);
        lastError = "ok";
        return PARSO_STATUS_OK;
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while setting record state");
    }
}

PARSO_API parso_status_t parso_engine_record_drain(
    parso_engine_t *engine, float *left, float *right,
    uint32_t maxFrames, uint32_t *outFrames
) {
    try {
        if (validateEngine(engine ? &engine->handle : nullptr) != PARSO_STATUS_OK)
            return PARSO_STATUS_CLOSED;
        if (!outFrames || maxFrames == 0 || maxFrames > static_cast<uint32_t>(INT_MAX) ||
            (!left && !right)) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "record drain arguments are invalid");
        }
        *outFrames = static_cast<uint32_t>(pe_record_drain(
            engine->handle.engine, left, right, static_cast<int>(maxFrames)
        ));
        lastError = "ok";
        return PARSO_STATUS_OK;
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while draining record ring");
    }
}

PARSO_API parso_status_t parso_engine_record_dropped_frames(
    const parso_engine_t *engine, uint64_t *outFrames
) {
    try {
        if (validateEngine(engine ? &engine->handle : nullptr) != PARSO_STATUS_OK)
            return PARSO_STATUS_CLOSED;
        if (!outFrames) return fail(PARSO_STATUS_INVALID_ARGUMENT, "record counter is null");
        const int64_t dropped = pe_record_dropped_frames(engine->handle.engine);
        *outFrames = dropped < 0 ? 0 : static_cast<uint64_t>(dropped);
        lastError = "ok";
        return PARSO_STATUS_OK;
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while reading record counter");
    }
}

PARSO_API parso_status_t parso_engine_record_reset(parso_engine_t *engine) {
    try {
        if (validateEngine(engine ? &engine->handle : nullptr) != PARSO_STATUS_OK)
            return PARSO_STATUS_CLOSED;
        pe_record_reset(engine->handle.engine);
        lastError = "ok";
        return PARSO_STATUS_OK;
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while resetting record ring");
    }
}

} // extern "C"
