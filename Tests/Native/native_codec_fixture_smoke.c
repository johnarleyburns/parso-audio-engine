#include "parso_flac.h"
#include "parso_opus.h"
#include "parso_vorbis.h"
#include "glint/glint.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static int fixture_available(const char *path)
{
    FILE *file = fopen(path, "rb");
    if (file == NULL)
        return 0;
    fclose(file);
    return 1;
}

static int require_flac(const char *path)
{
    int32_t *samples = NULL;
    uint32_t *exact_float_bits = NULL;
    uint64_t frames = 0;
    uint32_t channels = 0;
    uint32_t sample_rate = 0;
    uint32_t bits_per_sample = 0;
    int status = parso_flac_decode_file(path, &samples, &exact_float_bits, &frames,
                                        &channels, &sample_rate, &bits_per_sample);
    int ok = status == 0 && samples != NULL && frames > 0 && channels > 0 &&
             channels <= 8 && sample_rate > 0 && bits_per_sample > 0 &&
             bits_per_sample <= 32;
    if (!ok)
        fprintf(stderr, "native_codec_fixture_smoke: FLAC decode failed (%d)\n", status);
    parso_flac_free(samples);
    parso_flac_free(exact_float_bits);
    return ok;
}

static int require_vorbis(const char *path)
{
    int16_t *samples = NULL;
    uint64_t frames = 0;
    uint32_t channels = 0;
    uint32_t sample_rate = 0;
    int status = parso_vorbis_decode_file(path, &samples, &frames, &channels, &sample_rate);
    int ok = status == 0 && samples != NULL && frames > 0 && channels > 0 &&
             channels <= 8 && sample_rate > 0;
    if (!ok)
        fprintf(stderr, "native_codec_fixture_smoke: Ogg Vorbis decode failed (%d)\n", status);
    parso_vorbis_free(samples);
    return ok;
}

static int require_opus(const char *path)
{
    float *samples = NULL;
    uint64_t frames = 0;
    uint32_t channels = 0;
    uint32_t sample_rate = 0;
    int status = parso_opus_decode_file(path, &samples, &frames, &channels, &sample_rate);
    int ok = status == 0 && samples != NULL && frames > 0 && channels > 0 &&
             channels <= 8 && sample_rate == 48000 && isfinite(samples[0]);
    if (!ok)
        fprintf(stderr, "native_codec_fixture_smoke: Opus decode failed (%d)\n", status);
    parso_opus_free(samples);
    return ok;
}

static int read_file(const char *path, uint8_t **data, int *size)
{
    FILE *file;
    long length;
    uint8_t *buffer;
    size_t read_count;

    *data = NULL;
    *size = 0;
#if defined(_WIN32)
    if (fopen_s(&file, path, "rb") != 0)
        file = NULL;
#else
    file = fopen(path, "rb");
#endif
    if (file == NULL || fseek(file, 0, SEEK_END) != 0) {
        if (file != NULL)
            fclose(file);
        return 0;
    }
    length = ftell(file);
    if (length <= 0 || length > INT32_MAX || fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return 0;
    }
    buffer = (uint8_t *)malloc((size_t)length);
    if (buffer == NULL) {
        fclose(file);
        return 0;
    }
    read_count = fread(buffer, 1, (size_t)length, file);
    fclose(file);
    if (read_count != (size_t)length) {
        free(buffer);
        return 0;
    }
    *data = buffer;
    *size = (int)length;
    return 1;
}

static int require_glint_mp3(const char *path)
{
    uint8_t *encoded = NULL;
    int encoded_size = 0;
    int sample_rate = 0;
    int channels = 0;
    int frames = 0;
    float *samples;
    int ok;

    if (!read_file(path, &encoded, &encoded_size)) {
        fprintf(stderr, "native_codec_fixture_smoke: MP3 fixture read failed\n");
        return 0;
    }
    samples = glint_decode_audio(encoded, encoded_size, &sample_rate, &channels, &frames);
    ok = samples != NULL && sample_rate > 0 && channels > 0 && channels <= 2 &&
         frames > 0 && isfinite(samples[0]);
    if (!ok)
        fprintf(stderr, "native_codec_fixture_smoke: Glint MP3 decode failed\n");
    glint_free(samples);
    free(encoded);
    return ok;
}

static int require_glint_aac(void)
{
    enum { frames = 4096 };
    float pcm[frames];
    uint8_t *encoded;
    float *decoded;
    int encoded_size = 0;
    int sample_rate = 0;
    int channels = 0;
    int decoded_frames = 0;
    int index;
    int ok;

    for (index = 0; index < frames; ++index)
        pcm[index] = 0.2f * (float)sin(2.0 * 3.141592653589793 * 440.0 * index / 48000.0);
    encoded = glint_encode_audio(pcm, frames, 1, 48000, GLINT_ENC_AAC, 128, -1,
                                  GLINT_QUALITY_NORMAL, &encoded_size);
    if (encoded == NULL || encoded_size <= 0) {
        fprintf(stderr, "native_codec_fixture_smoke: Glint AAC encode failed\n");
        glint_free(encoded);
        return 0;
    }
    decoded = glint_decode_audio(encoded, encoded_size, &sample_rate, &channels,
                                 &decoded_frames);
    ok = decoded != NULL && sample_rate == 48000 && channels == 1 &&
         decoded_frames > 0 && isfinite(decoded[0]);
    if (!ok)
        fprintf(stderr, "native_codec_fixture_smoke: Glint AAC round trip failed\n");
    glint_free(decoded);
    glint_free(encoded);
    return ok;
}

static int require_glint_wav(void)
{
    enum { frames = 256, channels = 2 };
    float pcm[frames * channels];
    uint8_t *encoded;
    float *decoded;
    int encoded_size = 0;
    int sample_rate = 0;
    int decoded_channels = 0;
    int decoded_frames = 0;
    int index;
    int ok;

    for (index = 0; index < frames * channels; ++index)
        pcm[index] = index % channels == 0 ? 0.25f : -0.125f;
    encoded = glint_wav_write(pcm, frames, channels, 48000, 24, 0, &encoded_size);
    if (encoded == NULL || encoded_size <= 0) {
        fprintf(stderr, "native_codec_fixture_smoke: WAV encode failed\n");
        glint_free(encoded);
        return 0;
    }
    decoded = glint_wav_read(encoded, encoded_size, &sample_rate, &decoded_channels,
                             &decoded_frames);
    ok = decoded != NULL && sample_rate == 48000 && decoded_channels == channels &&
         decoded_frames == frames && fabs(decoded[0] - 0.25) < 1.0e-5 &&
         fabs(decoded[1] + 0.125) < 1.0e-5;
    if (!ok)
        fprintf(stderr, "native_codec_fixture_smoke: WAV round trip failed\n");
    glint_free(decoded);
    glint_free(encoded);
    return ok;
}

int main(int argc, char **argv)
{
    if (argc != 5) {
        fprintf(stderr, "usage: %s FLAC OGG OPUS MP3\n", argv[0]);
        return 2;
    }
    if (!fixture_available(argv[1]) || !fixture_available(argv[2]) ||
        !fixture_available(argv[3]) || !fixture_available(argv[4])) {
        fprintf(stderr, "native_codec_fixture_smoke: fixture corpus is unavailable\n");
        return 77;
    }
    return require_flac(argv[1]) && require_vorbis(argv[2]) && require_opus(argv[3]) &&
                   require_glint_mp3(argv[4]) && require_glint_aac() && require_glint_wav()
               ? 0
               : 1;
}
