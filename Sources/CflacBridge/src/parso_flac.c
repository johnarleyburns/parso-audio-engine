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

typedef struct {
    int32_t *samples;
    size_t count;
    size_t capacity;
    uint32_t channels;
    uint32_t sample_rate;
    uint32_t *exact_float_bits;
    size_t exact_count;
    int failed;
} parso_flac_decode_context;

static int parso_flac_reserve(parso_flac_decode_context *context, size_t additional)
{
    size_t required;
    size_t capacity;
    int32_t *samples;

    if (additional > SIZE_MAX - context->count)
        return 0;
    required = context->count + additional;
    if (required <= context->capacity)
        return 1;

    capacity = context->capacity == 0 ? 4096 : context->capacity;
    while (capacity < required) {
        if (capacity > SIZE_MAX / 2)
            return 0;
        capacity *= 2;
    }
    if (capacity > SIZE_MAX / sizeof(*samples))
        return 0;
    samples = (int32_t *)realloc(context->samples, capacity * sizeof(*samples));
    if (samples == NULL)
        return 0;
    context->samples = samples;
    context->capacity = capacity;
    return 1;
}

static FLAC__StreamDecoderWriteStatus parso_flac_write_callback(
    const FLAC__StreamDecoder *decoder,
    const FLAC__Frame *frame,
    const FLAC__int32 *const buffer[],
    void *client_data)
{
    parso_flac_decode_context *context = (parso_flac_decode_context *)client_data;
    uint32_t channel;
    uint32_t frame_index;
    size_t frame_count = frame->header.blocksize;
    size_t sample_count;

    (void)decoder;
    if (context->channels == 0 || frame_count > SIZE_MAX / context->channels) {
        context->failed = 1;
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }
    sample_count = frame_count * context->channels;
    if (!parso_flac_reserve(context, sample_count)) {
        context->failed = 1;
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }
    for (frame_index = 0; frame_index < frame_count; ++frame_index) {
        for (channel = 0; channel < context->channels; ++channel)
            context->samples[context->count++] = buffer[channel][frame_index];
    }
    return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
}

static void parso_flac_metadata_callback(
    const FLAC__StreamDecoder *decoder,
    const FLAC__StreamMetadata *metadata,
    void *client_data)
{
    parso_flac_decode_context *context = (parso_flac_decode_context *)client_data;

    (void)decoder;
    if (metadata->type != FLAC__METADATA_TYPE_STREAMINFO)
    {
        if (metadata->type != FLAC__METADATA_TYPE_APPLICATION || metadata->length < 4 ||
            memcmp(metadata->data.application.id, parso_float_application_id, 4) != 0)
            return;
        {
            size_t byte_count = metadata->length - 4;
            if (byte_count == 0 || byte_count % sizeof(uint32_t) != 0) {
                context->failed = 1;
                return;
            }
            context->exact_float_bits = (uint32_t *)malloc(byte_count);
            if (context->exact_float_bits == NULL) {
                context->failed = 1;
                return;
            }
            memcpy(context->exact_float_bits, metadata->data.application.data, byte_count);
            context->exact_count = byte_count / sizeof(uint32_t);
        }
        return;
    }
    context->channels = metadata->data.stream_info.channels;
    context->sample_rate = metadata->data.stream_info.sample_rate;
}

static void parso_flac_error_callback(
    const FLAC__StreamDecoder *decoder,
    FLAC__StreamDecoderErrorStatus status,
    void *client_data)
{
    parso_flac_decode_context *context = (parso_flac_decode_context *)client_data;

    (void)decoder;
    (void)status;
    context->failed = 1;
}

int parso_flac_decode_file(const char *path,
                           int32_t **samples,
                           uint32_t **exact_float_bits,
                           uint64_t *frames,
                           uint32_t *channels,
                           uint32_t *sample_rate)
{
    FLAC__StreamDecoder *decoder;
    FLAC__StreamDecoderInitStatus init_status;
    parso_flac_decode_context context = { 0 };
    FLAC__bool processed;
    FLAC__bool finished;

    if (path == NULL || samples == NULL || exact_float_bits == NULL || frames == NULL ||
        channels == NULL || sample_rate == NULL)
        return 1;
    *samples = NULL;
    *exact_float_bits = NULL;
    *frames = 0;
    *channels = 0;
    *sample_rate = 0;

    decoder = FLAC__stream_decoder_new();
    if (decoder == NULL)
        return 1;
    FLAC__stream_decoder_set_metadata_respond_all(decoder);
    init_status = FLAC__stream_decoder_init_file(
        decoder,
        path,
        parso_flac_write_callback,
        parso_flac_metadata_callback,
        parso_flac_error_callback,
        &context);
    if (init_status != FLAC__STREAM_DECODER_INIT_STATUS_OK) {
        FLAC__stream_decoder_delete(decoder);
        return 2;
    }
    processed = FLAC__stream_decoder_process_until_end_of_stream(decoder);
    finished = FLAC__stream_decoder_finish(decoder);
    FLAC__stream_decoder_delete(decoder);
    if (!processed || !finished || context.failed || context.channels == 0 ||
        context.sample_rate == 0 || context.count % context.channels != 0) {
        free(context.samples);
        free(context.exact_float_bits);
        return 3;
    }

    *samples = context.samples;
    *exact_float_bits = context.exact_float_bits;
    *frames = (uint64_t)(context.count / context.channels);
    *channels = context.channels;
    *sample_rate = context.sample_rate;
    return 0;
}

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

void parso_flac_free(void *pointer)
{
    free(pointer);
}
