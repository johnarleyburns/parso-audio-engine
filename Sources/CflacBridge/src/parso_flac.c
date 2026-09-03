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
    uint32_t bits_per_sample;
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
    context->bits_per_sample = metadata->data.stream_info.bits_per_sample;
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
                           uint32_t *sample_rate,
                           uint32_t *bits_per_sample)
{
    FLAC__StreamDecoder *decoder;
    FLAC__StreamDecoderInitStatus init_status;
    parso_flac_decode_context context = { 0 };
    FLAC__bool processed;
    FLAC__bool finished;

    if (path == NULL || samples == NULL || exact_float_bits == NULL || frames == NULL ||
        channels == NULL || sample_rate == NULL || bits_per_sample == NULL)
        return 1;
    *samples = NULL;
    *exact_float_bits = NULL;
    *frames = 0;
    *channels = 0;
    *sample_rate = 0;
    *bits_per_sample = 0;

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
    *bits_per_sample = context.bits_per_sample;
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

/* ── Bounded range decode ─────────────────────────────────────────────────── */

typedef struct {
    int32_t *samples;
    size_t count;      /* interleaved samples written so far */
    size_t capacity;
    uint32_t channels;
    uint32_t sample_rate;
    uint32_t bits_per_sample;
    uint64_t first_frame;   /* absolute source frame the caller asked to start at */
    uint64_t target_frames; /* per-channel frames wanted (plus any lookahead) */
    uint64_t emitted_frames;/* per-channel frames already stored */
    int failed;
    int have_stream_info;
} parso_flac_range_context;

static int parso_flac_range_reserve(parso_flac_range_context *context, size_t additional)
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

static FLAC__StreamDecoderWriteStatus parso_flac_range_write_callback(
    const FLAC__StreamDecoder *decoder,
    const FLAC__Frame *frame,
    const FLAC__int32 *const buffer[],
    void *client_data)
{
    parso_flac_range_context *context = (parso_flac_range_context *)client_data;
    uint32_t block = frame->header.blocksize;
    uint64_t frame_start;
    uint32_t skip = 0;
    uint32_t take;
    uint32_t channel;
    uint32_t i;

    (void)decoder;
    if (context->channels == 0 || block == 0) {
        context->failed = 1;
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }

    /* Where does this block start in the source stream? libFLAC reports either a
     * sample number (post-seek streams use this) or a frame index. */
    if (frame->header.number_type == FLAC__FRAME_NUMBER_TYPE_SAMPLE_NUMBER)
        frame_start = frame->header.number.sample_number;
    else
        frame_start = (uint64_t)frame->header.number.frame_number * block;

    /* Trim any leading samples that fall before the requested first frame. */
    if (frame_start < context->first_frame) {
        uint64_t lead = context->first_frame - frame_start;
        if (lead >= block)
            return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
        skip = (uint32_t)lead;
    }

    if (context->emitted_frames >= context->target_frames)
        return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;

    take = block - skip;
    {
        uint64_t remaining = context->target_frames - context->emitted_frames;
        if ((uint64_t)take > remaining)
            take = (uint32_t)remaining;
    }
    if (take == 0)
        return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;

    if ((uint64_t)take > SIZE_MAX / context->channels ||
        !parso_flac_range_reserve(context, (size_t)take * context->channels)) {
        context->failed = 1;
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }
    for (i = 0; i < take; ++i) {
        for (channel = 0; channel < context->channels; ++channel)
            context->samples[context->count++] = buffer[channel][skip + i];
    }
    context->emitted_frames += take;
    return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
}

static void parso_flac_range_metadata_callback(
    const FLAC__StreamDecoder *decoder,
    const FLAC__StreamMetadata *metadata,
    void *client_data)
{
    parso_flac_range_context *context = (parso_flac_range_context *)client_data;

    (void)decoder;
    if (metadata->type != FLAC__METADATA_TYPE_STREAMINFO)
        return;
    context->channels = metadata->data.stream_info.channels;
    context->sample_rate = metadata->data.stream_info.sample_rate;
    context->bits_per_sample = metadata->data.stream_info.bits_per_sample;
    context->have_stream_info = 1;
}

static void parso_flac_range_error_callback(
    const FLAC__StreamDecoder *decoder,
    FLAC__StreamDecoderErrorStatus status,
    void *client_data)
{
    parso_flac_range_context *context = (parso_flac_range_context *)client_data;

    (void)decoder;
    (void)status;
    context->failed = 1;
}

int parso_flac_decode_range(const char *path,
                            uint64_t first_frame,
                            uint64_t frame_count,
                            int32_t **samples,
                            uint64_t *frames,
                            uint32_t *channels,
                            uint32_t *sample_rate,
                            uint32_t *bits_per_sample,
                            int *seek_unsupported)
{
    FLAC__StreamDecoder *decoder;
    FLAC__StreamDecoderInitStatus init_status;
    parso_flac_range_context context = { 0 };
    FLAC__bool finished;

    if (path == NULL || samples == NULL || frames == NULL || channels == NULL ||
        sample_rate == NULL || bits_per_sample == NULL || seek_unsupported == NULL)
        return 1;
    *samples = NULL;
    *frames = 0;
    *channels = 0;
    *sample_rate = 0;
    *bits_per_sample = 0;
    *seek_unsupported = 0;

    context.first_frame = first_frame;
    context.target_frames = frame_count;

    decoder = FLAC__stream_decoder_new();
    if (decoder == NULL)
        return 1;
    init_status = FLAC__stream_decoder_init_file(
        decoder,
        path,
        parso_flac_range_write_callback,
        parso_flac_range_metadata_callback,
        parso_flac_range_error_callback,
        &context);
    if (init_status != FLAC__STREAM_DECODER_INIT_STATUS_OK) {
        FLAC__stream_decoder_delete(decoder);
        return 2;
    }

    if (!FLAC__stream_decoder_process_until_end_of_metadata(decoder) ||
        context.failed || !context.have_stream_info || context.channels == 0) {
        FLAC__stream_decoder_finish(decoder);
        FLAC__stream_decoder_delete(decoder);
        free(context.samples);
        return 3;
    }

    if (frame_count > 0) {
        if (!FLAC__stream_decoder_seek_absolute(decoder, first_frame)) {
            /* A file stream that refuses a seek has no usable random-access
             * path; report it rather than silently decoding from the top. */
            *seek_unsupported = 1;
            FLAC__stream_decoder_finish(decoder);
            FLAC__stream_decoder_delete(decoder);
            free(context.samples);
            return 4;
        }
        while (context.emitted_frames < context.target_frames && !context.failed) {
            if (!FLAC__stream_decoder_process_single(decoder))
                break;
            if (FLAC__stream_decoder_get_state(decoder) == FLAC__STREAM_DECODER_END_OF_STREAM)
                break;
        }
    }

    finished = FLAC__stream_decoder_finish(decoder);
    FLAC__stream_decoder_delete(decoder);

    if (context.failed || !finished || context.count % context.channels != 0) {
        free(context.samples);
        return 3;
    }

    *samples = context.samples;
    *frames = context.emitted_frames;
    *channels = context.channels;
    *sample_rate = context.sample_rate;
    *bits_per_sample = context.bits_per_sample;
    return 0;
}

void parso_flac_free(void *pointer)
{
    free(pointer);
}
