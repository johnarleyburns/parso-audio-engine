#ifndef PARSO_OPUS_H
#define PARSO_OPUS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int parso_opus_decode_file(const char *path,
                           float **samples,
                           uint64_t *frames,
                           uint32_t *channels,
                           uint32_t *sample_rate);

void parso_opus_free(void *pointer);

#ifdef __cplusplus
}
#endif

#endif
