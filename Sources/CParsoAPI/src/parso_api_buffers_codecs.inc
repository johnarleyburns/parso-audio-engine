void appendLE16(std::vector<uint8_t> &bytes, uint16_t value) {
    bytes.push_back(static_cast<uint8_t>(value));
    bytes.push_back(static_cast<uint8_t>(value >> 8));
}

void appendLE24(std::vector<uint8_t> &bytes, uint32_t value) {
    bytes.push_back(static_cast<uint8_t>(value));
    bytes.push_back(static_cast<uint8_t>(value >> 8));
    bytes.push_back(static_cast<uint8_t>(value >> 16));
}

void appendLE32(std::vector<uint8_t> &bytes, uint32_t value) {
    bytes.push_back(static_cast<uint8_t>(value));
    bytes.push_back(static_cast<uint8_t>(value >> 8));
    bytes.push_back(static_cast<uint8_t>(value >> 16));
    bytes.push_back(static_cast<uint8_t>(value >> 24));
}

void appendPCMInteger(std::vector<uint8_t> &bytes, float sample, uint32_t bits) {
    double value = std::isfinite(sample) ? static_cast<double>(sample) : 0.0;
    if (value > 1.0) value = 1.0;
    if (value < -1.0) value = -1.0;
    switch (bits) {
        case 8: {
            int value8 = static_cast<int>(value * 127.0 + (value >= 0 ? 0.5 : -0.5));
            if (value8 > 127) value8 = 127;
            if (value8 < -128) value8 = -128;
            bytes.push_back(static_cast<uint8_t>(value8 + 128));
            break;
        }
        case 16: {
            int value16 = static_cast<int>(value * 32767.0 + (value >= 0 ? 0.5 : -0.5));
            if (value16 > 32767) value16 = 32767;
            if (value16 < -32768) value16 = -32768;
            appendLE16(bytes, static_cast<uint16_t>(static_cast<int16_t>(value16)));
            break;
        }
        case 24: {
            int64_t value24 = static_cast<int64_t>(value * 8388607.0 + (value >= 0 ? 0.5 : -0.5));
            if (value24 > 8388607) value24 = 8388607;
            if (value24 < -8388608) value24 = -8388608;
            appendLE24(bytes, static_cast<uint32_t>(value24));
            break;
        }
        case 32: {
            double scaled = value * 2147483647.0 + (value >= 0 ? 0.5 : -0.5);
            int64_t value32 = static_cast<int64_t>(scaled);
            if (value32 > 2147483647) value32 = 2147483647;
            if (value32 < -2147483648LL) value32 = -2147483648LL;
            appendLE32(bytes, static_cast<uint32_t>(value32));
            break;
        }
        default:
            break;
    }
}

parso_status_t validateWriteSize(const parso_pcm_buffer_t *buffer, uint32_t bits,
                                 uint64_t headerBytes, uint64_t maxBytes) noexcept {
    const parso_status_t bufferStatus = validatePCMBuffer(buffer);
    if (bufferStatus != PARSO_STATUS_OK) return bufferStatus;
    if (!validBits(bits)) return fail(PARSO_STATUS_INVALID_ARGUMENT, "unsupported PCM bit depth");
    const uint64_t samples = buffer->frames * buffer->channel_count;
    const uint64_t bytesPerSample = bits / 8;
    if (!multiplicationFits(samples, bytesPerSample, maxBytes - headerBytes)) {
        return fail(PARSO_STATUS_INVALID_ARGUMENT, "encoded PCM is too large");
    }
    return PARSO_STATUS_OK;
}

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
    parso_api_detail::EngineHandle handle;
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

PARSO_API parso_status_t parso_capabilities_init(parso_capabilities_t *capabilities) {
    if (!capabilities) return fail(PARSO_STATUS_INVALID_ARGUMENT, "capabilities is null");
    std::memset(capabilities, 0, sizeof(*capabilities));
    capabilities->size = sizeof(*capabilities);
    capabilities->abi_version = PARSO_ABI_VERSION;
    return PARSO_STATUS_OK;
}

PARSO_API parso_status_t parso_capabilities_get(parso_capabilities_t *capabilities) {
    const parso_status_t status = validateCapabilities(capabilities);
    if (status != PARSO_STATUS_OK) return status;
    capabilities->decode_containers = PARSO_CONTAINER_WAV;
    capabilities->encode_containers = PARSO_CONTAINER_WAV;
#if defined(PARSO_CODEC_BRIDGES_AVAILABLE)
    capabilities->decode_containers |= PARSO_CONTAINER_FLAC |
                                       PARSO_CONTAINER_OGG_VORBIS |
                                       PARSO_CONTAINER_OPUS |
                                       PARSO_CONTAINER_MP3 |
                                       PARSO_CONTAINER_AAC;
    capabilities->encode_containers |= PARSO_CONTAINER_FLAC |
                                       PARSO_CONTAINER_OGG_VORBIS |
                                       PARSO_CONTAINER_OPUS |
                                       PARSO_CONTAINER_MP3 |
                                       PARSO_CONTAINER_AAC;
#endif
    capabilities->pcm_read_formats = PARSO_PCM_FORMAT_S8 |
                                      PARSO_PCM_FORMAT_S16_LE |
                                      PARSO_PCM_FORMAT_S24_LE |
                                      PARSO_PCM_FORMAT_S32_LE;
    capabilities->pcm_write_formats = capabilities->pcm_read_formats;
    capabilities->max_channels = 2;
    capabilities->max_sample_rate_hz = static_cast<uint32_t>(INT32_MAX);
    capabilities->offline_services = PARSO_OFFLINE_SERVICE_SRC |
                                     PARSO_OFFLINE_SERVICE_LOUDNESS |
                                     PARSO_OFFLINE_SERVICE_ANALYSIS;
    lastError = "ok";
    return PARSO_STATUS_OK;
}

PARSO_API parso_status_t parso_pcm_buffer_init(parso_pcm_buffer_t *buffer) {
    if (!buffer) return fail(PARSO_STATUS_INVALID_ARGUMENT, "PCM buffer is null");
    std::memset(buffer, 0, sizeof(*buffer));
    buffer->size = sizeof(*buffer);
    buffer->abi_version = PARSO_ABI_VERSION;
    return PARSO_STATUS_OK;
}

PARSO_API parso_status_t parso_pcm_buffer_release(parso_pcm_buffer_t *buffer) {
    if (!buffer) return fail(PARSO_STATUS_INVALID_ARGUMENT, "PCM buffer is null");
    std::free(buffer->samples);
    std::memset(buffer, 0, sizeof(*buffer));
    buffer->size = sizeof(*buffer);
    buffer->abi_version = PARSO_ABI_VERSION;
    lastError = "ok";
    return PARSO_STATUS_OK;
}

PARSO_API parso_status_t parso_bytes_init(parso_bytes_t *bytes) {
    if (!bytes) return fail(PARSO_STATUS_INVALID_ARGUMENT, "bytes are null");
    std::memset(bytes, 0, sizeof(*bytes));
    bytes->size = sizeof(*bytes);
    bytes->abi_version = PARSO_ABI_VERSION;
    return PARSO_STATUS_OK;
}

PARSO_API parso_status_t parso_bytes_release(parso_bytes_t *bytes) {
    if (!bytes) return fail(PARSO_STATUS_INVALID_ARGUMENT, "bytes are null");
    std::free(bytes->data);
    std::memset(bytes, 0, sizeof(*bytes));
    bytes->size = sizeof(*bytes);
    bytes->abi_version = PARSO_ABI_VERSION;
    lastError = "ok";
    return PARSO_STATUS_OK;
}

PARSO_API parso_status_t parso_codec_options_init(parso_codec_options_t *options) {
    if (!options) return fail(PARSO_STATUS_INVALID_ARGUMENT, "codec options are null");
    std::memset(options, 0, sizeof(*options));
    options->size = sizeof(*options);
    options->abi_version = PARSO_ABI_VERSION;
    options->compression_level = 5;
    options->bitrate_kbps = 192;
    options->bits_per_sample = 16;
    options->quality = 1;
    options->vbr_quality = PARSO_CODEC_VBR_CBR;
    return PARSO_STATUS_OK;
}
