#include "parso_flac.h"

#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "FLAC/format.h"
#include "FLAC/metadata.h"
#include "FLAC/stream_decoder.h"
#include "FLAC/stream_encoder.h"

static const FLAC__byte parso_float_application_id[4] = { 'P', 'F', 'L', 'T' };
int parso_flac_encode_file(const char *path,
                           const int32_t *samples,
                           const uint32_t *exact_float_bits,
                           uint64_t frames,
                           uint32_t channels,
                           uint32_t sample_rate,
                           uint32_t compression)
{
    FLAC__StreamEncoder *encoder;
    FLAC__StreamEncoderInitStatus init_status;
    FLAC__bool processed;
    FLAC__bool finished;

    if (path == NULL || (frames != 0 && (samples == NULL || exact_float_bits == NULL)) ||
        channels == 0 || channels > 8 || sample_rate == 0 ||
        frames > UINT32_MAX)
        return 1;

    encoder = FLAC__stream_encoder_new();
    if (encoder == NULL)
        return 1;
    if (!FLAC__stream_encoder_set_channels(encoder, channels) ||
        !FLAC__stream_encoder_set_bits_per_sample(encoder, 32) ||
        !FLAC__stream_encoder_set_sample_rate(encoder, sample_rate) ||
        !FLAC__stream_encoder_set_compression_level(encoder, compression > 8 ? 8 : compression)) {
        FLAC__stream_encoder_delete(encoder);
        return 1;
    }
    FLAC__StreamMetadata *metadata = FLAC__metadata_object_new(FLAC__METADATA_TYPE_APPLICATION);
    if (metadata == NULL || frames > (UINT32_MAX - 4) / (4 * channels)) {
        FLAC__metadata_object_delete(metadata);
        FLAC__stream_encoder_delete(encoder);
        return 1;
    }
    memcpy(metadata->data.application.id, parso_float_application_id, 4);
    if (!FLAC__metadata_object_application_set_data(
            metadata,
            (FLAC__byte *)exact_float_bits,
            (uint32_t)(frames * channels * sizeof(uint32_t)),
            1)) {
        FLAC__metadata_object_delete(metadata);
        FLAC__stream_encoder_delete(encoder);
        return 1;
    }
    FLAC__StreamMetadata *metadata_blocks[1] = { metadata };
    if (!FLAC__stream_encoder_set_metadata(encoder, metadata_blocks, 1)) {
        FLAC__metadata_object_delete(metadata);
        FLAC__stream_encoder_delete(encoder);
        return 1;
    }
    init_status = FLAC__stream_encoder_init_file(encoder, path, NULL, NULL);
    if (init_status != FLAC__STREAM_ENCODER_INIT_STATUS_OK) {
        FLAC__metadata_object_delete(metadata);
        FLAC__stream_encoder_delete(encoder);
        return 2;
    }
    processed = frames == 0 ? (FLAC__bool)1 : FLAC__stream_encoder_process_interleaved(
        encoder, samples, (uint32_t)frames);
    finished = FLAC__stream_encoder_finish(encoder);
    FLAC__metadata_object_delete(metadata);
    FLAC__stream_encoder_delete(encoder);
    return processed && finished ? 0 : 3;
}

int parso_flac_encode_file_tagged(const char *path,
                                  const int32_t *samples,
                                  uint64_t frames,
                                  uint32_t channels,
                                  uint32_t bits_per_sample,
                                  uint32_t sample_rate,
                                  uint32_t compression,
                                  const char *const *comment_keys,
                                  const char *const *comment_values,
                                  int comment_count)
{
    FLAC__StreamEncoder *encoder;
    FLAC__StreamEncoderInitStatus init_status;
    FLAC__StreamMetadata *vorbis = NULL;
    FLAC__StreamMetadata *blocks[1];
    FLAC__bool processed;
    FLAC__bool finished;
    int i;

    if (path == NULL || (frames != 0 && samples == NULL) ||
        channels == 0 || channels > 8 || sample_rate == 0 ||
        (bits_per_sample != 16 && bits_per_sample != 24) ||
        frames > UINT32_MAX || (comment_count > 0 && (comment_keys == NULL || comment_values == NULL)))
        return 1;

    encoder = FLAC__stream_encoder_new();
    if (encoder == NULL)
        return 1;
    if (!FLAC__stream_encoder_set_channels(encoder, channels) ||
        !FLAC__stream_encoder_set_bits_per_sample(encoder, bits_per_sample) ||
        !FLAC__stream_encoder_set_sample_rate(encoder, sample_rate) ||
        !FLAC__stream_encoder_set_compression_level(encoder, compression > 8 ? 8 : compression) ||
        !FLAC__stream_encoder_set_verify(encoder, 1)) {
        FLAC__stream_encoder_delete(encoder);
        return 1;
    }

    if (comment_count > 0) {
        vorbis = FLAC__metadata_object_new(FLAC__METADATA_TYPE_VORBIS_COMMENT);
        if (vorbis == NULL) {
            FLAC__stream_encoder_delete(encoder);
            return 1;
        }
        for (i = 0; i < comment_count; ++i) {
            FLAC__StreamMetadata_VorbisComment_Entry entry;
            if (comment_keys[i] == NULL || comment_values[i] == NULL ||
                comment_values[i][0] == '\0')
                continue;
            if (!FLAC__metadata_object_vorbiscomment_entry_from_name_value_pair(
                    &entry, comment_keys[i], comment_values[i]) ||
                !FLAC__metadata_object_vorbiscomment_append_comment(vorbis, entry, false)) {
                FLAC__metadata_object_delete(vorbis);
                FLAC__stream_encoder_delete(encoder);
                return 1;
            }
        }
        blocks[0] = vorbis;
        if (!FLAC__stream_encoder_set_metadata(encoder, blocks, 1)) {
            FLAC__metadata_object_delete(vorbis);
            FLAC__stream_encoder_delete(encoder);
            return 1;
        }
    }

    init_status = FLAC__stream_encoder_init_file(encoder, path, NULL, NULL);
    if (init_status != FLAC__STREAM_ENCODER_INIT_STATUS_OK) {
        if (vorbis) FLAC__metadata_object_delete(vorbis);
        FLAC__stream_encoder_delete(encoder);
        return 2;
    }

    processed = frames == 0 ? (FLAC__bool)1 : FLAC__stream_encoder_process_interleaved(
        encoder, samples, (uint32_t)frames);
    finished = FLAC__stream_encoder_finish(encoder);
    if (vorbis) FLAC__metadata_object_delete(vorbis);
    FLAC__stream_encoder_delete(encoder);
    return processed && finished ? 0 : 3;
}

typedef struct {
    uint8_t *data;
    size_t size;
    size_t capacity;
    int failed;
} parso_flac_memory_output;

static FLAC__StreamEncoderWriteStatus parso_flac_memory_write_callback(
    const FLAC__StreamEncoder *encoder,
    const FLAC__byte buffer[],
    size_t bytes,
    uint32_t samples,
    uint32_t current_frame,
    void *client_data)
{
    parso_flac_memory_output *output = (parso_flac_memory_output *)client_data;
    size_t required;
    size_t capacity;
    uint8_t *resized;

    (void)encoder;
    (void)samples;
    (void)current_frame;
    if (bytes > SIZE_MAX - output->size) {
        output->failed = 1;
        return FLAC__STREAM_ENCODER_WRITE_STATUS_FATAL_ERROR;
    }
    required = output->size + bytes;
    if (required > output->capacity) {
        capacity = output->capacity == 0 ? 4096 : output->capacity;
        while (capacity < required) {
            if (capacity > SIZE_MAX / 2) {
                output->failed = 1;
                return FLAC__STREAM_ENCODER_WRITE_STATUS_FATAL_ERROR;
            }
            capacity *= 2;
        }
        resized = (uint8_t *)realloc(output->data, capacity);
        if (resized == NULL) {
            output->failed = 1;
            return FLAC__STREAM_ENCODER_WRITE_STATUS_FATAL_ERROR;
        }
        output->data = resized;
        output->capacity = capacity;
    }
    if (bytes != 0)
        memcpy(output->data + output->size, buffer, bytes);
    output->size = required;
    return FLAC__STREAM_ENCODER_WRITE_STATUS_OK;
}

int parso_flac_encode_memory(const int32_t *samples,
                             uint64_t frames,
                             uint32_t channels,
                             uint32_t bits_per_sample,
                             uint32_t sample_rate,
                             uint32_t compression,
                             uint8_t **data,
                             uint64_t *size_bytes)
{
    FLAC__StreamEncoder *encoder;
    FLAC__StreamEncoderInitStatus init_status;
    parso_flac_memory_output output = { 0 };
    FLAC__bool processed;
    FLAC__bool finished;

    if (data == NULL || size_bytes == NULL ||
        (frames != 0 && samples == NULL) || channels == 0 || channels > 8 ||
        (bits_per_sample != 16 && bits_per_sample != 24 && bits_per_sample != 32) ||
        sample_rate == 0 || frames > UINT32_MAX) {
        return 1;
    }
    *data = NULL;
    *size_bytes = 0;

    encoder = FLAC__stream_encoder_new();
    if (encoder == NULL)
        return 1;
    if (!FLAC__stream_encoder_set_channels(encoder, channels) ||
        !FLAC__stream_encoder_set_bits_per_sample(encoder, bits_per_sample) ||
        !FLAC__stream_encoder_set_sample_rate(encoder, sample_rate) ||
        !FLAC__stream_encoder_set_compression_level(encoder, compression > 8 ? 8 : compression) ||
        !FLAC__stream_encoder_set_total_samples_estimate(encoder, frames)) {
        FLAC__stream_encoder_delete(encoder);
        return 1;
    }
    init_status = FLAC__stream_encoder_init_stream(
        encoder, parso_flac_memory_write_callback, NULL, NULL, NULL, &output);
    if (init_status != FLAC__STREAM_ENCODER_INIT_STATUS_OK) {
        FLAC__stream_encoder_delete(encoder);
        return 2;
    }
    processed = frames == 0 ? (FLAC__bool)1 : FLAC__stream_encoder_process_interleaved(
        encoder, samples, (uint32_t)frames);
    finished = FLAC__stream_encoder_finish(encoder);
    FLAC__stream_encoder_delete(encoder);
    if (!processed || !finished || output.failed || output.size == 0) {
        free(output.data);
        return 3;
    }
    *data = output.data;
    *size_bytes = (uint64_t)output.size;
    return 0;
}

