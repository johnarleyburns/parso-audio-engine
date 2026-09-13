namespace parso_api_detail {

struct EngineHandle {
    pe_engine *engine = nullptr;
    uint32_t maxFrames = 0;
    uint32_t deckCount = 0;
};

} // namespace parso_api_detail

namespace {

using parso_api_detail::EngineHandle;

constexpr uint32_t kMinimumOptionsSize = static_cast<uint32_t>(sizeof(parso_engine_options_t));
constexpr uint32_t kMinimumControlSize = static_cast<uint32_t>(sizeof(parso_control_t));
constexpr uint32_t kMinimumPCMViewSize = static_cast<uint32_t>(sizeof(parso_pcm_view_t));
constexpr uint32_t kMinimumOutputSize = static_cast<uint32_t>(sizeof(parso_output_view_t));
constexpr uint32_t kMinimumCommandSize = static_cast<uint32_t>(sizeof(parso_command_t));
constexpr uint32_t kMinimumStatsSize = static_cast<uint32_t>(sizeof(parso_stats_t));
constexpr uint32_t kMinimumEventSize = static_cast<uint32_t>(sizeof(parso_event_t));
constexpr uint32_t kMinimumCapabilitiesSize = static_cast<uint32_t>(sizeof(parso_capabilities_t));
constexpr uint32_t kMinimumPCMBufferSize = static_cast<uint32_t>(sizeof(parso_pcm_buffer_t));
constexpr uint32_t kMinimumBytesSize = static_cast<uint32_t>(sizeof(parso_bytes_t));
constexpr uint32_t kMinimumCodecOptionsSize = static_cast<uint32_t>(sizeof(parso_codec_options_t));
constexpr uint32_t kMinimumSRCOptionsSize = static_cast<uint32_t>(sizeof(parso_src_options_t));
constexpr uint32_t kMinimumLoudnessOptionsSize =
    static_cast<uint32_t>(sizeof(parso_loudness_options_t));
constexpr uint32_t kMinimumLoudnessResultSize =
    static_cast<uint32_t>(sizeof(parso_loudness_result_t));
constexpr uint32_t kMinimumAnalysisOptionsSize =
    static_cast<uint32_t>(sizeof(parso_analysis_options_t));
constexpr uint32_t kMinimumAnalysisResultSize =
    static_cast<uint32_t>(sizeof(parso_analysis_result_t));
constexpr uint32_t kMinimumKeyOptionsSize =
    static_cast<uint32_t>(sizeof(parso_key_options_t));
constexpr uint32_t kMinimumKeyResultSize =
    static_cast<uint32_t>(sizeof(parso_key_result_t));
constexpr uint32_t kMinimumStructureOptionsSize =
    static_cast<uint32_t>(sizeof(parso_structure_options_t));

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

bool validBits(uint32_t bits) noexcept {
    return bits == 8 || bits == 16 || bits == 24 || bits == 32;
}

bool validWavBits(uint32_t bits, uint32_t isFloat) noexcept {
    if (isFloat > 1) return false;
    return isFloat ? (bits == 32 || bits == 64) : validBits(bits);
}

bool validSRCQuality(uint32_t quality) noexcept {
    return quality <= PARSO_SRC_QUALITY_FASTEST;
}

bool multiplicationFits(uint64_t left, uint64_t right, uint64_t limit) noexcept {
    return right == 0 || left <= limit / right;
}

parso_status_t validateCapabilities(const parso_capabilities_t *capabilities) noexcept {
    if (!capabilities) return fail(PARSO_STATUS_INVALID_ARGUMENT, "capabilities is null");
    return checkHeader(capabilities->size, capabilities->abi_version, kMinimumCapabilitiesSize);
}

parso_status_t validatePCMBuffer(const parso_pcm_buffer_t *buffer) noexcept {
    if (!buffer) return fail(PARSO_STATUS_INVALID_ARGUMENT, "PCM buffer is null");
    const parso_status_t headerStatus = checkHeader(
        buffer->size, buffer->abi_version, kMinimumPCMBufferSize
    );
    if (headerStatus != PARSO_STATUS_OK) return headerStatus;
    if (buffer->channel_count < 1 || buffer->channel_count > 2 ||
        !finitePositive(buffer->sample_rate_hz)) {
        return fail(PARSO_STATUS_INVALID_ARGUMENT, "PCM buffer format is invalid");
    }
    if (buffer->frames > 0 && !buffer->samples) {
        return fail(PARSO_STATUS_INVALID_ARGUMENT, "PCM buffer samples are null");
    }
    if (!multiplicationFits(buffer->frames, buffer->channel_count,
                            static_cast<uint64_t>(std::numeric_limits<size_t>::max()) /
                            sizeof(float))) {
        return fail(PARSO_STATUS_INVALID_ARGUMENT, "PCM buffer is too large");
    }
    return PARSO_STATUS_OK;
}

parso_status_t validateEmptyPCMBuffer(const parso_pcm_buffer_t *buffer) noexcept {
    if (!buffer) return fail(PARSO_STATUS_INVALID_ARGUMENT, "output PCM buffer is null");
    const parso_status_t status = checkHeader(buffer->size, buffer->abi_version, kMinimumPCMBufferSize);
    if (status != PARSO_STATUS_OK) return status;
    if (buffer->samples || buffer->frames != 0 || buffer->channel_count != 0 ||
        buffer->sample_rate_hz != 0) {
        return fail(PARSO_STATUS_INVALID_ARGUMENT, "output PCM buffer must be empty");
    }
    return PARSO_STATUS_OK;
}

parso_status_t validateEmptyBytes(const parso_bytes_t *bytes) noexcept {
    if (!bytes) return fail(PARSO_STATUS_INVALID_ARGUMENT, "output bytes are null");
    const parso_status_t status = checkHeader(bytes->size, bytes->abi_version, kMinimumBytesSize);
    if (status != PARSO_STATUS_OK) return status;
    if (bytes->data || bytes->size_bytes != 0) {
        return fail(PARSO_STATUS_INVALID_ARGUMENT, "output bytes must be empty");
    }
    return PARSO_STATUS_OK;
}

bool validCodec(uint32_t codec) noexcept {
    return codec >= PARSO_CODEC_WAV && codec <= PARSO_CODEC_AAC;
}

parso_status_t validateCodecOptions(const parso_codec_options_t *options) noexcept {
    if (!options) return fail(PARSO_STATUS_INVALID_ARGUMENT, "codec options are null");
    const parso_status_t status = checkHeader(
        options->size, options->abi_version, kMinimumCodecOptionsSize
    );
    if (status != PARSO_STATUS_OK) return status;
    if (options->compression_level > 8 || options->wav_is_float > 1 ||
        options->quality > 2 ||
        (options->vbr_quality != PARSO_CODEC_VBR_CBR && options->vbr_quality > 9)) {
        return fail(PARSO_STATUS_INVALID_ARGUMENT, "codec options are invalid");
    }
    if (options->bits_per_sample != 0 && !validWavBits(
            options->bits_per_sample, options->wav_is_float)) {
        return fail(PARSO_STATUS_INVALID_ARGUMENT, "codec bit depth is invalid");
    }
    if (options->bitrate_kbps != 0 &&
        (options->bitrate_kbps < 8 || options->bitrate_kbps > 512)) {
        return fail(PARSO_STATUS_INVALID_ARGUMENT, "codec bitrate is invalid");
    }
    return PARSO_STATUS_OK;
}

parso_status_t validateSRCOptions(const parso_src_options_t *options) noexcept {
    if (!options) return fail(PARSO_STATUS_INVALID_ARGUMENT, "SRC options are null");
    const parso_status_t status = checkHeader(
        options->size, options->abi_version, kMinimumSRCOptionsSize
    );
    if (status != PARSO_STATUS_OK) return status;
    if (!finitePositive(options->destination_sample_rate_hz) ||
        options->destination_sample_rate_hz > static_cast<uint32_t>(INT_MAX) ||
        options->source_sample_rate_hz > static_cast<uint32_t>(INT_MAX) ||
        options->channel_count > 2 || !validSRCQuality(options->quality)) {
        return fail(PARSO_STATUS_INVALID_ARGUMENT, "invalid SRC options");
    }
    return PARSO_STATUS_OK;
}

parso_status_t validateLoudnessOptions(const parso_loudness_options_t *options) noexcept {
    if (!options) return fail(PARSO_STATUS_INVALID_ARGUMENT, "loudness options are null");
    const parso_status_t status = checkHeader(
        options->size, options->abi_version, kMinimumLoudnessOptionsSize
    );
    if (status != PARSO_STATUS_OK) return status;
    if (!std::isfinite(options->target_lufs)) {
        return fail(PARSO_STATUS_INVALID_ARGUMENT, "loudness target is not finite");
    }
    return PARSO_STATUS_OK;
}

parso_status_t validateLoudnessResult(parso_loudness_result_t *result) noexcept {
    if (!result) return fail(PARSO_STATUS_INVALID_ARGUMENT, "loudness result is null");
    return checkHeader(result->size, result->abi_version, kMinimumLoudnessResultSize);
}

parso_status_t validateAnalysisOptions(const parso_analysis_options_t *options) noexcept {
    if (!options) return fail(PARSO_STATUS_INVALID_ARGUMENT, "analysis options are null");
    const parso_status_t status = checkHeader(
        options->size, options->abi_version, kMinimumAnalysisOptionsSize
    );
    if (status != PARSO_STATUS_OK) return status;
    if (options->hop_frames > 8192 || options->min_bpm > 300 || options->max_bpm > 300 ||
        (options->min_bpm != 0 && options->max_bpm != 0 && options->min_bpm >= options->max_bpm)) {
        return fail(PARSO_STATUS_INVALID_ARGUMENT, "analysis options are invalid");
    }
    return PARSO_STATUS_OK;
}

parso_status_t validateAnalysisResult(parso_analysis_result_t *result) noexcept {
    if (!result) return fail(PARSO_STATUS_INVALID_ARGUMENT, "analysis result is null");
    return checkHeader(result->size, result->abi_version, kMinimumAnalysisResultSize);
}

parso_status_t validateKeyOptions(const parso_key_options_t *options) noexcept {
    if (!options) return fail(PARSO_STATUS_INVALID_ARGUMENT, "key options are null");
    const parso_status_t status = checkHeader(
        options->size, options->abi_version, kMinimumKeyOptionsSize
    );
    if (status != PARSO_STATUS_OK) return status;
    if (options->window_frames > 16384 || options->hop_frames > 16384 ||
        options->min_midi > 127 || options->max_midi > 127 ||
        (options->min_midi != 0 && options->max_midi != 0 &&
         options->min_midi > options->max_midi)) {
        return fail(PARSO_STATUS_INVALID_ARGUMENT, "key options are invalid");
    }
    return PARSO_STATUS_OK;
}

parso_status_t validateKeyResult(parso_key_result_t *result) noexcept {
    if (!result) return fail(PARSO_STATUS_INVALID_ARGUMENT, "key result is null");
    return checkHeader(result->size, result->abi_version, kMinimumKeyResultSize);
}

parso_status_t validateStructureOptions(
    const parso_structure_options_t *options) noexcept {
    if (!options) return fail(PARSO_STATUS_INVALID_ARGUMENT, "structure options are null");
    const parso_status_t status = checkHeader(
        options->size, options->abi_version, kMinimumStructureOptionsSize
    );
    if (status != PARSO_STATUS_OK) return status;
    if ((options->bpm != 0.0 &&
         (!std::isfinite(options->bpm) || options->bpm < 30.0 || options->bpm > 300.0)) ||
        options->max_sections > 4096) {
        return fail(PARSO_STATUS_INVALID_ARGUMENT, "structure options are invalid");
    }
    return PARSO_STATUS_OK;
}

double keyProfileCorrelation(const double *chroma, const double *profile) noexcept {
    double chromaMean = 0.0;
    double profileMean = 0.0;
    for (size_t index = 0; index < 12; ++index) {
        chromaMean += chroma[index];
        profileMean += profile[index];
    }
    chromaMean /= 12.0;
    profileMean /= 12.0;
    double numerator = 0.0;
    double chromaVariance = 0.0;
    double profileVariance = 0.0;
    for (size_t index = 0; index < 12; ++index) {
        const double a = chroma[index] - chromaMean;
        const double b = profile[index] - profileMean;
        numerator += a * b;
        chromaVariance += a * a;
        profileVariance += b * b;
    }
    const double denominator = std::sqrt(chromaVariance * profileVariance);
    return denominator > 1.0e-12 ? numerator / denominator : 0.0;
}

constexpr double kPi = 3.141592653589793238462643383279502884;

uint32_t camelotMinorNumber(uint32_t tonic) noexcept {
    static constexpr uint32_t numbers[12] = {5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10};
    return numbers[tonic % 12];
}

parso_status_t copyPCM(const std::vector<float> &samples, uint32_t sampleRate,
                       uint32_t channels, parso_pcm_buffer_t *out) noexcept {
    if (channels < 1 || channels > 2 || sampleRate == 0 ||
        samples.size() % channels != 0) {
        return fail(PARSO_STATUS_INTERNAL, "decoded PCM has an invalid format");
    }
    if (samples.size() > std::numeric_limits<uint64_t>::max() / sizeof(float)) {
        return fail(PARSO_STATUS_INVALID_ARGUMENT, "decoded PCM is too large");
    }
    const size_t allocationSize = samples.size() * sizeof(float);
    float *owned = nullptr;
    if (allocationSize > 0) {
        owned = static_cast<float *>(std::malloc(allocationSize));
        if (!owned) return fail(PARSO_STATUS_OUT_OF_MEMORY, "PCM allocation failed");
        std::memcpy(owned, samples.data(), allocationSize);
    }
    out->samples = owned;
    out->frames = static_cast<uint64_t>(samples.size() / channels);
    out->channel_count = channels;
    out->sample_rate_hz = sampleRate;
    return PARSO_STATUS_OK;
}

#if defined(PARSO_CODEC_BRIDGES_AVAILABLE)
parso_status_t copyPCM(const float *samples, uint64_t sampleCount,
                       uint32_t sampleRate, uint32_t channels,
                       parso_pcm_buffer_t *out) noexcept {
    if (!samples && sampleCount != 0) {
        return fail(PARSO_STATUS_INTERNAL, "decoded PCM is null");
    }
    if (channels < 1 || channels > 2 || sampleRate == 0 ||
        sampleCount % channels != 0 ||
        sampleCount > std::numeric_limits<size_t>::max() / sizeof(float)) {
        return fail(PARSO_STATUS_INTERNAL, "decoded PCM has an invalid format");
    }
    const size_t allocationSize = static_cast<size_t>(sampleCount) * sizeof(float);
    float *owned = nullptr;
    if (allocationSize > 0) {
        owned = static_cast<float *>(std::malloc(allocationSize));
        if (!owned) return fail(PARSO_STATUS_OUT_OF_MEMORY, "PCM allocation failed");
        std::memcpy(owned, samples, allocationSize);
    }
    out->samples = owned;
    out->frames = sampleCount / channels;
    out->channel_count = channels;
    out->sample_rate_hz = sampleRate;
    return PARSO_STATUS_OK;
}

parso_status_t copyIntegerPCM(const int32_t *samples, uint64_t sampleCount,
                              uint32_t sampleRate, uint32_t channels,
                              uint32_t bits, parso_pcm_buffer_t *out) noexcept {
    if (!samples && sampleCount != 0) {
        return fail(PARSO_STATUS_INTERNAL, "decoded integer PCM is null");
    }
    if (!validBits(bits) || channels < 1 || channels > 2 || sampleRate == 0 ||
        sampleCount % channels != 0 ||
        sampleCount > std::numeric_limits<size_t>::max() / sizeof(float)) {
        return fail(PARSO_STATUS_INTERNAL, "decoded integer PCM has an invalid format");
    }
    const size_t count = static_cast<size_t>(sampleCount);
    std::vector<float> converted(count);
    const double scale = std::ldexp(1.0, static_cast<int>(bits) - 1);
    for (size_t index = 0; index < count; ++index)
        converted[index] = static_cast<float>(static_cast<double>(samples[index]) / scale);
    return copyPCM(converted, sampleRate, channels, out);
}
#endif

parso_status_t copyBytes(const std::vector<uint8_t> &bytes, parso_bytes_t *out) noexcept {
    uint8_t *owned = nullptr;
    if (!bytes.empty()) {
        owned = static_cast<uint8_t *>(std::malloc(bytes.size()));
        if (!owned) return fail(PARSO_STATUS_OUT_OF_MEMORY, "byte allocation failed");
        std::memcpy(owned, bytes.data(), bytes.size());
    }
    out->data = owned;
    out->size_bytes = static_cast<uint64_t>(bytes.size());
    return PARSO_STATUS_OK;
}
