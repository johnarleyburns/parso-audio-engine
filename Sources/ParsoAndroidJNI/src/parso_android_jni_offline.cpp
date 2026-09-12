#include "parso.h"

#include <jni.h>

#include <cmath>
#include <cstdint>
#include <limits>
#include <vector>

namespace {

bool makePCMInput(JNIEnv *env, jobject buffer, jint frames, jint sampleRateHz,
                  jint channelCount, parso_pcm_buffer_t *out) noexcept {
    if (!env || !buffer || !out || frames <= 0 || sampleRateHz <= 0 ||
        (channelCount != 1 && channelCount != 2) ||
        static_cast<uint64_t>(frames) > std::numeric_limits<uint64_t>::max() /
            static_cast<uint64_t>(channelCount)) return false;
    const uint64_t samples = static_cast<uint64_t>(frames) *
                             static_cast<uint64_t>(channelCount);
    if (samples > std::numeric_limits<uint64_t>::max() / sizeof(float)) return false;
    void *address = env->GetDirectBufferAddress(buffer);
    const jlong capacity = env->GetDirectBufferCapacity(buffer);
    const uint64_t requiredBytes = samples * sizeof(float);
    if (!address || capacity < 0 || static_cast<uint64_t>(capacity) < requiredBytes ||
        parso_pcm_buffer_init(out) != PARSO_STATUS_OK) return false;
    out->samples = static_cast<float *>(address);
    out->frames = static_cast<uint64_t>(frames);
    out->channel_count = static_cast<uint32_t>(channelCount);
    out->sample_rate_hz = static_cast<uint32_t>(sampleRateHz);
    return true;
}

} // namespace

extern "C" {

JNIEXPORT jdoubleArray JNICALL Java_com_parsoaudio_ParsoNative_nativeAnalysisSummary(
    JNIEnv *env, jclass, jobject samples, jint frames, jint sampleRateHz, jint channelCount
) {
    parso_pcm_buffer_t input{};
    if (!makePCMInput(env, samples, frames, sampleRateHz, channelCount, &input)) return nullptr;
    parso_analysis_options_t options{};
    parso_analysis_result_t result{};
    if (parso_analysis_options_init(&options) != PARSO_STATUS_OK ||
        parso_analysis_result_init(&result) != PARSO_STATUS_OK ||
        parso_analysis_measure(&input, &options, &result) != PARSO_STATUS_OK) return nullptr;
    const jdouble values[] = {
        result.duration_seconds, result.rms, result.peak, result.bpm, result.bpm_confidence
    };
    jdoubleArray output = env->NewDoubleArray(5);
    if (output) env->SetDoubleArrayRegion(output, 0, 5, values);
    return output;
}

JNIEXPORT jdoubleArray JNICALL Java_com_parsoaudio_ParsoNative_nativeKey(
    JNIEnv *env, jclass, jobject samples, jint frames, jint sampleRateHz, jint channelCount
) {
    parso_pcm_buffer_t input{};
    if (!makePCMInput(env, samples, frames, sampleRateHz, channelCount, &input)) return nullptr;
    parso_key_options_t options{};
    parso_key_result_t result{};
    if (parso_key_options_init(&options) != PARSO_STATUS_OK ||
        parso_key_result_init(&result) != PARSO_STATUS_OK ||
        parso_key_measure(&input, &options, &result) != PARSO_STATUS_OK) return nullptr;
    const jdouble values[] = {
        static_cast<jdouble>(result.tonic_pitch_class), static_cast<jdouble>(result.is_minor),
        static_cast<jdouble>(result.camelot_number), static_cast<jdouble>(result.camelot_letter),
        result.confidence
    };
    jdoubleArray output = env->NewDoubleArray(5);
    if (output) env->SetDoubleArrayRegion(output, 0, 5, values);
    return output;
}

JNIEXPORT jdoubleArray JNICALL Java_com_parsoaudio_ParsoNative_nativeStructure(
    JNIEnv *env, jclass, jobject samples, jint frames, jint sampleRateHz, jint channelCount,
    jdouble bpm, jint maxSections
) {
    parso_pcm_buffer_t input{};
    if (!makePCMInput(env, samples, frames, sampleRateHz, channelCount, &input) ||
        maxSections < 1 || maxSections > 4096) return nullptr;
    parso_structure_options_t options{};
    if (parso_structure_options_init(&options) != PARSO_STATUS_OK) return nullptr;
    options.bpm = bpm;
    options.max_sections = static_cast<uint32_t>(maxSections);
    std::vector<parso_structure_section_t> sections(static_cast<size_t>(maxSections));
    uint32_t count = 0;
    if (parso_structure_measure(&input, &options, sections.data(),
                                static_cast<uint32_t>(maxSections), &count) != PARSO_STATUS_OK) {
        return nullptr;
    }
    jdoubleArray output = env->NewDoubleArray(static_cast<jsize>(count * 5u));
    if (!output) return nullptr;
    std::vector<jdouble> values(static_cast<size_t>(count) * 5u);
    for (uint32_t index = 0; index < count; ++index) {
        const parso_structure_section_t &section = sections[index];
        values[index * 5u] = section.start_seconds;
        values[index * 5u + 1u] = static_cast<jdouble>(section.kind);
        values[index * 5u + 2u] = static_cast<jdouble>(section.bar);
        values[index * 5u + 3u] = section.energy;
        values[index * 5u + 4u] = section.confidence;
    }
    env->SetDoubleArrayRegion(output, 0, static_cast<jsize>(values.size()), values.data());
    return output;
}

JNIEXPORT jbyteArray JNICALL Java_com_parsoaudio_ParsoNative_nativeEncodeOggVorbis(
    JNIEnv *env, jclass, jobject samples, jint frames, jint sampleRateHz,
    jint channelCount, jint bitrateKbps
) {
    parso_pcm_buffer_t input{};
    if (!makePCMInput(env, samples, frames, sampleRateHz, channelCount, &input) ||
        bitrateKbps < 8 || bitrateKbps > 512) return nullptr;
    parso_codec_options_t options{};
    parso_bytes_t output{};
    if (parso_codec_options_init(&options) != PARSO_STATUS_OK ||
        parso_bytes_init(&output) != PARSO_STATUS_OK) return nullptr;
    options.bitrate_kbps = static_cast<uint32_t>(bitrateKbps);
    if (parso_codec_write(&input, PARSO_CODEC_OGG_VORBIS, &options, &output) != PARSO_STATUS_OK ||
        output.size_bytes > static_cast<uint64_t>(std::numeric_limits<jsize>::max())) {
        parso_bytes_release(&output);
        return nullptr;
    }
    jbyteArray encoded = env->NewByteArray(static_cast<jsize>(output.size_bytes));
    if (encoded) {
        env->SetByteArrayRegion(encoded, 0, static_cast<jsize>(output.size_bytes),
                                reinterpret_cast<const jbyte *>(output.data));
    }
    parso_bytes_release(&output);
    return encoded;
}

JNIEXPORT jobject JNICALL Java_com_parsoaudio_ParsoNative_nativeDecodeOggVorbis(
    JNIEnv *env, jclass, jbyteArray encoded
) {
    if (!env || !encoded) return nullptr;
    const jsize encodedSize = env->GetArrayLength(encoded);
    if (encodedSize <= 0) return nullptr;
    jboolean isCopy = JNI_FALSE;
    jbyte *encodedData = env->GetByteArrayElements(encoded, &isCopy);
    if (!encodedData) return nullptr;
    parso_codec_options_t options{};
    parso_pcm_buffer_t output{};
    const bool initialized = parso_codec_options_init(&options) == PARSO_STATUS_OK &&
        parso_pcm_buffer_init(&output) == PARSO_STATUS_OK;
    const parso_status_t status = initialized
        ? parso_codec_read(reinterpret_cast<const uint8_t *>(encodedData),
                           static_cast<uint64_t>(encodedSize), PARSO_CODEC_OGG_VORBIS,
                           &options, &output)
        : PARSO_STATUS_INTERNAL;
    env->ReleaseByteArrayElements(encoded, encodedData, JNI_ABORT);
    if (status != PARSO_STATUS_OK || output.frames == 0 || output.channel_count < 1 ||
        output.channel_count > 2 || output.frames >
            static_cast<uint64_t>(std::numeric_limits<jsize>::max()) / output.channel_count) {
        parso_pcm_buffer_release(&output);
        return nullptr;
    }
    const uint64_t sampleCount = output.frames * output.channel_count;
    if (sampleCount > static_cast<uint64_t>(std::numeric_limits<jsize>::max())) {
        parso_pcm_buffer_release(&output);
        return nullptr;
    }
    jfloatArray samples = env->NewFloatArray(static_cast<jsize>(sampleCount));
    if (!samples) {
        parso_pcm_buffer_release(&output);
        return nullptr;
    }
    env->SetFloatArrayRegion(samples, 0, static_cast<jsize>(sampleCount), output.samples);
    jclass decodedClass = env->FindClass("com/parsoaudio/DecodedVorbis");
    if (!decodedClass) {
        parso_pcm_buffer_release(&output);
        return nullptr;
    }
    jmethodID constructor = env->GetMethodID(decodedClass, "<init>", "([FIII)V");
    if (!constructor) {
        parso_pcm_buffer_release(&output);
        return nullptr;
    }
    jobject decoded = env->NewObject(decodedClass, constructor, samples,
                                     static_cast<jint>(output.frames),
                                     static_cast<jint>(output.sample_rate_hz),
                                     static_cast<jint>(output.channel_count));
    parso_pcm_buffer_release(&output);
    return decoded;
}

JNIEXPORT jfloatArray JNICALL Java_com_parsoaudio_ParsoNative_nativeConvertSampleRate(
    JNIEnv *env, jclass, jobject samples, jint frames, jint sourceSampleRateHz,
    jint destinationSampleRateHz, jint channelCount, jint quality
) {
    parso_pcm_buffer_t input{};
    if (!makePCMInput(env, samples, frames, sourceSampleRateHz, channelCount, &input) ||
        destinationSampleRateHz <= 0 || quality < 0 || quality > 2) return nullptr;
    parso_src_options_t options{};
    parso_pcm_buffer_t output{};
    if (parso_src_options_init(&options) != PARSO_STATUS_OK ||
        parso_pcm_buffer_init(&output) != PARSO_STATUS_OK) return nullptr;
    options.destination_sample_rate_hz = static_cast<uint32_t>(destinationSampleRateHz);
    options.quality = static_cast<uint32_t>(quality);
    if (parso_src_convert(&input, &options, &output) != PARSO_STATUS_OK ||
        output.frames > static_cast<uint64_t>(std::numeric_limits<jsize>::max()) /
            output.channel_count) {
        parso_pcm_buffer_release(&output);
        return nullptr;
    }
    const uint64_t sampleCount = output.frames * output.channel_count;
    jfloatArray converted = env->NewFloatArray(static_cast<jsize>(sampleCount));
    if (converted) env->SetFloatArrayRegion(converted, 0, static_cast<jsize>(sampleCount), output.samples);
    parso_pcm_buffer_release(&output);
    return converted;
}

JNIEXPORT jdoubleArray JNICALL Java_com_parsoaudio_ParsoNative_nativeMeasureLoudness(
    JNIEnv *env, jclass, jobject samples, jint frames, jint sampleRateHz,
    jint channelCount, jdouble targetLufs
) {
    parso_pcm_buffer_t input{};
    if (!makePCMInput(env, samples, frames, sampleRateHz, channelCount, &input) ||
        !std::isfinite(targetLufs)) return nullptr;
    parso_loudness_options_t options{};
    parso_loudness_result_t result{};
    if (parso_loudness_options_init(&options) != PARSO_STATUS_OK ||
        parso_loudness_result_init(&result) != PARSO_STATUS_OK) return nullptr;
    options.target_lufs = targetLufs;
    if (parso_loudness_measure(&input, &options, &result) != PARSO_STATUS_OK) return nullptr;
    const jdouble values[] = {
        result.integrated_lufs, result.true_peak_dbtp,
        result.gain_to_target_db, result.loudness_range_lu
    };
    jdoubleArray output = env->NewDoubleArray(4);
    if (output) env->SetDoubleArrayRegion(output, 0, 4, values);
    return output;
}


} // extern "C"

