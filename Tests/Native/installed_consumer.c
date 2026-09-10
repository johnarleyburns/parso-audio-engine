#include "parso.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>

int main(void)
{
    enum { frames = 1024 };
    float samples[frames];
    parso_capabilities_t capabilities;
    parso_codec_options_t options;
    parso_pcm_buffer_t input;
    parso_pcm_buffer_t decoded;
    parso_bytes_t encoded;
    uint32_t index;

    for (index = 0; index < frames; ++index)
        samples[index] = 0.25f * sinf((float)index * 0.03f);
    if (parso_capabilities_init(&capabilities) != PARSO_STATUS_OK ||
        parso_capabilities_get(&capabilities) != PARSO_STATUS_OK ||
        (capabilities.encode_containers & PARSO_CONTAINER_OGG_VORBIS) == 0 ||
        parso_codec_options_init(&options) != PARSO_STATUS_OK ||
        parso_pcm_buffer_init(&input) != PARSO_STATUS_OK ||
        parso_pcm_buffer_init(&decoded) != PARSO_STATUS_OK ||
        parso_bytes_init(&encoded) != PARSO_STATUS_OK) {
        fprintf(stderr, "installed consumer: initialization failed: %s\n", parso_last_error());
        return 1;
    }
    input.samples = samples;
    input.frames = frames;
    input.channel_count = 1;
    input.sample_rate_hz = 48000;
    if (parso_codec_write(&input, PARSO_CODEC_OGG_VORBIS, &options, &encoded) != PARSO_STATUS_OK ||
        encoded.size_bytes < 4 || encoded.data[0] != 'O' || encoded.data[1] != 'g' ||
        encoded.data[2] != 'g' || encoded.data[3] != 'S' ||
        parso_codec_read(encoded.data, encoded.size_bytes, PARSO_CODEC_OGG_VORBIS,
                         &options, &decoded) != PARSO_STATUS_OK ||
        decoded.frames == 0 || decoded.channel_count != 1 ||
        decoded.sample_rate_hz != 48000 || !isfinite(decoded.samples[0])) {
        fprintf(stderr, "installed consumer: Xiph Vorbis round trip failed: %s\n",
                parso_last_error());
        parso_pcm_buffer_release(&decoded);
        parso_bytes_release(&encoded);
        input.samples = NULL;
        parso_pcm_buffer_release(&input);
        return 1;
    }
    parso_pcm_buffer_release(&decoded);
    parso_bytes_release(&encoded);
    input.samples = NULL;
    parso_pcm_buffer_release(&input);
    return 0;
}
