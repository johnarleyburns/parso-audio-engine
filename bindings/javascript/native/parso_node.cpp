#include <node_api.h>

#include "parso.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

#ifndef NODE_GYP_MODULE_NAME
#define NODE_GYP_MODULE_NAME parso_node
#endif

namespace {

bool napiOk(napi_env env, napi_status status, const char *operation) {
    if (status == napi_ok) return true;
    napi_throw_error(env, nullptr, operation);
    return false;
}

bool fail(napi_env env, parso_status_t status, const char *operation) {
    if (status == PARSO_STATUS_OK) return true;
    const char *detail = parso_last_error();
    std::string message = std::string(operation) + " failed with native status " +
        std::to_string(status);
    if (detail != nullptr && detail[0] != '\0') {
        message += ": ";
        message += detail;
    }
    napi_throw_error(env, nullptr, message.c_str());
    return false;
}

bool argCount(napi_env env, size_t actual, size_t minimum, const char *operation) {
    if (actual >= minimum) return true;
    std::string message = operation;
    message += " received too few arguments";
    napi_throw_type_error(env, nullptr, message.c_str());
    return false;
}

bool getNumber(napi_env env, napi_value value, double *out, const char *name) {
    napi_valuetype type;
    if (!napiOk(env, napi_typeof(env, value, &type), name) || type != napi_number) {
        napi_throw_type_error(env, nullptr, name);
        return false;
    }
    return napiOk(env, napi_get_value_double(env, value, out), name);
}

bool getU32(napi_env env, napi_value value, uint32_t *out, const char *name) {
    double number = 0.0;
    if (!getNumber(env, value, &number, name) || !std::isfinite(number) ||
        number < 0.0 || number > static_cast<double>(UINT32_MAX) ||
        std::floor(number) != number) {
        napi_throw_range_error(env, nullptr, name);
        return false;
    }
    *out = static_cast<uint32_t>(number);
    return true;
}

bool getI32(napi_env env, napi_value value, int32_t *out, const char *name) {
    double number = 0.0;
    if (!getNumber(env, value, &number, name) || !std::isfinite(number) ||
        number < static_cast<double>(INT32_MIN) || number > static_cast<double>(INT32_MAX) ||
        std::floor(number) != number) {
        napi_throw_range_error(env, nullptr, name);
        return false;
    }
    *out = static_cast<int32_t>(number);
    return true;
}

bool getOptionalNumber(napi_env env, napi_value object, const char *name,
                       double *out, bool *present) {
    napi_value value;
    napi_status status = napi_get_named_property(env, object, name, &value);
    if (status != napi_ok) {
        *present = false;
        return true;
    }
    napi_valuetype type;
    if (!napiOk(env, napi_typeof(env, value, &type), name)) return false;
    if (type == napi_undefined || type == napi_null) {
        *present = false;
        return true;
    }
    *present = true;
    return getNumber(env, value, out, name);
}

bool getFloat32(napi_env env, napi_value value, const float **data, size_t *length,
                const char *name) {
    napi_typedarray_type type;
    size_t byteOffset = 0;
    napi_value arrayBuffer;
    void *raw = nullptr;
    if (!napiOk(env, napi_get_typedarray_info(env, value, &type, length, &raw,
                                              &arrayBuffer, &byteOffset), name) ||
        type != napi_float32_array) {
        napi_throw_type_error(env, nullptr, name);
        return false;
    }
    *data = static_cast<const float *>(raw);
    return true;
}

bool getUint8(napi_env env, napi_value value, const uint8_t **data, size_t *length,
              const char *name) {
    napi_typedarray_type type;
    size_t byteOffset = 0;
    napi_value arrayBuffer;
    void *raw = nullptr;
    if (!napiOk(env, napi_get_typedarray_info(env, value, &type, length, &raw,
                                              &arrayBuffer, &byteOffset), name) ||
        type != napi_uint8_array) {
        napi_throw_type_error(env, nullptr, name);
        return false;
    }
    *data = static_cast<const uint8_t *>(raw);
    return true;
}

bool getBigIntHandle(napi_env env, napi_value value, parso_engine_t **out) {
    bool lossless = false;
    uint64_t raw = 0;
    if (!napiOk(env, napi_get_value_bigint_uint64(env, value, &raw, &lossless),
                "engine handle") || !lossless || raw == 0) {
        napi_throw_type_error(env, nullptr, "engine handle must be a non-zero BigInt");
        return false;
    }
    *out = reinterpret_cast<parso_engine_t *>(static_cast<uintptr_t>(raw));
    return true;
}

bool getObject(napi_env env, napi_value value, napi_value *out, const char *name) {
    napi_valuetype type;
    if (!napiOk(env, napi_typeof(env, value, &type), name) || type != napi_object) {
        napi_throw_type_error(env, nullptr, name);
        return false;
    }
    *out = value;
    return true;
}

bool setNamed(napi_env env, napi_value object, const char *name, napi_value value) {
    return napiOk(env, napi_set_named_property(env, object, name, value), name);
}

bool setU32(napi_env env, napi_value object, const char *name, uint32_t value) {
    napi_value number;
    return napiOk(env, napi_create_uint32(env, value, &number), name) &&
        setNamed(env, object, name, number);
}

bool setI32(napi_env env, napi_value object, const char *name, int32_t value) {
    napi_value number;
    return napiOk(env, napi_create_int32(env, value, &number), name) &&
        setNamed(env, object, name, number);
}

bool setU64(napi_env env, napi_value object, const char *name, uint64_t value) {
    napi_value number;
    if (value > static_cast<uint64_t>(9007199254740991.0)) {
        napi_throw_range_error(env, nullptr, "native integer exceeds JavaScript safe range");
        return false;
    }
    return napiOk(env, napi_create_double(env, static_cast<double>(value), &number), name) &&
        setNamed(env, object, name, number);
}

bool setDouble(napi_env env, napi_value object, const char *name, double value) {
    napi_value number;
    return napiOk(env, napi_create_double(env, value, &number), name) &&
        setNamed(env, object, name, number);
}

bool makeFloatArray(napi_env env, size_t length, napi_value *out, float **data = nullptr) {
    if (length > std::numeric_limits<size_t>::max() / sizeof(float)) {
        napi_throw_range_error(env, nullptr, "float array is too large");
        return false;
    }
    void *raw = nullptr;
    napi_value arrayBuffer;
    if (!napiOk(env, napi_create_arraybuffer(env, length * sizeof(float), &raw, &arrayBuffer),
                "float array allocation")) return false;
    napi_value typed;
    if (!napiOk(env, napi_create_typedarray(env, napi_float32_array, length,
                                             arrayBuffer, 0, &typed),
                "float array creation")) return false;
    if (data != nullptr) *data = static_cast<float *>(raw);
    *out = typed;
    return true;
}

bool makeByteArray(napi_env env, size_t length, napi_value *out, uint8_t **data = nullptr) {
    void *raw = nullptr;
    napi_value arrayBuffer;
    if (!napiOk(env, napi_create_arraybuffer(env, length, &raw, &arrayBuffer),
                "byte array allocation")) return false;
    napi_value typed;
    if (!napiOk(env, napi_create_typedarray(env, napi_uint8_array, length,
                                             arrayBuffer, 0, &typed),
                "byte array creation")) return false;
    if (data != nullptr) *data = static_cast<uint8_t *>(raw);
    *out = typed;
    return true;
}

bool pcmResult(napi_env env, parso_pcm_buffer_t *buffer, napi_value *out) {
    if (buffer->frames > SIZE_MAX / buffer->channel_count) {
        napi_throw_range_error(env, nullptr, "native PCM is too large");
        return false;
    }
    size_t count = static_cast<size_t>(buffer->frames * buffer->channel_count);
    napi_value samples;
    float *copy = nullptr;
    if (!makeFloatArray(env, count, &samples, &copy)) return false;
    if (count != 0 && buffer->samples == nullptr) {
        napi_throw_error(env, nullptr, "native PCM returned a null sample pointer");
        return false;
    }
    if (count != 0) std::memcpy(copy, buffer->samples, count * sizeof(float));
    napi_value result;
    if (!napiOk(env, napi_create_object(env, &result), "PCM result")) return false;
    return setNamed(env, result, "samples", samples) &&
        setU64(env, result, "frames", buffer->frames) &&
        setU32(env, result, "channelCount", buffer->channel_count) &&
        setU32(env, result, "sampleRateHz", buffer->sample_rate_hz) &&
        (*out = result, true);
}

bool bytesResult(napi_env env, parso_bytes_t *bytes, napi_value *out) {
    if (bytes->size_bytes > SIZE_MAX) {
        napi_throw_range_error(env, nullptr, "native byte result is too large");
        return false;
    }
    napi_value result;
    uint8_t *copy = nullptr;
    if (!makeByteArray(env, static_cast<size_t>(bytes->size_bytes), &result, &copy)) return false;
    if (bytes->size_bytes != 0 && bytes->data == nullptr) {
        napi_throw_error(env, nullptr, "native byte result has a null pointer");
        return false;
    }
    if (bytes->size_bytes != 0) std::memcpy(copy, bytes->data, static_cast<size_t>(bytes->size_bytes));
    *out = result;
    return true;
}

bool readOptions(napi_env env, napi_value value, parso_codec_options_t *options) {
    if (value == nullptr) return true;
    napi_value object;
    if (!getObject(env, value, &object, "codec options")) return false;
    double number = 0.0; bool present = false;
    if (!getOptionalNumber(env, object, "compressionLevel", &number, &present)) return false;
    if (present) options->compression_level = static_cast<uint32_t>(number);
    if (!getOptionalNumber(env, object, "bitrateKbps", &number, &present)) return false;
    if (present) options->bitrate_kbps = static_cast<uint32_t>(number);
    if (!getOptionalNumber(env, object, "bitsPerSample", &number, &present)) return false;
    if (present) options->bits_per_sample = static_cast<uint32_t>(number);
    if (!getOptionalNumber(env, object, "quality", &number, &present)) return false;
    if (present) options->quality = static_cast<uint32_t>(number);
    if (!getOptionalNumber(env, object, "vbrQuality", &number, &present)) return false;
    if (present) options->vbr_quality = static_cast<uint32_t>(number);
    if (!getOptionalNumber(env, object, "wavIsFloat", &number, &present)) return false;
    if (present) options->wav_is_float = number != 0.0 ? 1u : 0u;
    return true;
}

bool parsePcmArgs(napi_env env, napi_value *argv, size_t sampleIndex, size_t rateIndex,
                  size_t channelIndex, const float **samples, size_t *sampleCount,
                  uint32_t *rate, uint32_t *channels) {
    if (!getFloat32(env, argv[sampleIndex], samples, sampleCount, "samples") ||
        !getU32(env, argv[rateIndex], rate, "sample rate") ||
        !getU32(env, argv[channelIndex], channels, "channel count")) return false;
    if (*sampleCount == 0 || *channels == 0 || *sampleCount % *channels != 0 || *rate == 0) {
        napi_throw_range_error(env, nullptr, "invalid PCM shape");
        return false;
    }
    return true;
}

bool createPcmView(const float *left, const float *right, uint64_t frames,
                   uint32_t channels, uint32_t rate, parso_pcm_view_t *view,
                   const float *planes[2]) {
    planes[0] = left;
    planes[1] = right;
    view->size = sizeof(*view);
    view->abi_version = PARSO_ABI_VERSION;
    view->planes = planes;
    view->frames = frames;
    view->channel_count = channels;
    view->sample_rate_hz = rate;
    return true;
}

bool getHandleAndObject(napi_env env, napi_value *argv, parso_engine_t **engine,
                        napi_value *object, size_t objectIndex) {
    if (!getBigIntHandle(env, argv[0], engine)) return false;
    return getObject(env, argv[objectIndex], object, "object");
}

napi_value jsCapabilities(napi_env env, napi_callback_info info) {
    size_t argc = 0; if (!napiOk(env, napi_get_cb_info(env, info, &argc, nullptr, nullptr, nullptr), "capabilities")) return nullptr;
    parso_capabilities_t capabilities{};
    if (!fail(env, parso_capabilities_init(&capabilities), "capability initialization") ||
        !fail(env, parso_capabilities_get(&capabilities), "capability query")) return nullptr;
    napi_value result; if (!napiOk(env, napi_create_object(env, &result), "capabilities result")) return nullptr;
    if (!setU64(env, result, "decodeContainers", capabilities.decode_containers) ||
        !setU64(env, result, "encodeContainers", capabilities.encode_containers) ||
        !setU64(env, result, "readPcmFormats", capabilities.pcm_read_formats) ||
        !setU64(env, result, "writePcmFormats", capabilities.pcm_write_formats) ||
        !setU32(env, result, "maxChannels", capabilities.max_channels) ||
        !setU32(env, result, "maxSampleRateHz", capabilities.max_sample_rate_hz) ||
        !setU64(env, result, "offlineServices", capabilities.offline_services)) return nullptr;
    return result;
}

napi_value jsReadWav(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value argv[1]; if (!napiOk(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr), "WAV read")) return nullptr;
    if (!argCount(env, argc, 1, "WAV read")) return nullptr;
    const uint8_t *data = nullptr; size_t size = 0; if (!getUint8(env, argv[0], &data, &size, "encoded data")) return nullptr;
    parso_pcm_buffer_t output{}; if (!fail(env, parso_pcm_buffer_init(&output), "PCM initialization")) return nullptr;
    parso_status_t status = parso_wav_read(data, size, &output); napi_value result = nullptr;
    if (fail(env, status, "WAV decoding")) pcmResult(env, &output, &result);
    parso_pcm_buffer_release(&output); return result;
}

napi_value jsReadPcm(napi_env env, napi_callback_info info) {
    size_t argc = 4; napi_value argv[4]; if (!napiOk(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr), "raw PCM read")) return nullptr;
    if (!argCount(env, argc, 4, "raw PCM read")) return nullptr;
    const uint8_t *data = nullptr; size_t size = 0; uint32_t rate = 0; uint32_t channels = 0; uint32_t bits = 0;
    if (!getUint8(env, argv[0], &data, &size, "encoded data") || !getU32(env, argv[1], &rate, "sample rate") ||
        !getU32(env, argv[2], &channels, "channel count") || !getU32(env, argv[3], &bits, "bits per sample")) return nullptr;
    parso_pcm_buffer_t output{}; if (!fail(env, parso_pcm_buffer_init(&output), "PCM initialization")) return nullptr;
    parso_status_t status = parso_pcm_read(data, size, rate, channels, bits, &output); napi_value result = nullptr;
    if (fail(env, status, "raw PCM decoding")) pcmResult(env, &output, &result);
    parso_pcm_buffer_release(&output); return result;
}

napi_value jsWriteWav(napi_env env, napi_callback_info info) {
    size_t argc = 5; napi_value argv[5]; if (!napiOk(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr), "WAV write")) return nullptr;
    if (!argCount(env, argc, 3, "WAV write")) return nullptr;
    const float *samples = nullptr; size_t count = 0; uint32_t rate = 0; uint32_t channels = 0;
    if (!parsePcmArgs(env, argv, 0, 1, 2, &samples, &count, &rate, &channels)) return nullptr;
    uint32_t bits = 16; if (argc > 3 && !getU32(env, argv[3], &bits, "bits per sample")) return nullptr;
    uint32_t isFloat = 0; if (argc > 4) { double value = 0; if (!getNumber(env, argv[4], &value, "WAV float flag")) return nullptr; isFloat = value != 0 ? 1u : 0u; }
    parso_pcm_buffer_t input{sizeof(input), PARSO_ABI_VERSION, const_cast<float *>(samples), count / channels, channels, rate};
    parso_bytes_t output{}; if (!fail(env, parso_bytes_init(&output), "byte initialization")) return nullptr;
    parso_status_t status = parso_wav_write(&input, bits, isFloat, &output); napi_value result = nullptr;
    if (fail(env, status, "WAV encoding")) bytesResult(env, &output, &result);
    parso_bytes_release(&output); return result;
}

napi_value jsWritePcm(napi_env env, napi_callback_info info) {
    size_t argc = 4; napi_value argv[4]; if (!napiOk(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr), "raw PCM write")) return nullptr;
    if (!argCount(env, argc, 3, "raw PCM write")) return nullptr;
    const float *samples = nullptr; size_t count = 0; uint32_t rate = 0; uint32_t channels = 0; uint32_t bits = 16;
    if (!parsePcmArgs(env, argv, 0, 1, 2, &samples, &count, &rate, &channels) || (argc > 3 && !getU32(env, argv[3], &bits, "bits per sample"))) return nullptr;
    parso_pcm_buffer_t input{sizeof(input), PARSO_ABI_VERSION, const_cast<float *>(samples), count / channels, channels, rate};
    parso_bytes_t output{}; if (!fail(env, parso_bytes_init(&output), "byte initialization")) return nullptr;
    parso_status_t status = parso_pcm_write(&input, bits, &output); napi_value result = nullptr;
    if (fail(env, status, "raw PCM encoding")) bytesResult(env, &output, &result);
    parso_bytes_release(&output); return result;
}

bool parseOptions(napi_env env, napi_value value, parso_codec_options_t *options) {
    if (!fail(env, parso_codec_options_init(options), "codec-options initialization")) return false;
    return value == nullptr || readOptions(env, value, options);
}

napi_value jsCodecRead(napi_env env, napi_callback_info info) {
    size_t argc = 3; napi_value argv[3]; if (!napiOk(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr), "codec read")) return nullptr;
    if (!argCount(env, argc, 2, "codec read")) return nullptr;
    const uint8_t *data = nullptr; size_t size = 0; uint32_t codec = 0;
    if (!getUint8(env, argv[0], &data, &size, "encoded data") || !getU32(env, argv[1], &codec, "codec")) return nullptr;
    parso_codec_options_t options{}; if (argc > 2 && !parseOptions(env, argv[2], &options)) return nullptr;
    if (argc <= 2 && !parseOptions(env, nullptr, &options)) return nullptr;
    parso_pcm_buffer_t output{}; if (!fail(env, parso_pcm_buffer_init(&output), "PCM initialization")) return nullptr;
    parso_status_t status = parso_codec_read(data, size, codec, &options, &output); napi_value result = nullptr;
    if (fail(env, status, "codec decoding")) pcmResult(env, &output, &result);
    parso_pcm_buffer_release(&output); return result;
}

napi_value jsCodecWrite(napi_env env, napi_callback_info info) {
    size_t argc = 5; napi_value argv[5]; if (!napiOk(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr), "codec write")) return nullptr;
    if (!argCount(env, argc, 4, "codec write")) return nullptr;
    const float *samples = nullptr; size_t count = 0; uint32_t rate = 0; uint32_t channels = 0; uint32_t codec = 0;
    if (!parsePcmArgs(env, argv, 0, 1, 2, &samples, &count, &rate, &channels) || !getU32(env, argv[3], &codec, "codec")) return nullptr;
    parso_codec_options_t options{}; if (argc > 4 && !parseOptions(env, argv[4], &options)) return nullptr;
    if (argc <= 4 && !parseOptions(env, nullptr, &options)) return nullptr;
    parso_pcm_buffer_t input{sizeof(input), PARSO_ABI_VERSION, const_cast<float *>(samples), count / channels, channels, rate};
    parso_bytes_t output{}; if (!fail(env, parso_bytes_init(&output), "byte initialization")) return nullptr;
    parso_status_t status = parso_codec_write(&input, codec, &options, &output); napi_value result = nullptr;
    if (fail(env, status, "codec encoding")) bytesResult(env, &output, &result);
    parso_bytes_release(&output); return result;
}

napi_value jsSrc(napi_env env, napi_callback_info info) {
    size_t argc = 6; napi_value argv[6]; if (!napiOk(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr), "sample-rate conversion")) return nullptr;
    if (!argCount(env, argc, 4, "sample-rate conversion")) return nullptr;
    const float *samples = nullptr; size_t count = 0; uint32_t sourceRate = 0; uint32_t destinationRate = 0; uint32_t channels = 0;
    if (!parsePcmArgs(env, argv, 0, 1, 3, &samples, &count, &sourceRate, &channels) || !getU32(env, argv[2], &destinationRate, "destination sample rate")) return nullptr;
    uint32_t quality = 0; if (argc > 4 && !getU32(env, argv[4], &quality, "SRC quality")) return nullptr;
    parso_src_options_t options{}; if (!fail(env, parso_src_options_init(&options), "SRC-options initialization")) return nullptr;
    options.source_sample_rate_hz = sourceRate; options.destination_sample_rate_hz = destinationRate;
    options.channel_count = channels; options.quality = quality;
    parso_pcm_buffer_t input{sizeof(input), PARSO_ABI_VERSION, const_cast<float *>(samples), count / channels, channels, sourceRate};
    parso_pcm_buffer_t output{}; if (!fail(env, parso_pcm_buffer_init(&output), "PCM initialization")) return nullptr;
    parso_status_t status = parso_src_convert(&input, &options, &output); napi_value result = nullptr;
    if (fail(env, status, "sample-rate conversion")) pcmResult(env, &output, &result);
    parso_pcm_buffer_release(&output); return result;
}

napi_value jsLoudness(napi_env env, napi_callback_info info) {
    size_t argc = 4; napi_value argv[4]; if (!napiOk(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr), "loudness")) return nullptr;
    if (!argCount(env, argc, 3, "loudness")) return nullptr;
    const float *samples = nullptr; size_t count = 0; uint32_t rate = 0; uint32_t channels = 0;
    if (!parsePcmArgs(env, argv, 0, 1, 2, &samples, &count, &rate, &channels)) return nullptr;
    double target = -14.0; if (argc > 3 && !getNumber(env, argv[3], &target, "target LUFS")) return nullptr;
    parso_loudness_options_t options{}; if (!fail(env, parso_loudness_options_init(&options), "loudness-options initialization")) return nullptr; options.target_lufs = target;
    parso_loudness_result_t result{}; if (!fail(env, parso_loudness_result_init(&result), "loudness-result initialization")) return nullptr;
    parso_pcm_buffer_t input{sizeof(input), PARSO_ABI_VERSION, const_cast<float *>(samples), count / channels, channels, rate};
    if (!fail(env, parso_loudness_measure(&input, &options, &result), "loudness measurement")) return nullptr;
    napi_value output; if (!napiOk(env, napi_create_object(env, &output), "loudness result")) return nullptr;
    return setDouble(env, output, "integratedLufs", result.integrated_lufs) && setDouble(env, output, "truePeakDbtp", result.true_peak_dbtp) && setDouble(env, output, "gainToTargetDb", result.gain_to_target_db) && setDouble(env, output, "loudnessRangeLu", result.loudness_range_lu) ? output : nullptr;
}

napi_value jsAnalysis(napi_env env, napi_callback_info info) {
    size_t argc = 4; napi_value argv[4]; if (!napiOk(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr), "analysis")) return nullptr;
    if (!argCount(env, argc, 3, "analysis")) return nullptr;
    const float *samples = nullptr; size_t count = 0; uint32_t rate = 0; uint32_t channels = 0;
    if (!parsePcmArgs(env, argv, 0, 1, 2, &samples, &count, &rate, &channels)) return nullptr;
    parso_analysis_options_t options{}; if (!fail(env, parso_analysis_options_init(&options), "analysis-options initialization")) return nullptr;
    parso_analysis_result_t result{}; if (!fail(env, parso_analysis_result_init(&result), "analysis-result initialization")) return nullptr;
    parso_pcm_buffer_t input{sizeof(input), PARSO_ABI_VERSION, const_cast<float *>(samples), count / channels, channels, rate};
    if (!fail(env, parso_analysis_measure(&input, &options, &result), "analysis measurement")) return nullptr;
    napi_value output; if (!napiOk(env, napi_create_object(env, &output), "analysis result")) return nullptr;
    return setDouble(env, output, "durationSeconds", result.duration_seconds) && setDouble(env, output, "rms", result.rms) && setDouble(env, output, "peak", result.peak) && setDouble(env, output, "bpm", result.bpm) && setDouble(env, output, "bpmConfidence", result.bpm_confidence) ? output : nullptr;
}

napi_value jsKey(napi_env env, napi_callback_info info) {
    size_t argc = 4; napi_value argv[4]; if (!napiOk(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr), "key analysis")) return nullptr;
    if (!argCount(env, argc, 3, "key analysis")) return nullptr;
    const float *samples = nullptr; size_t count = 0; uint32_t rate = 0; uint32_t channels = 0;
    if (!parsePcmArgs(env, argv, 0, 1, 2, &samples, &count, &rate, &channels)) return nullptr;
    parso_key_options_t options{}; if (!fail(env, parso_key_options_init(&options), "key-options initialization")) return nullptr;
    parso_key_result_t result{}; if (!fail(env, parso_key_result_init(&result), "key-result initialization")) return nullptr;
    parso_pcm_buffer_t input{sizeof(input), PARSO_ABI_VERSION, const_cast<float *>(samples), count / channels, channels, rate};
    if (!fail(env, parso_key_measure(&input, &options, &result), "key measurement")) return nullptr;
    napi_value output; if (!napiOk(env, napi_create_object(env, &output), "key result")) return nullptr;
    return setU32(env, output, "tonicPitchClass", result.tonic_pitch_class) && setU32(env, output, "isMinor", result.is_minor) && setU32(env, output, "camelotNumber", result.camelot_number) && setU32(env, output, "camelotLetter", result.camelot_letter) && setDouble(env, output, "confidence", result.confidence) ? output : nullptr;
}

napi_value jsWaveform(napi_env env, napi_callback_info info) {
    size_t argc = 4; napi_value argv[4]; if (!napiOk(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr), "waveform")) return nullptr;
    if (!argCount(env, argc, 4, "waveform")) return nullptr;
    const float *samples = nullptr; size_t count = 0; uint32_t rate = 0; uint32_t channels = 0; uint32_t buckets = 0;
    if (!parsePcmArgs(env, argv, 0, 1, 2, &samples, &count, &rate, &channels) || !getU32(env, argv[3], &buckets, "bucket count")) return nullptr;
    parso_pcm_buffer_t input{sizeof(input), PARSO_ABI_VERSION, const_cast<float *>(samples), count / channels, channels, rate};
    napi_value minimum; float *minimumData = nullptr; napi_value maximum; float *maximumData = nullptr;
    if (!makeFloatArray(env, buckets, &minimum, &minimumData) || !makeFloatArray(env, buckets, &maximum, &maximumData)) return nullptr;
    if (!fail(env, parso_waveform_generate(&input, buckets, minimumData, maximumData), "waveform generation")) return nullptr;
    napi_value output; if (!napiOk(env, napi_create_object(env, &output), "waveform result")) return nullptr;
    return setNamed(env, output, "minimum", minimum) && setNamed(env, output, "maximum", maximum) ? output : nullptr;
}

napi_value jsStructure(napi_env env, napi_callback_info info) {
    size_t argc = 4; napi_value argv[4]; if (!napiOk(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr), "structure")) return nullptr;
    if (!argCount(env, argc, 3, "structure")) return nullptr;
    const float *samples = nullptr; size_t count = 0; uint32_t rate = 0; uint32_t channels = 0;
    if (!parsePcmArgs(env, argv, 0, 1, 2, &samples, &count, &rate, &channels)) return nullptr;
    parso_structure_options_t options{}; if (!fail(env, parso_structure_options_init(&options), "structure-options initialization")) return nullptr;
    uint32_t capacity = 256; if (argc > 3) { napi_value object; if (!getObject(env, argv[3], &object, "structure options")) return nullptr; double value = 0; bool present = false; if (!getOptionalNumber(env, object, "bpm", &value, &present)) return nullptr; if (present) options.bpm = value; if (!getOptionalNumber(env, object, "maxSections", &value, &present)) return nullptr; if (present) capacity = static_cast<uint32_t>(value); }
    std::vector<parso_structure_section_t> sections(capacity); uint32_t countOut = 0;
    parso_pcm_buffer_t input{sizeof(input), PARSO_ABI_VERSION, const_cast<float *>(samples), count / channels, channels, rate};
    if (!fail(env, parso_structure_measure(&input, &options, sections.data(), capacity, &countOut), "structure measurement")) return nullptr;
    napi_value output; if (!napiOk(env, napi_create_array_with_length(env, countOut, &output), "structure result")) return nullptr;
    const char *kinds[] = {"intro", "buildup", "drop", "verse", "chorus", "breakdown", "outro", "unknown"};
    for (uint32_t index = 0; index < countOut; ++index) { napi_value item; napi_create_object(env, &item); setDouble(env, item, "startSeconds", sections[index].start_seconds); napi_value kind; napi_create_string_utf8(env, kinds[std::min<uint32_t>(sections[index].kind, 7)], NAPI_AUTO_LENGTH, &kind); setNamed(env, item, "kind", kind); setU32(env, item, "bar", sections[index].bar); setDouble(env, item, "energy", sections[index].energy); setDouble(env, item, "confidence", sections[index].confidence); napi_set_element(env, output, index, item); }
    return output;
}

bool controlArray(napi_env env, napi_value object, const char *name, float *target, size_t count) {
    napi_value value; if (napi_get_named_property(env, object, name, &value) != napi_ok) return true;
    napi_valuetype type; if (!napiOk(env, napi_typeof(env, value, &type), name)) return false;
    if (type == napi_undefined || type == napi_null) return true;
    bool isArray = false; napi_is_array(env, value, &isArray); if (!isArray) { napi_throw_type_error(env, nullptr, name); return false; }
    uint32_t length = 0; napi_get_array_length(env, value, &length); if (length != count) { napi_throw_range_error(env, nullptr, name); return false; }
    for (size_t index = 0; index < count; ++index) { napi_value item; napi_get_element(env, value, static_cast<uint32_t>(index), &item); double number = 0; if (!getNumber(env, item, &number, name)) return false; target[index] = static_cast<float>(number); }
    return true;
}

bool controlScalar(napi_env env, napi_value object, const char *name, float *target) {
    double number = 0; bool present = false; if (!getOptionalNumber(env, object, name, &number, &present)) return false; if (present) *target = static_cast<float>(number); return true;
}

napi_value jsEngineCreate(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value argv[1]; if (!napiOk(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr), "engine creation")) return nullptr;
    parso_engine_options_t options{}; if (!fail(env, parso_engine_options_init(&options), "engine-options initialization")) return nullptr;
    if (argc > 0) { napi_value object; if (!getObject(env, argv[0], &object, "engine options")) return nullptr; double value = 0; bool present = false; if (!getOptionalNumber(env, object, "sampleRateHz", &value, &present)) return nullptr; if (present) options.sample_rate_hz = static_cast<uint32_t>(value); if (!getOptionalNumber(env, object, "maxFrames", &value, &present)) return nullptr; if (present) options.max_frames = static_cast<uint32_t>(value); if (!getOptionalNumber(env, object, "deckCount", &value, &present)) return nullptr; if (present) options.deck_count = static_cast<uint32_t>(value); if (!getOptionalNumber(env, object, "isolatorProfile", &value, &present)) return nullptr; if (present) options.isolator_profile = static_cast<uint32_t>(value); }
    parso_engine_t *engine = nullptr; if (!fail(env, parso_engine_create(&options, &engine), "engine creation")) return nullptr;
    napi_value result; if (!napiOk(env, napi_create_bigint_uint64(env, static_cast<uint64_t>(reinterpret_cast<uintptr_t>(engine)), &result), "engine handle")) { parso_engine_destroy(&engine); return nullptr; }
    return result;
}

napi_value jsEngineDestroy(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value argv[1]; if (!napiOk(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr), "engine destruction")) return nullptr; if (!argCount(env, argc, 1, "engine destruction")) return nullptr; parso_engine_t *engine = nullptr; if (!getBigIntHandle(env, argv[0], &engine)) return nullptr; if (!fail(env, parso_engine_destroy(&engine), "engine destruction")) return nullptr; return nullptr;
}

napi_value jsEngineSetControl(napi_env env, napi_callback_info info) {
    size_t argc = 2; napi_value argv[2]; if (!napiOk(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr), "control")) return nullptr; if (!argCount(env, argc, 2, "control")) return nullptr; parso_engine_t *engine = nullptr; napi_value object; if (!getHandleAndObject(env, argv, &engine, &object, 1)) return nullptr; parso_control_t control{}; if (!fail(env, parso_control_init(&control), "control initialization")) return nullptr;
    if (!controlScalar(env, object, "crossfader", &control.crossfader) || !controlScalar(env, object, "xfadeCurve", &control.xfade_curve) || !controlScalar(env, object, "masterLevel", &control.master_level) || !controlScalar(env, object, "limiterCeilingDb", &control.limiter_ceiling_db) || !controlScalar(env, object, "limiterEnabled", &control.limiter_enabled) || !controlScalar(env, object, "micLevel", &control.mic_level) || !controlScalar(env, object, "beatfxKind", &control.beatfx_kind) || !controlScalar(env, object, "beatfxBeats", &control.beatfx_beats) || !controlScalar(env, object, "beatfxDepth", &control.beatfx_depth) || !controlScalar(env, object, "beatfxAssign", &control.beatfx_assign) || !controlScalar(env, object, "beatfxOn", &control.beatfx_on) || !controlScalar(env, object, "masterReverbSend", &control.master_reverb_send) || !controlScalar(env, object, "masterEqLow", &control.master_eq_low) || !controlScalar(env, object, "masterEqMid", &control.master_eq_mid) || !controlScalar(env, object, "masterEqHigh", &control.master_eq_high) || !controlArray(env, object, "xfadeAssign", control.xfade_assign, PARSO_MAX_DECKS) || !controlArray(env, object, "fader", control.fader, PARSO_MAX_DECKS) || !controlArray(env, object, "trim", control.trim, PARSO_MAX_DECKS) || !controlArray(env, object, "eqLow", control.eq_low, PARSO_MAX_DECKS) || !controlArray(env, object, "eqMid", control.eq_mid, PARSO_MAX_DECKS) || !controlArray(env, object, "eqHigh", control.eq_high, PARSO_MAX_DECKS) || !controlArray(env, object, "colorAmount", control.color_amount, PARSO_MAX_DECKS) || !controlArray(env, object, "colorKind", control.color_kind, PARSO_MAX_DECKS) || !controlArray(env, object, "colorParam", control.color_param, PARSO_MAX_DECKS)) return nullptr;
    if (!fail(env, parso_engine_set_control(engine, &control), "setting control")) return nullptr;
    return nullptr;
}

napi_value jsEngineSetBuffer(napi_env env, napi_callback_info info, bool microphone) {
    size_t argc = 6; napi_value argv[6]; if (!napiOk(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr), "PCM buffer")) return nullptr; if (!argCount(env, argc, microphone ? 5 : 6, "PCM buffer")) return nullptr;
    parso_engine_t *engine = nullptr; if (!getBigIntHandle(env, argv[0], &engine)) return nullptr; uint32_t deck = 0; size_t leftCount = 0; size_t rightCount = 0; const float *left = nullptr; const float *right = nullptr; uint32_t frames = 0; uint32_t rate = 0;
    size_t leftIndex = microphone ? 1 : 2; size_t rightIndex = microphone ? 2 : 3; size_t framesIndex = microphone ? 3 : 4; size_t rateIndex = microphone ? 4 : 5;
    if (!microphone && !getU32(env, argv[1], &deck, "deck")) return nullptr;
    if (!getFloat32(env, argv[leftIndex], &left, &leftCount, "left samples")) return nullptr;
    napi_valuetype rightType; napi_typeof(env, argv[rightIndex], &rightType);
    if (rightType != napi_null && rightType != napi_undefined &&
        !getFloat32(env, argv[rightIndex], &right, &rightCount, "right samples")) return nullptr;
    if (!getU32(env, argv[framesIndex], &frames, "frames") ||
        !getU32(env, argv[rateIndex], &rate, "sample rate")) return nullptr;
    if (leftCount < frames || (right != nullptr && rightCount < frames) ||
        frames == 0 || rate == 0) {
        napi_throw_range_error(env, nullptr, "invalid PCM buffer");
        return nullptr;
    }
    const float *planes[2] = {left, right}; parso_pcm_view_t view{}; createPcmView(left, right, frames, right == nullptr ? 1u : 2u, rate, &view, planes); parso_status_t status = microphone ? parso_engine_set_mic_buffer(engine, &view) : parso_engine_set_deck_buffer(engine, deck, &view); if (!fail(env, status, microphone ? "setting microphone buffer" : "setting deck buffer")) return nullptr; return nullptr;
}

napi_value jsEnginePostCommand(napi_env env, napi_callback_info info) {
    size_t argc = 4; napi_value argv[4]; if (!napiOk(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr), "command")) return nullptr; if (!argCount(env, argc, 3, "command")) return nullptr; parso_engine_t *engine = nullptr; if (!getBigIntHandle(env, argv[0], &engine)) return nullptr; uint32_t type = 0; int32_t deck = -1; if (!getU32(env, argv[1], &type, "command type") || !getI32(env, argv[2], &deck, "deck")) return nullptr; parso_command_t command{}; if (!fail(env, parso_command_init(&command), "command initialization")) return nullptr; command.type = type; command.deck = deck; if (argc > 3) { napi_value object; if (!getObject(env, argv[3], &object, "command payload")) return nullptr; double value = 0; bool present = false; if (!getOptionalNumber(env, object, "i0", &value, &present)) return nullptr; if (present) command.i0 = static_cast<int32_t>(value); if (!getOptionalNumber(env, object, "i1", &value, &present)) return nullptr; if (present) command.i1 = static_cast<int32_t>(value); if (!getOptionalNumber(env, object, "i2", &value, &present)) return nullptr; if (present) command.i2 = static_cast<int32_t>(value); if (!getOptionalNumber(env, object, "f0", &value, &present)) return nullptr; if (present) command.f0 = static_cast<float>(value); if (!getOptionalNumber(env, object, "f1", &value, &present)) return nullptr; if (present) command.f1 = static_cast<float>(value); }
    if (!fail(env, parso_engine_post_command(engine, &command), "posting command")) return nullptr;
    return nullptr;
}

napi_value renderBus(napi_env env, parso_engine_t *engine, uint32_t frames, parso_status_t (*render)(parso_engine_t *, const parso_output_view_t *), const char *operation) {
    napi_value left; float *leftData = nullptr; napi_value right; float *rightData = nullptr; if (!makeFloatArray(env, frames, &left, &leftData) || !makeFloatArray(env, frames, &right, &rightData)) return nullptr; parso_output_view_t output{sizeof(output), PARSO_ABI_VERSION, leftData, rightData, frames, 0}; if (!fail(env, render(engine, &output), operation)) return nullptr; napi_value result; if (!napiOk(env, napi_create_object(env, &result), "render result")) return nullptr; return setNamed(env, result, "left", left) && setNamed(env, result, "right", right) ? result : nullptr;
}

napi_value jsEngineRender(napi_env env, napi_callback_info info, parso_status_t (*render)(parso_engine_t *, const parso_output_view_t *), const char *operation) {
    size_t argc = 2; napi_value argv[2]; if (!napiOk(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr), operation)) return nullptr; if (!argCount(env, argc, 2, operation)) return nullptr; parso_engine_t *engine = nullptr; uint32_t frames = 0; if (!getBigIntHandle(env, argv[0], &engine) || !getU32(env, argv[1], &frames, "frames")) return nullptr; return renderBus(env, engine, frames, render, operation);
}

napi_value jsRender(napi_env env, napi_callback_info info) { return jsEngineRender(env, info, parso_engine_render, "engine render"); }
napi_value jsRenderMonitor(napi_env env, napi_callback_info info) { return jsEngineRender(env, info, parso_engine_render_monitor, "monitor render"); }
napi_value jsRenderBooth(napi_env env, napi_callback_info info) { return jsEngineRender(env, info, parso_engine_render_booth, "booth render"); }

napi_value jsEngineStats(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value argv[1]; if (!napiOk(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr), "stats")) return nullptr; if (!argCount(env, argc, 1, "stats")) return nullptr; parso_engine_t *engine = nullptr; if (!getBigIntHandle(env, argv[0], &engine)) return nullptr; parso_stats_t stats{}; if (!fail(env, parso_stats_init(&stats), "stats initialization") || !fail(env, parso_engine_get_stats(engine, &stats), "stats query")) return nullptr; napi_value result; napi_create_object(env, &result); setU64(env, result, "masterFrame", stats.master_frame); setU64(env, result, "starvedFrames", stats.starved_frames); setU32(env, result, "deckCount", stats.deck_count); return result;
}

napi_value jsEngineEvents(napi_env env, napi_callback_info info) {
    size_t argc = 2; napi_value argv[2]; if (!napiOk(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr), "events")) return nullptr; if (!argCount(env, argc, 1, "events")) return nullptr; parso_engine_t *engine = nullptr; if (!getBigIntHandle(env, argv[0], &engine)) return nullptr; uint32_t max = 64; if (argc > 1 && !getU32(env, argv[1], &max, "max events")) return nullptr; std::vector<parso_event_t> events(max); for (auto &event : events) if (!fail(env, parso_event_init(&event), "event initialization")) return nullptr; uint32_t count = 0; if (!fail(env, parso_engine_poll_events(engine, events.data(), max, &count), "event polling")) return nullptr; napi_value output; napi_create_array_with_length(env, count, &output); for (uint32_t index = 0; index < count; ++index) { napi_value item; napi_create_object(env, &item); setU32(env, item, "type", events[index].type); setI32(env, item, "deck", events[index].deck); setU64(env, item, "frame", static_cast<uint64_t>(events[index].frame)); setDouble(env, item, "f0", events[index].f0); setDouble(env, item, "f1", events[index].f1); napi_set_element(env, output, index, item); } return output;
}

napi_value jsRecordActive(napi_env env, napi_callback_info info) { size_t argc = 2; napi_value argv[2]; if (!napiOk(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr), "record activation")) return nullptr; if (!argCount(env, argc, 2, "record activation")) return nullptr; parso_engine_t *engine = nullptr; if (!getBigIntHandle(env, argv[0], &engine)) return nullptr; double active = 0; if (!getNumber(env, argv[1], &active, "active")) return nullptr; if (!fail(env, parso_engine_record_set_active(engine, active != 0 ? 1u : 0u), "record activation")) return nullptr; return nullptr; }
napi_value jsRecordDrain(napi_env env, napi_callback_info info) { size_t argc = 2; napi_value argv[2]; if (!napiOk(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr), "record drain")) return nullptr; if (!argCount(env, argc, 2, "record drain")) return nullptr; parso_engine_t *engine = nullptr; uint32_t max = 0; if (!getBigIntHandle(env, argv[0], &engine) || !getU32(env, argv[1], &max, "max frames")) return nullptr; napi_value left; float *leftData = nullptr; napi_value right; float *rightData = nullptr; if (!makeFloatArray(env, max, &left, &leftData) || !makeFloatArray(env, max, &right, &rightData)) return nullptr; uint32_t count = 0; if (!fail(env, parso_engine_record_drain(engine, leftData, rightData, max, &count), "record drain")) return nullptr; napi_value result; napi_create_object(env, &result); setNamed(env, result, "left", left); setNamed(env, result, "right", right); if (count != max) { /* Typed arrays are intentionally bounded; the count is exposed for callers. */ } setU32(env, result, "frames", count); return result; }
napi_value jsRecordDropped(napi_env env, napi_callback_info info) { size_t argc = 1; napi_value argv[1]; if (!napiOk(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr), "record dropped frames")) return nullptr; if (!argCount(env, argc, 1, "record dropped frames")) return nullptr; parso_engine_t *engine = nullptr; if (!getBigIntHandle(env, argv[0], &engine)) return nullptr; uint64_t count = 0; if (!fail(env, parso_engine_record_dropped_frames(engine, &count), "record dropped frames")) return nullptr; if (count > static_cast<uint64_t>(9007199254740991.0)) { napi_throw_range_error(env, nullptr, "record dropped frames exceeds JavaScript safe range"); return nullptr; } napi_value result; napi_create_double(env, static_cast<double>(count), &result); return result; }
napi_value jsRecordReset(napi_env env, napi_callback_info info) { size_t argc = 1; napi_value argv[1]; if (!napiOk(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr), "record reset")) return nullptr; if (!argCount(env, argc, 1, "record reset")) return nullptr; parso_engine_t *engine = nullptr; if (!getBigIntHandle(env, argv[0], &engine)) return nullptr; if (!fail(env, parso_engine_record_reset(engine), "record reset")) return nullptr; return nullptr; }

void define(napi_env env, napi_value exports, const char *name, napi_callback callback) {
    napi_property_descriptor descriptor{name, nullptr, callback, nullptr, nullptr, nullptr, napi_default, nullptr};
    napi_define_properties(env, exports, 1, &descriptor);
}

napi_value init(napi_env env, napi_value exports) {
    napi_value version; napi_create_uint32(env, 1, &version); setNamed(env, exports, "abiVersion", version);
    define(env, exports, "capabilities", jsCapabilities); define(env, exports, "readWav", jsReadWav); define(env, exports, "readPcm", jsReadPcm); define(env, exports, "writeWav", jsWriteWav); define(env, exports, "writePcm", jsWritePcm); define(env, exports, "codecRead", jsCodecRead); define(env, exports, "codecWrite", jsCodecWrite); define(env, exports, "convertSampleRate", jsSrc); define(env, exports, "measureLoudness", jsLoudness); define(env, exports, "analyze", jsAnalysis); define(env, exports, "estimateKey", jsKey); define(env, exports, "structure", jsStructure); define(env, exports, "waveform", jsWaveform); define(env, exports, "engineCreate", jsEngineCreate); define(env, exports, "engineDestroy", jsEngineDestroy); define(env, exports, "engineSetControl", jsEngineSetControl); define(env, exports, "engineSetDeckBuffer", [](napi_env e, napi_callback_info i) { return jsEngineSetBuffer(e, i, false); }); define(env, exports, "engineSetMicBuffer", [](napi_env e, napi_callback_info i) { return jsEngineSetBuffer(e, i, true); }); define(env, exports, "enginePostCommand", jsEnginePostCommand); define(env, exports, "engineRender", jsRender); define(env, exports, "engineRenderMonitor", jsRenderMonitor); define(env, exports, "engineRenderBooth", jsRenderBooth); define(env, exports, "engineStats", jsEngineStats); define(env, exports, "enginePollEvents", jsEngineEvents); define(env, exports, "engineRecordSetActive", jsRecordActive); define(env, exports, "engineRecordDrain", jsRecordDrain); define(env, exports, "engineRecordDroppedFrames", jsRecordDropped); define(env, exports, "engineRecordReset", jsRecordReset);
    return exports;
}

} // namespace

NAPI_MODULE(NODE_GYP_MODULE_NAME, init)
