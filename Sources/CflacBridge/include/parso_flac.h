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
                           uint32_t *sample_rate,
                           uint32_t *bits_per_sample);

int parso_flac_encode_file(const char *path,
                           const int32_t *samples,
                           const uint32_t *exact_float_bits,
                           uint64_t frames,
                           uint32_t channels,
                           uint32_t sample_rate,
                           uint32_t compression);

/*
 * Encode a standard (non-PFLT) delivery FLAC: caller-chosen bit depth
 * (16 or 24), Vorbis comments from parallel key/value arrays, verify on.
 * `samples` is interleaved signed PCM already quantised to `bits_per_sample`
 * by the caller. Returns 0 on success, non-zero on failure.
 */
int parso_flac_encode_file_tagged(const char *path,
                                  const int32_t *samples,
                                  uint64_t frames,
                                  uint32_t channels,
                                  uint32_t bits_per_sample,
                                  uint32_t sample_rate,
                                  uint32_t compression,
                                  const char *const *comment_keys,
                                  const char *const *comment_values,
                                  int comment_count);

/*
 * Decode a bounded, contiguous range of a FLAC file without reading the rest of
 * it. `first_frame` and `frame_count` are in source-file sample frames (before
 * any resampling). On return `*frames` is the number of frames actually
 * decoded (>= frame_count unless the range runs past end of stream); the
 * interleaved 32-bit PCM array carries `*frames * *channels` samples and must be
 * released with parso_flac_free().
 *
 * If the stream cannot be positioned, `*seek_unsupported` is set to 1 and a
 * non-zero status is returned — the caller MUST NOT fall back to a full-file
 * decode silently.
 *
 * Returns 0 on success, non-zero on failure.
 */
int parso_flac_decode_range(const char *path,
                            uint64_t first_frame,
                            uint64_t frame_count,
                            int32_t **samples,
                            uint64_t *frames,
                            uint32_t *channels,
                            uint32_t *sample_rate,
                            uint32_t *bits_per_sample,
                            int *seek_unsupported);

void parso_flac_free(void *pointer);

#ifdef __cplusplus
}
#endif

#endif
