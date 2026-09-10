#include "parso.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static int require_ok(parso_status_t status, const char *operation)
{
    if (status == PARSO_STATUS_OK)
        return 1;
    fprintf(stderr, "public_codec_consumer: %s: %s (%s)\n",
            operation, parso_status_string(status), parso_last_error());
    return 0;
}

static int round_trip(const parso_pcm_buffer_t *input,
                      uint32_t codec,
                      const parso_codec_options_t *options)
{
    parso_bytes_t encoded;
    parso_pcm_buffer_t decoded;
    int ok = 1;

    if (!require_ok(parso_bytes_init(&encoded), "encoded init") ||
        !require_ok(parso_pcm_buffer_init(&decoded), "decoded init"))
        return 0;
    if (!require_ok(parso_codec_write(input, codec, options, &encoded), "codec write") ||
        encoded.data == NULL || encoded.size_bytes == 0 ||
        !require_ok(parso_codec_read(encoded.data, encoded.size_bytes, codec,
                                     options, &decoded), "codec read") ||
        decoded.samples == NULL || decoded.frames == 0 ||
        decoded.channel_count != input->channel_count ||
        decoded.sample_rate_hz != input->sample_rate_hz ||
        !isfinite(decoded.samples[0])) {
        fprintf(stderr, "public_codec_consumer: invalid round trip for codec %u\n", codec);
        ok = 0;
    }
    parso_pcm_buffer_release(&decoded);
    parso_bytes_release(&encoded);
    return ok;
}

static int read_file(const char *path, uint8_t **data, uint64_t *size)
{
    FILE *file = fopen(path, "rb");
    long length;
    uint8_t *buffer;
    size_t count;

    *data = NULL;
    *size = 0;
    if (file == NULL || fseek(file, 0, SEEK_END) != 0)
        goto failure;
    length = ftell(file);
    if (length <= 0 || fseek(file, 0, SEEK_SET) != 0)
        goto failure;
    buffer = (uint8_t *)malloc((size_t)length);
    if (buffer == NULL)
        goto failure;
    count = fread(buffer, 1, (size_t)length, file);
    fclose(file);
    if (count != (size_t)length) {
        free(buffer);
        return 0;
    }
    *data = buffer;
    *size = (uint64_t)length;
    return 1;

failure:
    if (file != NULL)
        fclose(file);
    return 0;
}

static int fixture_available(const char *path)
{
    FILE *file = fopen(path, "rb");
    if (file == NULL)
        return 0;
    fclose(file);
    return 1;
}

static int require_fixture(const char *path, uint32_t codec)
{
    uint8_t *data = NULL;
    uint64_t size = 0;
    parso_codec_options_t options;
    parso_pcm_buffer_t decoded;
    int ok = 0;

    if (!read_file(path, &data, &size) ||
        !require_ok(parso_codec_options_init(&options), "fixture options init") ||
        !require_ok(parso_pcm_buffer_init(&decoded), "fixture buffer init")) {
        free(data);
        return 0;
    }
    if (parso_codec_read(data, size, codec, &options, &decoded) == PARSO_STATUS_OK &&
        decoded.frames > 0 && decoded.channel_count > 0 &&
        decoded.channel_count <= 2 && decoded.sample_rate_hz > 0 &&
        isfinite(decoded.samples[0]))
        ok = 1;
    if (!ok)
        fprintf(stderr, "public_codec_consumer: fixture decode failed for codec %u\n", codec);
    parso_pcm_buffer_release(&decoded);
    free(data);
    return ok;
}

int main(int argc, char **argv)
{
    enum { frames = 2048, channels = 2 };
    float samples[frames * channels];
    parso_capabilities_t capabilities;
    parso_codec_options_t options;
    parso_pcm_buffer_t input;
    parso_bytes_t unsupported;
    uint32_t index;
    int ok = 1;

    for (index = 0; index < frames; ++index) {
        samples[index * channels] = 0.25f *
            (float)sin(2.0 * 3.141592653589793 * 440.0 * index / 48000.0);
        samples[index * channels + 1] = -samples[index * channels];
    }
    ok = ok && require_ok(parso_capabilities_init(&capabilities), "capabilities init");
    ok = ok && require_ok(parso_capabilities_get(&capabilities), "capabilities get");
    ok = ok && (capabilities.decode_containers &
                (PARSO_CONTAINER_WAV | PARSO_CONTAINER_FLAC |
                 PARSO_CONTAINER_OGG_VORBIS | PARSO_CONTAINER_OPUS |
                 PARSO_CONTAINER_MP3 | PARSO_CONTAINER_AAC)) ==
               (PARSO_CONTAINER_WAV | PARSO_CONTAINER_FLAC |
                PARSO_CONTAINER_OGG_VORBIS | PARSO_CONTAINER_OPUS |
                PARSO_CONTAINER_MP3 | PARSO_CONTAINER_AAC);
    ok = ok && (capabilities.encode_containers &
                (PARSO_CONTAINER_WAV | PARSO_CONTAINER_FLAC |
                 PARSO_CONTAINER_OGG_VORBIS | PARSO_CONTAINER_OPUS | PARSO_CONTAINER_MP3 |
                 PARSO_CONTAINER_AAC)) ==
               (PARSO_CONTAINER_WAV | PARSO_CONTAINER_FLAC |
                PARSO_CONTAINER_OGG_VORBIS | PARSO_CONTAINER_OPUS | PARSO_CONTAINER_MP3 |
                PARSO_CONTAINER_AAC);
    ok = ok && require_ok(parso_codec_options_init(&options), "codec options init");
    ok = ok && require_ok(parso_pcm_buffer_init(&input), "input init");
    ok = ok && require_ok(parso_bytes_init(&unsupported), "unsupported output init");
    input.samples = samples;
    input.frames = frames;
    input.channel_count = channels;
    input.sample_rate_hz = 48000;

    ok = ok && round_trip(&input, PARSO_CODEC_WAV, &options);
    ok = ok && round_trip(&input, PARSO_CODEC_FLAC, &options);
    ok = ok && round_trip(&input, PARSO_CODEC_OGG_VORBIS, &options);
    ok = ok && round_trip(&input, PARSO_CODEC_OPUS, &options);
    ok = ok && round_trip(&input, PARSO_CODEC_MP3, &options);
    ok = ok && round_trip(&input, PARSO_CODEC_AAC, &options);
    ok = ok && parso_codec_write(&input, 99u, &options,
                                 &unsupported) == PARSO_STATUS_INVALID_ARGUMENT;
    parso_bytes_release(&unsupported);

    input.samples = NULL;
    parso_pcm_buffer_release(&input);
    if (!ok)
        return 1;

    if (argc == 1)
        return 0;
    if (argc != 4 && argc != 5) {
        fprintf(stderr, "usage: %s [FLAC OGG [OPUS] MP3]\n", argv[0]);
        return 2;
    }
    if (!fixture_available(argv[1]) || !fixture_available(argv[2]) ||
        (argc == 5 && !fixture_available(argv[3])) ||
        !fixture_available(argv[argc - 1]))
        return 77;
    if (!require_fixture(argv[1], PARSO_CODEC_FLAC) ||
        !require_fixture(argv[2], PARSO_CODEC_OGG_VORBIS))
        return 1;
    if (argc == 5 && !require_fixture(argv[3], PARSO_CODEC_OPUS))
        return 1;
    return require_fixture(argv[argc - 1], PARSO_CODEC_MP3) ? 0 : 1;
}
