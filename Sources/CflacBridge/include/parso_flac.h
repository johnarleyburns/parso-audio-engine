/*
 * Small C-clean bridge around the vendored native libFLAC API.
 * The returned sample array is interleaved signed 32-bit PCM and must be
 * released with parso_flac_free().
 */
#ifndef PARSO_FLAC_H
#define PARSO_FLAC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int parso_flac_decode_file(const char *path,
                           int32_t **samples,
                           uint32_t **exact_float_bits,
                           uint64_t *frames,
                           uint32_t *channels,
                           uint32_t *sample_rate);

int parso_flac_encode_file(const char *path,
                           const int32_t *samples,
                           const uint32_t *exact_float_bits,
                           uint64_t frames,
                           uint32_t channels,
                           uint32_t sample_rate,
                           uint32_t compression);

void parso_flac_free(void *pointer);

#ifdef __cplusplus
}
#endif

#endif
