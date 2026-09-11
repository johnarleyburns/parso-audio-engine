#include "parso.h"

#include <jni.h>

#include <cstdint>
#include <limits>
#include <vector>

namespace {

parso_engine_t *fromHandle(jlong handle) noexcept {
    return reinterpret_cast<parso_engine_t *>(static_cast<uintptr_t>(handle));
}

jlong toHandle(parso_engine_t *engine) noexcept {
    return static_cast<jlong>(reinterpret_cast<uintptr_t>(engine));
}

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

JNIEXPORT jlong JNICALL Java_com_parsoaudio_ParsoNative_nativeCreate(
    JNIEnv *, jclass, jint sampleRateHz, jint maxFrames, jint deckCount
) {
    if (sampleRateHz <= 0 || maxFrames <= 0 || deckCount < 2 || deckCount > 4) return 0;
    parso_engine_options_t options{};
    if (parso_engine_options_init(&options) != PARSO_STATUS_OK) return 0;
    options.sample_rate_hz = static_cast<uint32_t>(sampleRateHz);
    options.max_frames = static_cast<uint32_t>(maxFrames);
    options.deck_count = static_cast<uint32_t>(deckCount);
    parso_engine_t *engine = nullptr;
    return parso_engine_create(&options, &engine) == PARSO_STATUS_OK
        ? toHandle(engine) : 0;
}

JNIEXPORT void JNICALL Java_com_parsoaudio_ParsoNative_nativeDestroy(
    JNIEnv *, jclass, jlong handle
) {
    parso_engine_t *engine = fromHandle(handle);
    if (engine) parso_engine_destroy(&engine);
}

JNIEXPORT jboolean JNICALL Java_com_parsoaudio_ParsoNative_nativeSetDeckBuffer(
    JNIEnv *env, jclass, jlong handle, jint deck, jobject leftBuffer,
    jobject rightBuffer, jint frames, jint sampleRateHz, jint channelCount
) {
    parso_engine_t *engine = fromHandle(handle);
    if (!engine || !env || deck < 0 || deck >= 4 || frames <= 0 || sampleRateHz <= 0 ||
        (channelCount != 1 && channelCount != 2) || !leftBuffer ||
        (channelCount == 2 && !rightBuffer)) return JNI_FALSE;
    void *leftAddress = env->GetDirectBufferAddress(leftBuffer);
    const jlong leftCapacity = env->GetDirectBufferCapacity(leftBuffer);
    const jlong requiredBytes = static_cast<jlong>(frames) * static_cast<jlong>(sizeof(float));
    if (!leftAddress || leftCapacity < requiredBytes) return JNI_FALSE;
    const void *rightAddress = nullptr;
    if (channelCount == 2) {
        rightAddress = env->GetDirectBufferAddress(rightBuffer);
        const jlong rightCapacity = env->GetDirectBufferCapacity(rightBuffer);
        if (!rightAddress || rightCapacity < requiredBytes) return JNI_FALSE;
    }
    const float *planes[] = {
        static_cast<const float *>(leftAddress),
        static_cast<const float *>(rightAddress)
    };
    parso_pcm_view_t view{};
    if (parso_pcm_view_init(&view) != PARSO_STATUS_OK) return JNI_FALSE;
    view.planes = planes;
    view.frames = static_cast<uint64_t>(frames);
    view.channel_count = static_cast<uint32_t>(channelCount);
    view.sample_rate_hz = static_cast<uint32_t>(sampleRateHz);
    return parso_engine_set_deck_buffer(engine, static_cast<uint32_t>(deck), &view) == PARSO_STATUS_OK
        ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL Java_com_parsoaudio_ParsoNative_nativePlay(
    JNIEnv *, jclass, jlong handle, jint deck
) {
    if (!fromHandle(handle) || deck < 0 || deck >= 4) return JNI_FALSE;
    parso_command_t command{};
    if (parso_command_init(&command) != PARSO_STATUS_OK) return JNI_FALSE;
    command.type = PARSO_COMMAND_PLAY;
    command.deck = deck;
    return parso_engine_post_command(fromHandle(handle), &command) == PARSO_STATUS_OK
        ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL Java_com_parsoaudio_ParsoNative_nativePause(
    JNIEnv *, jclass, jlong handle, jint deck
) {
    if (!fromHandle(handle) || deck < 0 || deck >= 4) return JNI_FALSE;
    parso_command_t command{};
    if (parso_command_init(&command) != PARSO_STATUS_OK) return JNI_FALSE;
    command.type = PARSO_COMMAND_PAUSE;
    command.deck = deck;
    return parso_engine_post_command(fromHandle(handle), &command) == PARSO_STATUS_OK
        ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jint JNICALL Java_com_parsoaudio_ParsoNative_nativeRender(
    JNIEnv *env, jclass, jlong handle, jobject leftBuffer, jobject rightBuffer, jint frames
) {
    if (!fromHandle(handle) || !leftBuffer || !rightBuffer || frames <= 0) return -1;
    void *leftAddress = env->GetDirectBufferAddress(leftBuffer);
    void *rightAddress = env->GetDirectBufferAddress(rightBuffer);
    const jlong leftCapacity = env->GetDirectBufferCapacity(leftBuffer);
    const jlong rightCapacity = env->GetDirectBufferCapacity(rightBuffer);
    if (!leftAddress || !rightAddress || leftCapacity < frames * static_cast<jlong>(sizeof(float)) ||
        rightCapacity < frames * static_cast<jlong>(sizeof(float))) return -1;
    parso_output_view_t output{};
    if (parso_output_view_init(&output) != PARSO_STATUS_OK) return -1;
    output.left = static_cast<float *>(leftAddress);
    output.right = static_cast<float *>(rightAddress);
    output.frames = static_cast<uint32_t>(frames);
    return parso_engine_render(fromHandle(handle), &output) == PARSO_STATUS_OK ? frames : -1;
}

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

} // extern "C"
