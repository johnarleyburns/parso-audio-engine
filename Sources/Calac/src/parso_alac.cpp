#include "parso_alac.h"

#include "ALACBitUtilities.h"
#include "ALACDecoder.h"
#include "ALACEncoder.h"

#include <cstring>
#include <limits>
#include <new>
#include <cstdlib>

struct parso_alac_encoder {
    ALACEncoder *codec;
    AudioFormatDescription input_format;
    uint32_t channels;
    uint32_t bytes_per_frame;
    uint32_t frames_per_packet;
    uint32_t max_output_bytes;
};

struct parso_alac_decoder {
    ALACDecoder *codec;
    uint32_t sample_rate;
    uint32_t channels;
    uint32_t bit_depth;
    uint32_t frames_per_packet;
    uint32_t bytes_per_frame;
};

namespace {

constexpr uint32_t kMaximumFrameSize = 16384;

uint32_t bytes_per_sample(uint32_t bit_depth)
{
    return (bit_depth + 7u) / 8u;
}

uint32_t encoder_format_flag(uint32_t bit_depth)
{
    switch (bit_depth) {
        case 16: return 1;
        case 20: return 2;
        case 24: return 3;
        case 32: return 4;
        default: return 0;
    }
}

bool valid_bit_depth(uint32_t bit_depth)
{
    return encoder_format_flag(bit_depth) != 0;
}

uint16_t read_be16(const uint8_t *bytes)
{
    return static_cast<uint16_t>((static_cast<uint16_t>(bytes[0]) << 8) | bytes[1]);
}

uint32_t read_be32(const uint8_t *bytes)
{
    return (static_cast<uint32_t>(bytes[0]) << 24) |
           (static_cast<uint32_t>(bytes[1]) << 16) |
           (static_cast<uint32_t>(bytes[2]) << 8) |
           static_cast<uint32_t>(bytes[3]);
}

bool validate_cookie(const uint8_t *cookie,
                     uint32_t cookie_size,
                     uint32_t *sample_rate,
                     uint32_t *channels,
                     uint32_t *bit_depth,
                     uint32_t *frames_per_packet,
                     uint32_t *bytes_per_frame)
{
    if (cookie == nullptr || (cookie_size != 24 && cookie_size != 48))
        return false;

    const uint32_t frame_length = read_be32(cookie);
    const uint32_t cookie_channels = cookie[9];
    const uint32_t cookie_bit_depth = cookie[5];
    const uint32_t cookie_sample_rate = read_be32(cookie + 20);

    if (frame_length == 0 || frame_length > kMaximumFrameSize ||
        cookie[4] != 0 || !valid_bit_depth(cookie_bit_depth) ||
        cookie_channels == 0 || cookie_channels > 8 || cookie_sample_rate == 0 ||
        (cookie_size == 24 && cookie_channels > 2) ||
        (cookie_size == 48 && cookie_channels <= 2))
        return false;

    const uint64_t frame_bytes = static_cast<uint64_t>(cookie_channels) *
                                 bytes_per_sample(cookie_bit_depth);
    if (frame_bytes > std::numeric_limits<uint32_t>::max())
        return false;

    *sample_rate = cookie_sample_rate;
    *channels = cookie_channels;
    *bit_depth = cookie_bit_depth;
    *frames_per_packet = frame_length;
    *bytes_per_frame = static_cast<uint32_t>(frame_bytes);
    return true;
}

} // namespace

extern "C" int parso_alac_encoder_create(uint32_t sample_rate,
                                            uint32_t channels,
                                            uint32_t bit_depth,
                                            uint32_t frames_per_packet,
                                            int fast_mode,
                                            parso_alac_encoder **out_encoder)
{
    if (out_encoder == nullptr)
        return PARSO_ALAC_INVALID_ARGUMENT;
    *out_encoder = nullptr;
    if (sample_rate == 0 || channels == 0 || channels > 8 ||
        !valid_bit_depth(bit_depth) || frames_per_packet == 0 ||
        frames_per_packet > kMaximumFrameSize)
        return PARSO_ALAC_INVALID_ARGUMENT;

    try {
        const uint64_t bytes_per_frame = static_cast<uint64_t>(channels) *
                                         bytes_per_sample(bit_depth);
        const uint64_t max_output = static_cast<uint64_t>(frames_per_packet) *
                                     channels * ((10u + 32u) / 8u) + 1u;
        if (bytes_per_frame > std::numeric_limits<uint32_t>::max() ||
            max_output > std::numeric_limits<uint32_t>::max())
            return PARSO_ALAC_INVALID_ARGUMENT;

        parso_alac_encoder *handle = new (std::nothrow) parso_alac_encoder{};
        if (handle == nullptr)
            return PARSO_ALAC_OUT_OF_MEMORY;

        handle->codec = new (std::nothrow) ALACEncoder();
        if (handle->codec == nullptr) {
            delete handle;
            return PARSO_ALAC_OUT_OF_MEMORY;
        }

        AudioFormatDescription output_format{};
        output_format.mSampleRate = static_cast<double>(sample_rate);
        output_format.mFormatID = kALACFormatAppleLossless;
        output_format.mFormatFlags = encoder_format_flag(bit_depth);
        output_format.mFramesPerPacket = frames_per_packet;
        output_format.mChannelsPerFrame = channels;
        handle->codec->SetFastMode(fast_mode != 0);
        handle->codec->SetFrameSize(frames_per_packet);
        if (handle->codec->InitializeEncoder(output_format) != ALAC_noErr) {
            delete handle->codec;
            delete handle;
            return PARSO_ALAC_CODEC_ERROR;
        }

        handle->input_format = output_format;
        handle->input_format.mFormatFlags = kALACFormatFlagIsSignedInteger |
                                             kALACFormatFlagIsPacked |
                                             kALACFormatFlagsNativeEndian;
        handle->input_format.mBytesPerPacket = static_cast<uint32_t>(bytes_per_frame);
        handle->input_format.mBytesPerFrame = static_cast<uint32_t>(bytes_per_frame);
        handle->input_format.mFramesPerPacket = 1;
        handle->input_format.mBitsPerChannel = bit_depth;
        handle->channels = channels;
        handle->bytes_per_frame = static_cast<uint32_t>(bytes_per_frame);
        handle->frames_per_packet = frames_per_packet;
        handle->max_output_bytes = static_cast<uint32_t>(max_output);
        *out_encoder = handle;
        return PARSO_ALAC_OK;
    } catch (...) {
        return PARSO_ALAC_CODEC_ERROR;
    }
}

extern "C" void parso_alac_encoder_destroy(parso_alac_encoder *encoder)
{
    if (encoder == nullptr)
        return;
    delete encoder->codec;
    delete encoder;
}

extern "C" int parso_alac_encoder_copy_magic_cookie(const parso_alac_encoder *encoder,
                                                       uint8_t *buffer,
                                                       uint32_t buffer_capacity,
                                                       uint32_t *inout_size)
{
    if (encoder == nullptr || inout_size == nullptr)
        return PARSO_ALAC_INVALID_ARGUMENT;

    const uint32_t required = encoder->codec->GetMagicCookieSize(encoder->channels);
    if (buffer == nullptr || buffer_capacity < required) {
        *inout_size = required;
        return PARSO_ALAC_BUFFER_TOO_SMALL;
    }

    uint32_t size = buffer_capacity;
    encoder->codec->GetMagicCookie(buffer, &size);
    if (size != required)
        return PARSO_ALAC_CODEC_ERROR;
    *inout_size = size;
    return PARSO_ALAC_OK;
}

extern "C" int parso_alac_encoder_encode(parso_alac_encoder *encoder,
                                            const uint8_t *pcm,
                                            uint32_t frames,
                                            uint8_t **out_packet,
                                            uint32_t *out_packet_bytes)
{
    if (encoder == nullptr || pcm == nullptr || frames == 0 ||
        frames > encoder->frames_per_packet || out_packet == nullptr ||
        out_packet_bytes == nullptr)
        return PARSO_ALAC_INVALID_ARGUMENT;
    *out_packet = nullptr;
    *out_packet_bytes = 0;

    const uint64_t input_bytes = static_cast<uint64_t>(frames) * encoder->bytes_per_frame;
    if (input_bytes > std::numeric_limits<int32_t>::max())
        return PARSO_ALAC_INVALID_ARGUMENT;

    uint8_t *packet = static_cast<uint8_t *>(std::malloc(encoder->max_output_bytes));
    if (packet == nullptr)
        return PARSO_ALAC_OUT_OF_MEMORY;

    int32_t packet_bytes = static_cast<int32_t>(input_bytes);
    const int32_t status = encoder->codec->Encode(
        encoder->input_format, encoder->input_format,
        const_cast<unsigned char *>(pcm), packet, &packet_bytes);
    if (status != ALAC_noErr || packet_bytes <= 0 ||
        packet_bytes > static_cast<int32_t>(encoder->max_output_bytes)) {
        std::free(packet);
        return PARSO_ALAC_CODEC_ERROR;
    }
    *out_packet = packet;
    *out_packet_bytes = static_cast<uint32_t>(packet_bytes);
    return PARSO_ALAC_OK;
}

extern "C" int parso_alac_decoder_create(const uint8_t *magic_cookie,
                                            uint32_t magic_cookie_size,
                                            parso_alac_decoder **out_decoder)
{
    if (out_decoder == nullptr)
        return PARSO_ALAC_INVALID_ARGUMENT;
    *out_decoder = nullptr;

    uint32_t sample_rate = 0;
    uint32_t channels = 0;
    uint32_t bit_depth = 0;
    uint32_t frames_per_packet = 0;
    uint32_t bytes_per_frame = 0;
    if (!validate_cookie(magic_cookie, magic_cookie_size, &sample_rate, &channels,
                         &bit_depth, &frames_per_packet, &bytes_per_frame))
        return PARSO_ALAC_INVALID_ARGUMENT;

    try {
        parso_alac_decoder *handle = new (std::nothrow) parso_alac_decoder{};
        if (handle == nullptr)
            return PARSO_ALAC_OUT_OF_MEMORY;
        handle->codec = new (std::nothrow) ALACDecoder();
        if (handle->codec == nullptr) {
            delete handle;
            return PARSO_ALAC_OUT_OF_MEMORY;
        }
        if (handle->codec->Init(const_cast<uint8_t *>(magic_cookie), magic_cookie_size) != ALAC_noErr) {
            delete handle->codec;
            delete handle;
            return PARSO_ALAC_CODEC_ERROR;
        }
        handle->sample_rate = sample_rate;
        handle->channels = channels;
        handle->bit_depth = bit_depth;
        handle->frames_per_packet = frames_per_packet;
        handle->bytes_per_frame = bytes_per_frame;
        *out_decoder = handle;
        return PARSO_ALAC_OK;
    } catch (...) {
        return PARSO_ALAC_CODEC_ERROR;
    }
}

extern "C" void parso_alac_decoder_destroy(parso_alac_decoder *decoder)
{
    if (decoder == nullptr)
        return;
    delete decoder->codec;
    delete decoder;
}

extern "C" uint32_t parso_alac_decoder_sample_rate(const parso_alac_decoder *decoder)
{
    return decoder == nullptr ? 0 : decoder->sample_rate;
}

extern "C" uint32_t parso_alac_decoder_channels(const parso_alac_decoder *decoder)
{
    return decoder == nullptr ? 0 : decoder->channels;
}

extern "C" uint32_t parso_alac_decoder_bit_depth(const parso_alac_decoder *decoder)
{
    return decoder == nullptr ? 0 : decoder->bit_depth;
}

extern "C" uint32_t parso_alac_decoder_frames_per_packet(const parso_alac_decoder *decoder)
{
    return decoder == nullptr ? 0 : decoder->frames_per_packet;
}

extern "C" uint32_t parso_alac_decoder_bytes_per_frame(const parso_alac_decoder *decoder)
{
    return decoder == nullptr ? 0 : decoder->bytes_per_frame;
}

extern "C" int parso_alac_decoder_decode(parso_alac_decoder *decoder,
                                            const uint8_t *packet,
                                            uint32_t packet_bytes,
                                            uint8_t *pcm,
                                            uint32_t pcm_capacity,
                                            uint32_t *out_frames)
{
    if (decoder == nullptr || packet == nullptr || packet_bytes < 3 || pcm == nullptr ||
        out_frames == nullptr)
        return PARSO_ALAC_INVALID_ARGUMENT;

    const uint64_t required_output = static_cast<uint64_t>(decoder->frames_per_packet) *
                                     decoder->bytes_per_frame;
    if (required_output > std::numeric_limits<uint32_t>::max() ||
        pcm_capacity < required_output)
        return PARSO_ALAC_BUFFER_TOO_SMALL;

    if (packet_bytes > std::numeric_limits<uint32_t>::max() - 3u)
        return PARSO_ALAC_INVALID_ARGUMENT;
    uint8_t *padded_packet = static_cast<uint8_t *>(std::malloc(packet_bytes + 3u));
    if (padded_packet == nullptr)
        return PARSO_ALAC_OUT_OF_MEMORY;
    std::memcpy(padded_packet, packet, packet_bytes);
    std::memset(padded_packet + packet_bytes, 0, 3);

    BitBuffer bits;
    BitBufferInit(&bits, padded_packet, packet_bytes);
    uint32_t frames = 0;
    const int32_t status = decoder->codec->Decode(
        &bits, pcm, decoder->frames_per_packet, decoder->channels, &frames);
    std::free(padded_packet);
    if (status != ALAC_noErr || frames > decoder->frames_per_packet) {
        *out_frames = 0;
        return PARSO_ALAC_CODEC_ERROR;
    }
    *out_frames = frames;
    return PARSO_ALAC_OK;
}

extern "C" void parso_alac_free(void *pointer)
{
    std::free(pointer);
}
