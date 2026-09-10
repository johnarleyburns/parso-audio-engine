#include "parso.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>

static int require_ok(parso_status_t status, const char *operation) {
    if (status == PARSO_STATUS_OK) return 1;
    fprintf(stderr, "public_c_offline_consumer: %s: %s (%s)\n",
            operation, parso_status_string(status), parso_last_error());
    return 0;
}

static int near_float(float actual, float expected, float tolerance) {
    return fabsf(actual - expected) <= tolerance;
}

int main(void) {
    parso_capabilities_t capabilities;
    parso_pcm_buffer_t source;
    parso_pcm_buffer_t decoded;
    parso_pcm_buffer_t raw_decoded;
    parso_bytes_t wav;
    parso_bytes_t raw;
    const float samples[] = {
        0.0f, 0.5f,
        -1.0f, 1.2f,
        -0.25f, 0.25f,
        0.125f, -0.125f
    };

    if (!require_ok(parso_capabilities_init(&capabilities), "capabilities init") ||
        !require_ok(parso_capabilities_get(&capabilities), "capabilities get") ||
        !require_ok(parso_pcm_buffer_init(&source), "source init") ||
        !require_ok(parso_pcm_buffer_init(&decoded), "decoded init") ||
        !require_ok(parso_pcm_buffer_init(&raw_decoded), "raw decoded init") ||
        !require_ok(parso_bytes_init(&wav), "WAV bytes init") ||
        !require_ok(parso_bytes_init(&raw), "raw bytes init")) return 1;

    if (capabilities.decode_containers != PARSO_CONTAINER_WAV ||
        capabilities.encode_containers != PARSO_CONTAINER_WAV ||
        (capabilities.pcm_read_formats & PARSO_PCM_FORMAT_S16_LE) == 0 ||
        (capabilities.pcm_write_formats & PARSO_PCM_FORMAT_S16_LE) == 0 ||
        (capabilities.decode_containers & PARSO_CONTAINER_FLAC) != 0) {
        fprintf(stderr, "public_c_offline_consumer: incorrect capabilities\n");
        return 1;
    }

    source.samples = (float *)samples;
    source.frames = 4;
    source.channel_count = 2;
    source.sample_rate_hz = 48000;

    if (!require_ok(parso_pcm_write(&source, 16, &raw), "raw PCM write") ||
        raw.size_bytes != sizeof(samples) / sizeof(float) * 2u) return 1;
    if (!require_ok(parso_pcm_read(raw.data, raw.size_bytes, 48000, 2, 16, &raw_decoded),
                    "raw PCM read") ||
        raw_decoded.frames != 4 || raw_decoded.channel_count != 2 ||
        !near_float(raw_decoded.samples[0], samples[0], 1.0e-4f) ||
        !near_float(raw_decoded.samples[1], samples[1], 1.0e-4f) ||
        !near_float(raw_decoded.samples[2], -1.0f, 1.0e-4f) ||
        !near_float(raw_decoded.samples[3], 1.0f, 1.0e-4f)) return 1;

    if (!require_ok(parso_wav_write(&source, 24, 0, &wav), "WAV write") ||
        wav.size_bytes != 44u + source.frames * source.channel_count * 3u ||
        !require_ok(parso_wav_read(wav.data, wav.size_bytes, &decoded), "WAV read") ||
        decoded.frames != source.frames || decoded.channel_count != source.channel_count ||
        decoded.sample_rate_hz != source.sample_rate_hz ||
        !near_float(decoded.samples[1], samples[1], 1.0e-6f) ||
        !near_float(decoded.samples[2], -1.0f, 1.0e-6f) ||
        !near_float(decoded.samples[3], 1.0f, 1.0e-6f)) return 1;

    if (!require_ok(parso_pcm_buffer_release(&raw_decoded), "raw decoded cleanup")) return 1;
    if (parso_wav_read((const uint8_t *)"not-wave", 8, &raw_decoded) !=
        PARSO_STATUS_INVALID_ARGUMENT) {
        fprintf(stderr, "public_c_offline_consumer: malformed WAV accepted\n");
        return 1;
    }

    if (!require_ok(parso_bytes_release(&wav), "WAV bytes release") ||
        !require_ok(parso_bytes_release(&wav), "repeat WAV bytes release") ||
        !require_ok(parso_bytes_release(&raw), "raw bytes release") ||
        !require_ok(parso_pcm_buffer_release(&decoded), "decoded release") ||
        !require_ok(parso_pcm_buffer_release(&decoded), "repeat decoded release") ||
        !require_ok(parso_pcm_buffer_release(&raw_decoded), "raw decoded release")) return 1;
    source.samples = NULL;
    if (!require_ok(parso_pcm_buffer_release(&source), "source release")) return 1;
    return 0;
}
