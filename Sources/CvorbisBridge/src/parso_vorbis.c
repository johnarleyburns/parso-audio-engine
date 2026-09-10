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
    const uint8_t *data;
    size_t size;
    size_t position;
} parso_vorbis_memory_input;

typedef struct {
    float *samples;
    size_t count;
    size_t capacity;
    uint32_t channels;
    uint32_t sample_rate;
} parso_vorbis_pcm_output;

typedef struct {
    uint8_t *data;
    size_t size;
    size_t capacity;
    int failed;
} parso_vorbis_byte_output;

static size_t parso_vorbis_memory_read(void *destination, size_t size,
                                       size_t count, void *source)
{
    parso_vorbis_memory_input *input = (parso_vorbis_memory_input *)source;
    size_t available;
    size_t items;

    if (size == 0 || input->position > input->size)
        return 0;
    available = input->size - input->position;
    items = available / size;
    if (items > count)
        items = count;
    if (items != 0) {
        memcpy(destination, input->data + input->position, items * size);
        input->position += items * size;
    }
    return items;
}

static int parso_vorbis_memory_seek(void *source, ogg_int64_t offset, int whence)
{
    parso_vorbis_memory_input *input = (parso_vorbis_memory_input *)source;
    ogg_int64_t base;
    ogg_int64_t target;

    if (whence == SEEK_SET)
        base = 0;
    else if (whence == SEEK_CUR)
        base = (ogg_int64_t)input->position;
    else if (whence == SEEK_END)
        base = (ogg_int64_t)input->size;
    else
        return -1;
    target = base + offset;
    if (target < 0 || (uint64_t)target > (uint64_t)input->size)
        return -1;
    input->position = (size_t)target;
    return 0;
}

static int parso_vorbis_memory_close(void *source)
{
    (void)source;
    return 0;
}

static long parso_vorbis_memory_tell(void *source)
{
    const parso_vorbis_memory_input *input = (const parso_vorbis_memory_input *)source;
    return input->position > (size_t)LONG_MAX ? -1L : (long)input->position;
}

static int parso_vorbis_output_reserve(parso_vorbis_pcm_output *output, size_t additional)
{
    size_t required;
    size_t capacity;
    float *resized;

    if (additional > SIZE_MAX - output->count)
        return 0;
    required = output->count + additional;
    if (required <= output->capacity)
        return 1;
    capacity = output->capacity == 0 ? 4096 : output->capacity;
    while (capacity < required) {
        if (capacity > SIZE_MAX / 2)
            return 0;
        capacity *= 2;
    }
    if (capacity > SIZE_MAX / sizeof(float))
        return 0;
    resized = (float *)realloc(output->samples, capacity * sizeof(float));
    if (resized == NULL)
        return 0;
    output->samples = resized;
    output->capacity = capacity;
    return 1;
}

static int parso_vorbis_decode_open(OggVorbis_File *file,
                                    float **samples,
                                    uint64_t *frames,
                                    uint32_t *channels,
                                    uint32_t *sample_rate)
{
    parso_vorbis_pcm_output output = { 0 };
    const vorbis_info *info;
    int section = 0;

    info = ov_info(file, -1);
    if (info == NULL || info->channels < 1 || info->channels > 8 || info->rate <= 0)
        return 1;
    output.channels = (uint32_t)info->channels;
    output.sample_rate = (uint32_t)info->rate;
    for (;;) {
        float **planar = NULL;
        long decoded = ov_read_float(file, &planar, 4096, &section);
        if (decoded == 0)
            break;
        if (decoded < 0 || (uint64_t)decoded >
                (uint64_t)(SIZE_MAX / sizeof(float) / output.channels) ||
            !parso_vorbis_output_reserve(&output,
                (size_t)decoded * output.channels)) {
            free(output.samples);
            return 1;
        }
        for (long frame = 0; frame < decoded; ++frame) {
            for (uint32_t channel = 0; channel < output.channels; ++channel)
                output.samples[output.count++] = planar[channel][frame];
        }
    }
    if (output.count == 0 || output.count % output.channels != 0) {
        free(output.samples);
        return 1;
    }
    *samples = output.samples;
    *frames = (uint64_t)(output.count / output.channels);
    *channels = output.channels;
    *sample_rate = output.sample_rate;
    return 0;
}

static int parso_vorbis_decode_open_file(OggVorbis_File *file,
                                         int16_t **samples,
                                         uint64_t *frames,
                                         uint32_t *channels,
                                         uint32_t *sample_rate)
{
    float *decoded = NULL;
    uint64_t decoded_frames = 0;
    uint32_t decoded_channels = 0;
    uint32_t decoded_rate = 0;
    size_t count;
    int16_t *converted;
    uint64_t index;

    if (parso_vorbis_decode_open(file, &decoded, &decoded_frames,
                                 &decoded_channels, &decoded_rate) != 0)
        return 1;
    if (decoded_frames > UINT64_MAX / decoded_channels ||
        decoded_frames * decoded_channels > SIZE_MAX / sizeof(int16_t)) {
        free(decoded);
        return 1;
    }
    count = (size_t)(decoded_frames * decoded_channels);
    converted = (int16_t *)malloc(count * sizeof(int16_t));
    if (converted == NULL) {
        free(decoded);
        return 1;
    }
    for (index = 0; index < (uint64_t)count; ++index) {
        double value = isfinite(decoded[index]) ? decoded[index] : 0.0;
        int32_t scaled;
        if (value > 1.0) value = 1.0;
        if (value < -1.0) value = -1.0;
        scaled = (int32_t)(value * 32767.0 + (value >= 0.0 ? 0.5 : -0.5));
        if (scaled > INT16_MAX) scaled = INT16_MAX;
        if (scaled < INT16_MIN) scaled = INT16_MIN;
        converted[index] = (int16_t)scaled;
    }
    free(decoded);
    *samples = converted;
    *frames = decoded_frames;
    *channels = decoded_channels;
    *sample_rate = decoded_rate;
    return 0;
}

int parso_vorbis_decode_file(const char *path,
                             int16_t **samples,
                             uint64_t *frames,
                             uint32_t *channels,
                             uint32_t *sample_rate)
{
    OggVorbis_File file;
    int status;

    if (path == NULL || samples == NULL || frames == NULL ||
        channels == NULL || sample_rate == NULL)
        return 1;
    *samples = NULL;
    *frames = 0;
    *channels = 0;
    *sample_rate = 0;
    if (ov_fopen(path, &file) != 0)
        return 2;
    status = parso_vorbis_decode_open_file(&file, samples, frames,
                                           channels, sample_rate);
    ov_clear(&file);
    return status;
}

int parso_vorbis_decode_memory(const uint8_t *data,
                               uint64_t size_bytes,
                               float **samples,
                               uint64_t *frames,
                               uint32_t *channels,
                               uint32_t *sample_rate)
{
    OggVorbis_File file;
    parso_vorbis_memory_input input;
    ov_callbacks callbacks;
    int status;

    if (data == NULL || size_bytes == 0 || size_bytes > SIZE_MAX ||
        samples == NULL || frames == NULL || channels == NULL || sample_rate == NULL)
        return 1;
    *samples = NULL;
    *frames = 0;
    *channels = 0;
    *sample_rate = 0;
    input.data = data;
    input.size = (size_t)size_bytes;
    input.position = 0;
    callbacks.read_func = parso_vorbis_memory_read;
    callbacks.seek_func = parso_vorbis_memory_seek;
    callbacks.close_func = parso_vorbis_memory_close;
    callbacks.tell_func = parso_vorbis_memory_tell;
    if (ov_open_callbacks(&input, &file, NULL, 0, callbacks) != 0)
        return 2;
    status = parso_vorbis_decode_open(&file, samples, frames, channels, sample_rate);
    ov_clear(&file);
    return status;
}

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
