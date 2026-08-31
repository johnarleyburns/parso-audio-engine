#include "parso_opus.h"

#include <limits.h>
#include <stdint.h>
#include <stdlib.h>

#include "opusfile.h"

int parso_opus_decode_file(const char *path,
                           float **samples,
                           uint64_t *frames,
                           uint32_t *channels,
                           uint32_t *sample_rate)
{
    OggOpusFile *file;
    const OpusHead *head;
    opus_int64 total_frames;
    int error = 0;
    int opus_channels;
    size_t capacity;
    size_t count = 0;
    float *decoded;

    if (path == NULL || samples == NULL || frames == NULL ||
        channels == NULL || sample_rate == NULL)
        return 1;
    *samples = NULL;
    *frames = 0;
    *channels = 0;
    *sample_rate = 0;

    file = op_open_file(path, &error);
    if (file == NULL)
        return 2;
    opus_channels = op_channel_count(file, -1);
    head = op_head(file, -1);
    total_frames = op_pcm_total(file, -1);
    if (opus_channels <= 0 || head == NULL || total_frames < 0 ||
        total_frames > (opus_int64)(SIZE_MAX / sizeof(float) / (size_t)opus_channels)) {
        op_free(file);
        return 2;
    }
    capacity = (size_t)total_frames * (size_t)opus_channels;
    if (capacity == 0)
        capacity = (size_t)opus_channels * 4096;
    decoded = (float *)malloc(capacity * sizeof(*decoded));
    if (decoded == NULL) {
        op_free(file);
        return 3;
    }
    for (;;) {
        int buffer_size;
        int result;
        if (count == capacity) {
            size_t new_capacity = capacity > SIZE_MAX / 2 ? 0 : capacity * 2;
            float *resized;
            if (new_capacity == 0 || new_capacity > SIZE_MAX / sizeof(*decoded)) {
                free(decoded);
                op_free(file);
                return 3;
            }
            resized = (float *)realloc(decoded, new_capacity * sizeof(*decoded));
            if (resized == NULL) {
                free(decoded);
                op_free(file);
                return 3;
            }
            decoded = resized;
            capacity = new_capacity;
        }
        buffer_size = (int)((capacity - count) > (size_t)INT_MAX ? INT_MAX : capacity - count);
        result = op_read_float(file, decoded + count, buffer_size, NULL);
        if (result == 0)
            break;
        if (result < 0) {
            free(decoded);
            op_free(file);
            return 4;
        }
        count += (size_t)result * (size_t)opus_channels;
    }
    op_free(file);
    if (count % (size_t)opus_channels != 0) {
        free(decoded);
        return 4;
    }
    *samples = decoded;
    *frames = (uint64_t)(count / (size_t)opus_channels);
    *channels = (uint32_t)opus_channels;
    *sample_rate = 48000;
    return 0;
}

void parso_opus_free(void *pointer)
{
    free(pointer);
}
