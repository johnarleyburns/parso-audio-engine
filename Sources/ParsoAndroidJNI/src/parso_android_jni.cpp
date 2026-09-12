#include "parso.h"

#include <jni.h>

#include <cstdint>
#include <cmath>
#include <cstring>
#include <limits>
#include <vector>

namespace {

parso_engine_t *fromHandle(jlong handle) noexcept {
    return reinterpret_cast<parso_engine_t *>(static_cast<uintptr_t>(handle));
}

jlong toHandle(parso_engine_t *engine) noexcept {
    return static_cast<jlong>(reinterpret_cast<uintptr_t>(engine));
}

int32_t floatBits(float value) noexcept {
    uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    return static_cast<int32_t>(bits);
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

JNIEXPORT jboolean JNICALL Java_com_parsoaudio_ParsoNative_nativeSetMix(
    JNIEnv *, jclass, jlong handle, jfloat crossfader, jfloat masterLevel
) {
    parso_engine_t *engine = fromHandle(handle);
    if (!engine || !std::isfinite(crossfader) || !std::isfinite(masterLevel) ||
        crossfader < -1.0f || crossfader > 1.0f || masterLevel < 0.0f || masterLevel > 1.0f) {
        return JNI_FALSE;
    }
    parso_control_t control{};
    if (parso_control_init(&control) != PARSO_STATUS_OK) return JNI_FALSE;
    control.crossfader = crossfader;
    control.master_level = masterLevel;
    return parso_engine_set_control(engine, &control) == PARSO_STATUS_OK
        ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL Java_com_parsoaudio_ParsoNative_nativePostCommand(
    JNIEnv *, jclass, jlong handle, jint type, jint deck,
    jint i0, jint i1, jint i2, jfloat f0, jfloat f1
) {
    parso_engine_t *engine = fromHandle(handle);
    if (!engine || type < 0 || type > static_cast<jint>(PARSO_COMMAND_LOAD) ||
        deck < 0 || deck >= 4) return JNI_FALSE;
    parso_command_t command{};
    if (parso_command_init(&command) != PARSO_STATUS_OK) return JNI_FALSE;
    command.type = static_cast<uint32_t>(type);
    command.deck = deck;
    command.i0 = i0;
    command.i1 = i1;
    command.i2 = i2;
    command.f0 = f0;
    command.f1 = f1;
    return parso_engine_post_command(engine, &command) == PARSO_STATUS_OK
        ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jlongArray JNICALL Java_com_parsoaudio_ParsoNative_nativeGetStats(
    JNIEnv *env, jclass, jlong handle
) {
    if (!env || !fromHandle(handle)) return nullptr;
    parso_stats_t stats{};
    if (parso_stats_init(&stats) != PARSO_STATUS_OK ||
        parso_engine_get_stats(fromHandle(handle), &stats) != PARSO_STATUS_OK) return nullptr;
    const jlong values[] = {
        static_cast<jlong>(stats.master_frame),
        static_cast<jlong>(stats.starved_frames),
        static_cast<jlong>(stats.deck_count),
    };
    jlongArray output = env->NewLongArray(3);
    if (output) env->SetLongArrayRegion(output, 0, 3, values);
    return output;
}

JNIEXPORT jlongArray JNICALL Java_com_parsoaudio_ParsoNative_nativePollEvents(
    JNIEnv *env, jclass, jlong handle, jint maxEvents
) {
    if (!env || !fromHandle(handle) || maxEvents <= 0 || maxEvents > 64) return nullptr;
    parso_event_t events[64]{};
    for (jint index = 0; index < maxEvents; ++index) {
        if (parso_event_init(&events[index]) != PARSO_STATUS_OK) return nullptr;
    }
    uint32_t count = 0;
    if (parso_engine_poll_events(fromHandle(handle), events, static_cast<uint32_t>(maxEvents), &count) !=
            PARSO_STATUS_OK) return nullptr;
    const jsize valueCount = static_cast<jsize>(count * 5u);
    jlongArray output = env->NewLongArray(valueCount);
    if (!output) return nullptr;
    std::vector<jlong> values(static_cast<size_t>(valueCount));
    for (uint32_t index = 0; index < count; ++index) {
        const size_t offset = static_cast<size_t>(index) * 5u;
        values[offset] = static_cast<jlong>(events[index].type);
        values[offset + 1u] = static_cast<jlong>(events[index].deck);
        values[offset + 2u] = static_cast<jlong>(events[index].frame);
        values[offset + 3u] = static_cast<jlong>(floatBits(events[index].f0));
        values[offset + 4u] = static_cast<jlong>(floatBits(events[index].f1));
    }
    env->SetLongArrayRegion(output, 0, valueCount, values.data());
    return output;
}

JNIEXPORT jbyteArray JNICALL Java_com_parsoaudio_ParsoNative_nativeEncodeRecording(
    JNIEnv *env, jclass, jobject samples, jint frames, jint sampleRateHz,
    jint channelCount, jint codec, jint bitrateKbps, jint quality
) {
    parso_pcm_buffer_t input{};
    if (!makePCMInput(env, samples, frames, sampleRateHz, channelCount, &input) ||
        codec <= 0 || bitrateKbps < 0 || quality < 0) return nullptr;
    parso_codec_options_t options{};
    parso_bytes_t encoded{};
    if (parso_codec_options_init(&options) != PARSO_STATUS_OK ||
        parso_bytes_init(&encoded) != PARSO_STATUS_OK) return nullptr;
    options.bitrate_kbps = static_cast<uint32_t>(bitrateKbps);
    options.quality = static_cast<uint32_t>(quality);
    if (parso_codec_write(&input, static_cast<uint32_t>(codec), &options, &encoded) !=
            PARSO_STATUS_OK || encoded.size_bytes > static_cast<uint64_t>(INT32_MAX)) {
        parso_bytes_release(&encoded);
        return nullptr;
    }
    jbyteArray output = env->NewByteArray(static_cast<jsize>(encoded.size_bytes));
    if (output && encoded.size_bytes > 0) {
        env->SetByteArrayRegion(output, 0, static_cast<jsize>(encoded.size_bytes),
                                reinterpret_cast<const jbyte *>(encoded.data));
    }
    parso_bytes_release(&encoded);
    return output;
}
} // extern "C"
