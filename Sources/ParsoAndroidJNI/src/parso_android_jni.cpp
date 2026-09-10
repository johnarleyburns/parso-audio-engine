#include "parso.h"

#include <jni.h>

#include <cstdint>

namespace {

parso_engine_t *fromHandle(jlong handle) noexcept {
    return reinterpret_cast<parso_engine_t *>(static_cast<uintptr_t>(handle));
}

jlong toHandle(parso_engine_t *engine) noexcept {
    return static_cast<jlong>(reinterpret_cast<uintptr_t>(engine));
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

} // extern "C"
