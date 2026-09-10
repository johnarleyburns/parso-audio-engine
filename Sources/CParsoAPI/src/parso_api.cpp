#include "parso.h"

#include "ebur128.h"
#include "parso_engine.h"
#include "samplerate.h"
#include "wav_io.hpp"
#if defined(PARSO_CODEC_BRIDGES_AVAILABLE)
#include "glint/glint.h"
#include "parso_flac.h"
#include "parso_vorbis.h"
#endif

#include <algorithm>
#include <climits>
#include <cmath>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>
#include <vector>

namespace {

constexpr uint32_t kMinimumOptionsSize = static_cast<uint32_t>(sizeof(parso_engine_options_t));
constexpr uint32_t kMinimumControlSize = static_cast<uint32_t>(sizeof(parso_control_t));
constexpr uint32_t kMinimumPCMViewSize = static_cast<uint32_t>(sizeof(parso_pcm_view_t));
constexpr uint32_t kMinimumOutputSize = static_cast<uint32_t>(sizeof(parso_output_view_t));
constexpr uint32_t kMinimumCommandSize = static_cast<uint32_t>(sizeof(parso_command_t));
constexpr uint32_t kMinimumStatsSize = static_cast<uint32_t>(sizeof(parso_stats_t));
constexpr uint32_t kMinimumCapabilitiesSize = static_cast<uint32_t>(sizeof(parso_capabilities_t));
constexpr uint32_t kMinimumPCMBufferSize = static_cast<uint32_t>(sizeof(parso_pcm_buffer_t));
constexpr uint32_t kMinimumBytesSize = static_cast<uint32_t>(sizeof(parso_bytes_t));
constexpr uint32_t kMinimumCodecOptionsSize = static_cast<uint32_t>(sizeof(parso_codec_options_t));
constexpr uint32_t kMinimumSRCOptionsSize = static_cast<uint32_t>(sizeof(parso_src_options_t));
constexpr uint32_t kMinimumLoudnessOptionsSize =
    static_cast<uint32_t>(sizeof(parso_loudness_options_t));
constexpr uint32_t kMinimumLoudnessResultSize =
    static_cast<uint32_t>(sizeof(parso_loudness_result_t));

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
                                     PARSO_OFFLINE_SERVICE_LOUDNESS;
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

PARSO_API parso_status_t parso_codec_read(
    const uint8_t *data, uint64_t sizeBytes, uint32_t codec,
    const parso_codec_options_t *options, parso_pcm_buffer_t *outBuffer
) {
    try {
        const parso_status_t outputStatus = validateEmptyPCMBuffer(outBuffer);
        if (outputStatus != PARSO_STATUS_OK) return outputStatus;
        const parso_status_t optionsStatus = validateCodecOptions(options);
        if (optionsStatus != PARSO_STATUS_OK) return optionsStatus;
        if (!validCodec(codec) || !data || sizeBytes == 0 ||
            sizeBytes > std::numeric_limits<size_t>::max()) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "codec input is invalid");
        }
        if (codec == PARSO_CODEC_WAV)
            return parso_wav_read(data, sizeBytes, outBuffer);
#if defined(PARSO_CODEC_BRIDGES_AVAILABLE)
        if (sizeBytes > static_cast<uint64_t>(INT_MAX))
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "codec input is too large");
        if (codec == PARSO_CODEC_FLAC) {
            int32_t *decoded = nullptr;
            uint64_t frames = 0;
            uint32_t channels = 0;
            uint32_t sampleRate = 0;
            uint32_t bits = 0;
            const int status = parso_flac_decode_memory(
                data, sizeBytes, &decoded, &frames, &channels, &sampleRate, &bits
            );
            if (status != 0 || !decoded || channels < 1 || channels > 2 ||
                sampleRate == 0 || frames == 0 || !validBits(bits)) {
                parso_flac_free(decoded);
                return fail(PARSO_STATUS_INVALID_ARGUMENT,
                            "FLAC input is malformed or unsupported");
            }
            const parso_status_t copyStatus = copyIntegerPCM(
                decoded, frames * channels, sampleRate, channels, bits, outBuffer
            );
            parso_flac_free(decoded);
            if (copyStatus == PARSO_STATUS_OK) lastError = "ok";
            return copyStatus;
        }
        if (codec == PARSO_CODEC_OGG_VORBIS) {
            float *decoded = nullptr;
            uint64_t frames = 0;
            uint32_t channels = 0;
            uint32_t sampleRate = 0;
            const int status = parso_vorbis_decode_memory(
                data, sizeBytes, &decoded, &frames, &channels, &sampleRate
            );
            if (status != 0 || !decoded || channels < 1 || channels > 2 ||
                sampleRate == 0 || frames == 0) {
                parso_vorbis_free(decoded);
                return fail(PARSO_STATUS_INVALID_ARGUMENT,
                            "Ogg Vorbis input is malformed or unsupported");
            }
            const parso_status_t copyStatus = copyPCM(
                decoded, frames * channels, sampleRate, channels, outBuffer
            );
            parso_vorbis_free(decoded);
            if (copyStatus == PARSO_STATUS_OK) lastError = "ok";
            return copyStatus;
        }
        int sampleRate = 0;
        int channels = 0;
        int frames = 0;
        float *decoded = static_cast<float *>(glint_decode_audio(
            data, static_cast<int>(sizeBytes), &sampleRate, &channels, &frames
        ));
        if (!decoded || sampleRate <= 0 || channels < 1 || channels > 2 || frames <= 0) {
            glint_free(decoded);
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "codec input is malformed or unsupported");
        }
        const parso_status_t status = copyPCM(
            decoded, static_cast<uint64_t>(frames) * static_cast<uint32_t>(channels),
            static_cast<uint32_t>(sampleRate), static_cast<uint32_t>(channels), outBuffer
        );
        glint_free(decoded);
        if (status == PARSO_STATUS_OK) lastError = "ok";
        return status;
#else
        (void)codec;
        return fail(PARSO_STATUS_UNSUPPORTED, "codec bridges are unavailable");
#endif
    } catch (const std::bad_alloc &) {
        return fail(PARSO_STATUS_OUT_OF_MEMORY, "codec decode allocation failed");
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while reading codec data");
    }
}

PARSO_API parso_status_t parso_codec_write(
    const parso_pcm_buffer_t *input, uint32_t codec,
    const parso_codec_options_t *options, parso_bytes_t *outBytes
) {
    try {
        const parso_status_t outputStatus = validateEmptyBytes(outBytes);
        if (outputStatus != PARSO_STATUS_OK) return outputStatus;
        const parso_status_t inputStatus = validatePCMBuffer(input);
        if (inputStatus != PARSO_STATUS_OK) return inputStatus;
        const parso_status_t optionsStatus = validateCodecOptions(options);
        if (optionsStatus != PARSO_STATUS_OK) return optionsStatus;
        if (!validCodec(codec))
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "codec selector is invalid");
        if (codec == PARSO_CODEC_WAV)
            return parso_wav_write(input, options->bits_per_sample,
                                   options->wav_is_float, outBytes);
#if defined(PARSO_CODEC_BRIDGES_AVAILABLE)
        if (input->frames > static_cast<uint64_t>(INT_MAX) ||
            input->sample_rate_hz > static_cast<uint32_t>(INT_MAX)) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "codec input is too large");
        }
        const uint64_t sampleCount = input->frames * input->channel_count;
        if (codec == PARSO_CODEC_FLAC) {
            const uint32_t bits = options->bits_per_sample == 0
                ? 16 : options->bits_per_sample;
            if (bits != 16 && bits != 24 && bits != 32)
                return fail(PARSO_STATUS_INVALID_ARGUMENT, "FLAC bit depth is invalid");
            if (sampleCount > std::numeric_limits<size_t>::max() / sizeof(int32_t))
                return fail(PARSO_STATUS_INVALID_ARGUMENT, "codec input is too large");
            std::vector<int32_t> quantized(static_cast<size_t>(sampleCount));
            const double maximum = std::ldexp(1.0, static_cast<int>(bits) - 1) - 1.0;
            const double minimum = -std::ldexp(1.0, static_cast<int>(bits) - 1);
            for (size_t index = 0; index < quantized.size(); ++index) {
                double sample = std::isfinite(input->samples[index])
                    ? static_cast<double>(input->samples[index]) : 0.0;
                sample = std::max(-1.0, std::min(1.0, sample));
                double scaled = sample * maximum;
                if (sample < 0.0) scaled = sample * -minimum;
                int64_t value = static_cast<int64_t>(scaled + (scaled >= 0.0 ? 0.5 : -0.5));
                if (value > static_cast<int64_t>(maximum)) value = static_cast<int64_t>(maximum);
                if (static_cast<double>(value) < minimum) value = static_cast<int64_t>(minimum);
                quantized[index] = static_cast<int32_t>(value);
            }
            uint8_t *encoded = nullptr;
            uint64_t encodedSize = 0;
            const int status = parso_flac_encode_memory(
                quantized.empty() ? nullptr : quantized.data(), input->frames,
                input->channel_count, bits, input->sample_rate_hz,
                options->compression_level, &encoded, &encodedSize
            );
            if (status != 0 || !encoded || encodedSize == 0) {
                parso_flac_free(encoded);
                return fail(PARSO_STATUS_INTERNAL, "FLAC encode failed");
            }
            outBytes->data = encoded;
            outBytes->size_bytes = encodedSize;
            lastError = "ok";
            return PARSO_STATUS_OK;
        }
        if (codec == PARSO_CODEC_OGG_VORBIS) {
            const uint32_t bitrate = options->bitrate_kbps == 0 ? 192
                : options->bitrate_kbps;
            uint8_t *encoded = nullptr;
            uint64_t encodedSize = 0;
            const int status = parso_vorbis_encode_memory(
                input->samples, input->frames, input->channel_count,
                input->sample_rate_hz, bitrate, &encoded, &encodedSize
            );
            if (status != 0 || !encoded || encodedSize == 0) {
                parso_vorbis_free(encoded);
                return fail(PARSO_STATUS_INTERNAL, "Ogg Vorbis encode failed");
            }
            outBytes->data = encoded;
            outBytes->size_bytes = encodedSize;
            lastError = "ok";
            return PARSO_STATUS_OK;
        }
        const int format = codec == PARSO_CODEC_OPUS ? GLINT_ENC_OPUS
            : codec == PARSO_CODEC_MP3 ? GLINT_ENC_MP3 : GLINT_ENC_AAC;
        const int bitrate = options->bitrate_kbps == 0 ? 192
            : static_cast<int>(options->bitrate_kbps);
        const int vbrQuality = options->vbr_quality == PARSO_CODEC_VBR_CBR
            ? -1 : static_cast<int>(options->vbr_quality);
        int encodedSize = 0;
        uint8_t *encoded = glint_encode_audio(
            input->samples, static_cast<int>(input->frames),
            static_cast<int>(input->channel_count), static_cast<int>(input->sample_rate_hz),
            format, bitrate, vbrQuality, static_cast<int>(options->quality), &encodedSize
        );
        if (!encoded || encodedSize <= 0) {
            glint_free(encoded);
            return fail(PARSO_STATUS_INTERNAL, "codec encode failed");
        }
        outBytes->data = encoded;
        outBytes->size_bytes = static_cast<uint64_t>(encodedSize);
        lastError = "ok";
        return PARSO_STATUS_OK;
#else
        return fail(PARSO_STATUS_UNSUPPORTED, "codec bridges are unavailable");
#endif
    } catch (const std::bad_alloc &) {
        return fail(PARSO_STATUS_OUT_OF_MEMORY, "codec encode allocation failed");
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while writing codec data");
    }
}

PARSO_API parso_status_t parso_wav_read(
    const uint8_t *data, uint64_t sizeBytes, parso_pcm_buffer_t *outBuffer
) {
    try {
        const parso_status_t outputStatus = validateEmptyPCMBuffer(outBuffer);
        if (outputStatus != PARSO_STATUS_OK) return outputStatus;
        if (!data || sizeBytes == 0 || sizeBytes > std::numeric_limits<size_t>::max()) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "WAV input is empty or too large");
        }
        std::vector<float> samples;
        int sampleRate = 0;
        int channels = 0;
        if (!glint::wav_read(data, static_cast<size_t>(sizeBytes), samples,
                             sampleRate, channels)) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "WAV input is malformed or unsupported");
        }
        if (sampleRate <= 0 || channels < 1 || channels > 2) {
            return fail(PARSO_STATUS_UNSUPPORTED, "WAV format exceeds the native PCM contract");
        }
        const parso_status_t copyStatus = copyPCM(
            samples, static_cast<uint32_t>(sampleRate), static_cast<uint32_t>(channels), outBuffer
        );
        if (copyStatus == PARSO_STATUS_OK) lastError = "ok";
        return copyStatus;
    } catch (const std::bad_alloc &) {
        return fail(PARSO_STATUS_OUT_OF_MEMORY, "WAV decode allocation failed");
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while reading WAV");
    }
}

PARSO_API parso_status_t parso_pcm_read(
    const uint8_t *data, uint64_t sizeBytes, uint32_t sampleRateHz,
    uint32_t channelCount, uint32_t bitsPerSample, parso_pcm_buffer_t *outBuffer
) {
    try {
        const parso_status_t outputStatus = validateEmptyPCMBuffer(outBuffer);
        if (outputStatus != PARSO_STATUS_OK) return outputStatus;
        if (!data || sizeBytes == 0 || sizeBytes > std::numeric_limits<size_t>::max() ||
            !finitePositive(sampleRateHz) || sampleRateHz > static_cast<uint32_t>(INT_MAX) ||
            channelCount < 1 || channelCount > 2 ||
            !validBits(bitsPerSample)) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "raw PCM arguments are invalid");
        }
        std::vector<float> samples;
        if (!glint::pcm_read(data, static_cast<size_t>(sizeBytes),
                             static_cast<int>(sampleRateHz), static_cast<int>(channelCount),
                             static_cast<int>(bitsPerSample), samples)) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "raw PCM input is malformed");
        }
        const parso_status_t copyStatus = copyPCM(samples, sampleRateHz, channelCount, outBuffer);
        if (copyStatus == PARSO_STATUS_OK) lastError = "ok";
        return copyStatus;
    } catch (const std::bad_alloc &) {
        return fail(PARSO_STATUS_OUT_OF_MEMORY, "raw PCM decode allocation failed");
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while reading raw PCM");
    }
}

PARSO_API parso_status_t parso_wav_write(
    const parso_pcm_buffer_t *buffer, uint32_t bitsPerSample,
    uint32_t isFloat, parso_bytes_t *outBytes
) {
    try {
        const parso_status_t outputStatus = validateEmptyBytes(outBytes);
        if (outputStatus != PARSO_STATUS_OK) return outputStatus;
        const parso_status_t bufferStatus = validatePCMBuffer(buffer);
        if (bufferStatus != PARSO_STATUS_OK) return bufferStatus;
        if (!validWavBits(bitsPerSample, isFloat)) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "unsupported WAV sample format");
        }
        const uint64_t bytesPerSample = bitsPerSample / 8;
        const uint64_t samples = buffer->frames * buffer->channel_count;
        if (buffer->sample_rate_hz > static_cast<uint32_t>(INT_MAX) ||
            !multiplicationFits(samples, bytesPerSample, UINT32_MAX - 36u) ||
            buffer->frames > static_cast<uint64_t>(std::numeric_limits<long>::max())) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "WAV output is too large");
        }
        float zero = 0.0f;
        const float *samplesPointer = buffer->samples ? buffer->samples : &zero;
        const std::vector<uint8_t> bytes = glint::wav_write(
            samplesPointer, static_cast<long>(buffer->frames),
            static_cast<int>(buffer->channel_count), static_cast<int>(buffer->sample_rate_hz),
            static_cast<int>(bitsPerSample), isFloat != 0
        );
        const parso_status_t copyStatus = copyBytes(bytes, outBytes);
        if (copyStatus == PARSO_STATUS_OK) lastError = "ok";
        return copyStatus;
    } catch (const std::bad_alloc &) {
        return fail(PARSO_STATUS_OUT_OF_MEMORY, "WAV encode allocation failed");
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while writing WAV");
    }
}

PARSO_API parso_status_t parso_pcm_write(
    const parso_pcm_buffer_t *buffer, uint32_t bitsPerSample, parso_bytes_t *outBytes
) {
    try {
        const parso_status_t outputStatus = validateEmptyBytes(outBytes);
        if (outputStatus != PARSO_STATUS_OK) return outputStatus;
        const parso_status_t sizeStatus = validateWriteSize(
            buffer, bitsPerSample, 0, static_cast<uint64_t>(std::numeric_limits<size_t>::max())
        );
        if (sizeStatus != PARSO_STATUS_OK) return sizeStatus;
        const uint64_t sampleCount = buffer->frames * buffer->channel_count;
        const size_t byteCount = static_cast<size_t>(sampleCount * (bitsPerSample / 8));
        std::vector<uint8_t> bytes;
        bytes.reserve(byteCount);
        for (uint64_t index = 0; index < sampleCount; ++index) {
            appendPCMInteger(bytes, buffer->samples[index], bitsPerSample);
        }
        const parso_status_t copyStatus = copyBytes(bytes, outBytes);
        if (copyStatus == PARSO_STATUS_OK) lastError = "ok";
        return copyStatus;
    } catch (const std::bad_alloc &) {
        return fail(PARSO_STATUS_OUT_OF_MEMORY, "raw PCM encode allocation failed");
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while writing raw PCM");
    }
}

PARSO_API parso_status_t parso_src_options_init(parso_src_options_t *options) {
    if (!options) return fail(PARSO_STATUS_INVALID_ARGUMENT, "SRC options are null");
    std::memset(options, 0, sizeof(*options));
    options->size = sizeof(*options);
    options->abi_version = PARSO_ABI_VERSION;
    options->destination_sample_rate_hz = 48000;
    options->quality = PARSO_SRC_QUALITY_BEST;
    return PARSO_STATUS_OK;
}

PARSO_API parso_status_t parso_src_convert(
    const parso_pcm_buffer_t *input, const parso_src_options_t *options,
    parso_pcm_buffer_t *outBuffer
) {
    try {
        const parso_status_t outputStatus = validateEmptyPCMBuffer(outBuffer);
        if (outputStatus != PARSO_STATUS_OK) return outputStatus;
        const parso_status_t inputStatus = validatePCMBuffer(input);
        if (inputStatus != PARSO_STATUS_OK) return inputStatus;
        const parso_status_t optionsStatus = validateSRCOptions(options);
        if (optionsStatus != PARSO_STATUS_OK) return optionsStatus;
        const uint32_t sourceRate = options->source_sample_rate_hz != 0
            ? options->source_sample_rate_hz : input->sample_rate_hz;
        const uint32_t channels = options->channel_count != 0
            ? options->channel_count : input->channel_count;
        if (sourceRate != input->sample_rate_hz || channels != input->channel_count) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "SRC options do not match input PCM");
        }
        if (input->frames > static_cast<uint64_t>(std::numeric_limits<long>::max())) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "SRC input is too large");
        }
        const double ratio = static_cast<double>(options->destination_sample_rate_hz) /
                             static_cast<double>(sourceRate);
        if (src_is_valid_ratio(ratio) == 0) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "SRC ratio is outside supported limits");
        }
        if (input->frames == 0) {
            outBuffer->channel_count = channels;
            outBuffer->sample_rate_hz = options->destination_sample_rate_hz;
            lastError = "ok";
            return PARSO_STATUS_OK;
        }
        const double estimated = std::ceil(static_cast<double>(input->frames) * ratio) + 256.0;
        if (!std::isfinite(estimated) ||
            estimated > static_cast<double>(std::numeric_limits<long>::max()) ||
            estimated > static_cast<double>(std::numeric_limits<size_t>::max() / sizeof(float) /
                                             channels)) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "SRC output is too large");
        }
        const long outputCapacity = static_cast<long>(estimated);
        const uint64_t sampleCount = static_cast<uint64_t>(outputCapacity) * channels;
        std::vector<float> samples(static_cast<size_t>(sampleCount));
        SRC_DATA data{};
        data.data_in = input->samples;
        data.data_out = samples.data();
        data.input_frames = static_cast<long>(input->frames);
        data.output_frames = outputCapacity;
        data.end_of_input = 1;
        data.src_ratio = ratio;
        const int error = src_simple(&data, static_cast<int>(options->quality),
                                     static_cast<int>(channels));
        if (error != 0) return fail(PARSO_STATUS_INTERNAL, src_strerror(error));
        samples.resize(static_cast<size_t>(data.output_frames_gen) * channels);
        const parso_status_t copyStatus = copyPCM(
            samples, options->destination_sample_rate_hz, channels, outBuffer
        );
        if (copyStatus == PARSO_STATUS_OK) lastError = "ok";
        return copyStatus;
    } catch (const std::bad_alloc &) {
        return fail(PARSO_STATUS_OUT_OF_MEMORY, "SRC allocation failed");
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while converting sample rate");
    }
}

PARSO_API parso_status_t parso_loudness_options_init(parso_loudness_options_t *options) {
    if (!options) return fail(PARSO_STATUS_INVALID_ARGUMENT, "loudness options are null");
    std::memset(options, 0, sizeof(*options));
    options->size = sizeof(*options);
    options->abi_version = PARSO_ABI_VERSION;
    options->target_lufs = -14.0;
    return PARSO_STATUS_OK;
}

PARSO_API parso_status_t parso_loudness_result_init(parso_loudness_result_t *result) {
    if (!result) return fail(PARSO_STATUS_INVALID_ARGUMENT, "loudness result is null");
    std::memset(result, 0, sizeof(*result));
    result->size = sizeof(*result);
    result->abi_version = PARSO_ABI_VERSION;
    result->integrated_lufs = -HUGE_VAL;
    result->true_peak_dbtp = -HUGE_VAL;
    result->gain_to_target_db = HUGE_VAL;
    return PARSO_STATUS_OK;
}

PARSO_API parso_status_t parso_loudness_measure(
    const parso_pcm_buffer_t *input, const parso_loudness_options_t *options,
    parso_loudness_result_t *result
) {
    try {
        const parso_status_t resultStatus = validateLoudnessResult(result);
        if (resultStatus != PARSO_STATUS_OK) return resultStatus;
        const parso_status_t inputStatus = validatePCMBuffer(input);
        if (inputStatus != PARSO_STATUS_OK) return inputStatus;
        const parso_status_t optionsStatus = validateLoudnessOptions(options);
        if (optionsStatus != PARSO_STATUS_OK) return optionsStatus;
        const int mode = EBUR128_MODE_I | EBUR128_MODE_LRA | EBUR128_MODE_TRUE_PEAK;
        ebur128_state *state = ebur128_init(
            input->channel_count, input->sample_rate_hz, mode
        );
        if (!state) return fail(PARSO_STATUS_OUT_OF_MEMORY, "loudness state allocation failed");
        const int addStatus = ebur128_add_frames_float(
            state, input->samples, static_cast<size_t>(input->frames)
        );
        if (addStatus != EBUR128_SUCCESS) {
            ebur128_destroy(&state);
            return fail(PARSO_STATUS_INTERNAL, "loudness frame processing failed");
        }
        double integrated = -HUGE_VAL;
        if (ebur128_loudness_global(state, &integrated) != EBUR128_SUCCESS) {
            ebur128_destroy(&state);
            return fail(PARSO_STATUS_INTERNAL, "integrated loudness measurement failed");
        }
        double peak = 0.0;
        for (uint32_t channel = 0; channel < input->channel_count; ++channel) {
            double channelPeak = 0.0;
            if (ebur128_true_peak(state, channel, &channelPeak) != EBUR128_SUCCESS) {
                ebur128_destroy(&state);
                return fail(PARSO_STATUS_INTERNAL, "true peak measurement failed");
            }
            peak = std::max(peak, channelPeak);
        }
        double range = 0.0;
        if (ebur128_loudness_range(state, &range) != EBUR128_SUCCESS ||
            !std::isfinite(range) || range < 0.0) {
            range = 0.0;
        }
        ebur128_destroy(&state);
        result->integrated_lufs = integrated;
        result->true_peak_dbtp = peak > 0.0 ? 20.0 * std::log10(peak) : -HUGE_VAL;
        result->gain_to_target_db = options->target_lufs - integrated;
        result->loudness_range_lu = range;
        lastError = "ok";
        return PARSO_STATUS_OK;
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while measuring loudness");
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
