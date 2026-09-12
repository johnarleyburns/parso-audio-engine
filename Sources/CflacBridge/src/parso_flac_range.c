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
