#include "parso.h"

#include "parso_engine.h"

#include <cmath>
#include <cstdint>
#include <cstring>
#include <new>

namespace {

constexpr uint32_t kMinimumOptionsSize = static_cast<uint32_t>(sizeof(parso_engine_options_t));
constexpr uint32_t kMinimumControlSize = static_cast<uint32_t>(sizeof(parso_control_t));
constexpr uint32_t kMinimumPCMViewSize = static_cast<uint32_t>(sizeof(parso_pcm_view_t));
constexpr uint32_t kMinimumOutputSize = static_cast<uint32_t>(sizeof(parso_output_view_t));
constexpr uint32_t kMinimumCommandSize = static_cast<uint32_t>(sizeof(parso_command_t));
constexpr uint32_t kMinimumStatsSize = static_cast<uint32_t>(sizeof(parso_stats_t));

thread_local const char *lastError = "ok";

parso_status_t fail(parso_status_t status, const char *message) noexcept {
    lastError = message;
    return status;
}

parso_status_t checkHeader(uint32_t size, uint32_t version, uint32_t minimum) noexcept {
    if (version != PARSO_ABI_VERSION) return fail(PARSO_STATUS_UNSUPPORTED, "unsupported ABI version");
    if (size < minimum) return fail(PARSO_STATUS_INVALID_SIZE, "structure size is too small");
    return PARSO_STATUS_OK;
}

bool finitePositive(uint32_t value) noexcept {
    return value > 0;
}

struct EngineHandle {
    pe_engine *engine = nullptr;
    uint32_t maxFrames = 0;
    uint32_t deckCount = 0;
};

void defaultControl(pe_control &control) noexcept {
    std::memset(&control, 0, sizeof(control));
    control.master_level = 0.8f;
    control.limiter_ceiling_db = -0.3f;
    control.limiter_enabled = 1.0f;
    control.cue_master_mix = 0.5f;
    control.headphone_level = 0.7f;
    control.mic_talkover_depth_db = -14.0f;
    control.beatfx_beats = 0.5f;
    control.beatfx_depth = 0.5f;
    control.beatfx_xpad = -1.0f;
    control.master_reverb_size = 0.6f;
    control.master_reverb_decay = 0.6f;
    control.master_reverb_damp = 0.5f;
    control.booth_level = 0.8f;
    for (uint32_t index = 0; index < PARSO_MAX_DECKS; ++index) {
        control.xfade_assign[index] = 2.0f;
        control.fader[index] = 1.0f;
        control.trim[index] = 0.5f;
        control.deck_time_ratio[index] = 1.0f;
        control.color_param[index] = 0.5f;
    }
}

parso_status_t validateEngine(const EngineHandle *handle) noexcept {
    return handle && handle->engine
        ? PARSO_STATUS_OK
        : fail(PARSO_STATUS_CLOSED, "engine handle is closed");
}

parso_status_t validateControl(const parso_control_t *control) noexcept {
    if (!control) return fail(PARSO_STATUS_INVALID_ARGUMENT, "control is null");
    return checkHeader(control->size, control->abi_version, kMinimumControlSize);
}

parso_status_t validateView(const parso_pcm_view_t *view) noexcept {
    if (!view) return fail(PARSO_STATUS_INVALID_ARGUMENT, "PCM view is null");
    const parso_status_t headerStatus = checkHeader(view->size, view->abi_version, kMinimumPCMViewSize);
    if (headerStatus != PARSO_STATUS_OK) return headerStatus;
    if (!view->planes || !view->planes[0] || view->channel_count < 1 || view->channel_count > 2) {
        return fail(PARSO_STATUS_INVALID_ARGUMENT, "PCM view must contain one or two planes");
    }
    if (view->channel_count == 2 && !view->planes[1]) {
        return fail(PARSO_STATUS_INVALID_ARGUMENT, "stereo PCM view is missing its right plane");
    }
    if (!finitePositive(view->sample_rate_hz)) {
        return fail(PARSO_STATUS_INVALID_ARGUMENT, "PCM sample rate must be positive");
    }
    return PARSO_STATUS_OK;
}

} // namespace

struct parso_engine {
    EngineHandle handle;
};

extern "C" {

PARSO_API const char *parso_last_error(void) {
    return lastError;
}

PARSO_API const char *parso_status_string(parso_status_t status) {
    switch (status) {
        case PARSO_STATUS_OK: return "ok";
        case PARSO_STATUS_INVALID_ARGUMENT: return "invalid argument";
        case PARSO_STATUS_INVALID_SIZE: return "invalid structure size";
        case PARSO_STATUS_UNSUPPORTED: return "unsupported";
        case PARSO_STATUS_OUT_OF_MEMORY: return "out of memory";
        case PARSO_STATUS_QUEUE_FULL: return "queue full";
        case PARSO_STATUS_CLOSED: return "closed";
        case PARSO_STATUS_INTERNAL: return "internal error";
        default: return "unknown status";
    }
}

PARSO_API parso_status_t parso_engine_options_init(parso_engine_options_t *options) {
    if (!options) return fail(PARSO_STATUS_INVALID_ARGUMENT, "options is null");
    std::memset(options, 0, sizeof(*options));
    options->size = sizeof(*options);
    options->abi_version = PARSO_ABI_VERSION;
    options->sample_rate_hz = 48000;
    options->max_frames = 512;
    options->deck_count = 2;
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
    for (uint32_t index = 0; index < PARSO_MAX_DECKS; ++index) {
        control->xfade_assign[index] = 2.0f;
        control->fader[index] = 1.0f;
        control->trim[index] = 0.5f;
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
            options->deck_count < 2 || options->deck_count > PARSO_MAX_DECKS) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "invalid engine options");
        }
        pe_engine *internal = pe_create(
            static_cast<double>(options->sample_rate_hz),
            static_cast<int>(options->max_frames),
            static_cast<int>(options->deck_count)
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
        for (uint32_t index = 0; index < PARSO_MAX_DECKS; ++index) {
            nativeControl.xfade_assign[index] = control->xfade_assign[index];
            nativeControl.fader[index] = control->fader[index];
            nativeControl.trim[index] = control->trim[index];
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
        if (command->type == PARSO_COMMAND_PLAY) nativeCommand.type = PE_CMD_PLAY;
        else if (command->type == PARSO_COMMAND_PAUSE) nativeCommand.type = PE_CMD_PAUSE;
        else return fail(PARSO_STATUS_UNSUPPORTED, "command is not in this ABI slice");
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

} // extern "C"
