#include "parso_vorbis.h"

#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "ogg/ogg.h"
#include "vorbis/codec.h"
#include "vorbis/vorbisenc.h"
#include "vorbis/vorbisfile.h"
typedef struct {
    uint8_t *data;
    size_t size;
    size_t capacity;
    int failed;
} parso_vorbis_byte_output;
static int parso_vorbis_bytes_reserve(parso_vorbis_byte_output *output, size_t additional)
{
    size_t required;
    size_t capacity;
    uint8_t *resized;

    if (additional > SIZE_MAX - output->size)
        return 0;
    required = output->size + additional;
    if (required <= output->capacity)
        return 1;
    capacity = output->capacity == 0 ? 4096 : output->capacity;
    while (capacity < required) {
        if (capacity > SIZE_MAX / 2)
            return 0;
        capacity *= 2;
    }
    resized = (uint8_t *)realloc(output->data, capacity);
    if (resized == NULL)
        return 0;
    output->data = resized;
    output->capacity = capacity;
    return 1;
}

static int parso_vorbis_write_page(parso_vorbis_byte_output *output,
                                   const ogg_page *page)
{
    size_t total = (size_t)page->header_len + (size_t)page->body_len;
    if (!parso_vorbis_bytes_reserve(output, total)) {
        output->failed = 1;
        return 0;
    }
    memcpy(output->data + output->size, page->header, (size_t)page->header_len);
    output->size += (size_t)page->header_len;
    memcpy(output->data + output->size, page->body, (size_t)page->body_len);
    output->size += (size_t)page->body_len;
    return 1;
}

static int parso_vorbis_flush_pages(ogg_stream_state *stream,
                                    parso_vorbis_byte_output *output,
                                    int flush)
{
    ogg_page page;
    int produced;
    do {
        produced = flush ? ogg_stream_flush(stream, &page)
                         : ogg_stream_pageout(stream, &page);
        if (produced != 0 && !parso_vorbis_write_page(output, &page))
            return 0;
    } while (produced != 0);
    return output->failed == 0;
}

int parso_vorbis_encode_memory(const float *samples,
                               uint64_t frames,
                               uint32_t channels,
                               uint32_t sample_rate,
                               uint32_t bitrate_kbps,
                               uint8_t **data,
                               uint64_t *size_bytes)
{
    vorbis_info info;
    vorbis_comment comment;
    vorbis_dsp_state dsp;
    vorbis_block block;
    ogg_stream_state stream;
    ogg_packet packet;
    ogg_packet headers[3];
    parso_vorbis_byte_output output = { 0 };
    uint64_t offset = 0;
    int initialized_info = 0;
    int initialized_comment = 0;
    int initialized_dsp = 0;
    int initialized_block = 0;
    int initialized_stream = 0;
    int status = 1;
    float quality;

    if (data == NULL || size_bytes == NULL || samples == NULL || frames == 0 ||
        channels < 1 || channels > 2 || sample_rate < 8000 || sample_rate > 48000 ||
        frames > (uint64_t)LONG_MAX || bitrate_kbps < 16 || bitrate_kbps > 512)
        return 1;
    *data = NULL;
    *size_bytes = 0;
    quality = ((float)bitrate_kbps - 64.0f) / 256.0f;
    if (quality < -0.1f) quality = -0.1f;
    if (quality > 1.0f) quality = 1.0f;
    vorbis_info_init(&info);
    initialized_info = 1;
    if (vorbis_encode_init_vbr(&info, (long)channels, (long)sample_rate, quality) != 0)
        goto cleanup;
    vorbis_comment_init(&comment);
    initialized_comment = 1;
    if (vorbis_analysis_init(&dsp, &info) != 0)
        goto cleanup;
    initialized_dsp = 1;
    if (vorbis_block_init(&dsp, &block) != 0)
        goto cleanup;
    initialized_block = 1;
    if (ogg_stream_init(&stream, 0x50525356) != 0)
        goto cleanup;
    initialized_stream = 1;
    if (vorbis_analysis_headerout(&dsp, &comment,
                                  &headers[0], &headers[1], &headers[2]) != 0 ||
        ogg_stream_packetin(&stream, &headers[0]) != 0 ||
        ogg_stream_packetin(&stream, &headers[1]) != 0 ||
        ogg_stream_packetin(&stream, &headers[2]) != 0 ||
        !parso_vorbis_flush_pages(&stream, &output, 1))
        goto cleanup;

    while (offset < frames) {
        long count = (long)((frames - offset) > 4096 ? 4096 : (frames - offset));
        float **buffer = vorbis_analysis_buffer(&dsp, count);
        long frame;
        uint32_t channel;
        if (buffer == NULL)
            goto cleanup;
        for (frame = 0; frame < count; ++frame) {
            for (channel = 0; channel < channels; ++channel)
                buffer[channel][frame] = samples[(offset + (uint64_t)frame) * channels + channel];
        }
        if (vorbis_analysis_wrote(&dsp, (int)count) != 0)
            goto cleanup;
        offset += (uint64_t)count;
        for (;;) {
            int block_status = vorbis_analysis_blockout(&dsp, &block);
            if (block_status == 0)
                break;
            if (block_status < 0 || vorbis_analysis(&block, NULL) != 0 ||
                vorbis_bitrate_addblock(&block) != 0)
                goto cleanup;
            while (vorbis_bitrate_flushpacket(&dsp, &packet)) {
                if (ogg_stream_packetin(&stream, &packet) != 0 ||
                    !parso_vorbis_flush_pages(&stream, &output, 0))
                    goto cleanup;
            }
        }
    }
    if (vorbis_analysis_wrote(&dsp, 0) != 0)
        goto cleanup;
    for (;;) {
        int block_status = vorbis_analysis_blockout(&dsp, &block);
        if (block_status == 0)
            break;
        if (block_status < 0 || vorbis_analysis(&block, NULL) != 0 ||
            vorbis_bitrate_addblock(&block) != 0)
            goto cleanup;
        while (vorbis_bitrate_flushpacket(&dsp, &packet)) {
            packet.e_o_s = 1;
            if (ogg_stream_packetin(&stream, &packet) != 0 ||
                !parso_vorbis_flush_pages(&stream, &output, 0))
                goto cleanup;
        }
    }
    if (!parso_vorbis_flush_pages(&stream, &output, 1) || output.size == 0)
        goto cleanup;
    *data = output.data;
    *size_bytes = (uint64_t)output.size;
    output.data = NULL;
    status = 0;

cleanup:
    if (initialized_stream) ogg_stream_clear(&stream);
    if (initialized_block) vorbis_block_clear(&block);
    if (initialized_dsp) vorbis_dsp_clear(&dsp);
    if (initialized_comment) vorbis_comment_clear(&comment);
    if (initialized_info) vorbis_info_clear(&info);
    free(output.data);
    return status;
}

void parso_vorbis_free(void *pointer)
{
    free(pointer);
}

