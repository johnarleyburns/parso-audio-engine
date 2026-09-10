#ifndef PARSO_VORBIS_H
#define PARSO_VORBIS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int parso_vorbis_decode_file(const char *path,
                             int16_t **samples,
                             uint64_t *frames,
                             uint32_t *channels,
                             uint32_t *sample_rate);

int parso_vorbis_decode_memory(const uint8_t *data,
                               uint64_t size_bytes,
                               float **samples,
                               uint64_t *frames,
                               uint32_t *channels,
                               uint32_t *sample_rate);

int parso_vorbis_encode_memory(const float *samples,
                               uint64_t frames,
                               uint32_t channels,
                               uint32_t sample_rate,
                               uint32_t bitrate_kbps,
                               uint8_t **data,
                               uint64_t *size_bytes);

void parso_vorbis_free(void *pointer);

#ifdef __cplusplus
}
#endif

#endif
