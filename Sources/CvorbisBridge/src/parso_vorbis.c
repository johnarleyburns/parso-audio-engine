#include "parso_vorbis.h"

#include <stdint.h>
#include <stdlib.h>

#include "stb_vorbis.h"

int parso_vorbis_decode_file(const char *path,
                             int16_t **samples,
                             uint64_t *frames,
                             uint32_t *channels,
                             uint32_t *sample_rate)
{
    int decoded_channels = 0;
    int decoded_sample_rate = 0;
    short *decoded_samples = NULL;
    int decoded_frames;

    if (path == NULL || samples == NULL || frames == NULL ||
        channels == NULL || sample_rate == NULL)
        return 1;
    *samples = NULL;
    *frames = 0;
    *channels = 0;
    *sample_rate = 0;
    decoded_frames = stb_vorbis_decode_filename(
        path, &decoded_channels, &decoded_sample_rate, &decoded_samples);
    if (decoded_frames <= 0 || decoded_samples == NULL ||
        decoded_channels <= 0 || decoded_sample_rate <= 0) {
        free(decoded_samples);
        return 2;
    }
    *samples = (int16_t *)decoded_samples;
    *frames = (uint64_t)decoded_frames;
    *channels = (uint32_t)decoded_channels;
    *sample_rate = (uint32_t)decoded_sample_rate;
    return 0;
}

void parso_vorbis_free(void *pointer)
{
    free(pointer);
}
