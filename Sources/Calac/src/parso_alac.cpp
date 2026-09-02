// First-party placeholder for the portable ALAC C API.
//
// The implementation previously vendored from Apple's public-source ALAC
// repository was removed after legal review. Only the public headers remain;
// portable ALAC will stay unavailable until a new independently authored,
// permissively licensed implementation is added.

#include "parso_alac.h"

extern "C" int parso_alac_encoder_create(uint32_t, uint32_t, uint32_t, uint32_t,
                                          int, parso_alac_encoder **out_encoder) {
    if (out_encoder) *out_encoder = nullptr;
    return PARSO_ALAC_CODEC_ERROR;
}

extern "C" void parso_alac_encoder_destroy(parso_alac_encoder *) {}

extern "C" int parso_alac_encoder_copy_magic_cookie(const parso_alac_encoder *,
                                                     uint8_t *, uint32_t, uint32_t *) {
    return PARSO_ALAC_CODEC_ERROR;
}

extern "C" int parso_alac_encoder_encode(parso_alac_encoder *, const uint8_t *, uint32_t,
                                          uint8_t **out_packet, uint32_t *out_packet_bytes) {
    if (out_packet) *out_packet = nullptr;
    if (out_packet_bytes) *out_packet_bytes = 0;
    return PARSO_ALAC_CODEC_ERROR;
}

extern "C" int parso_alac_decoder_create(const uint8_t *, uint32_t,
                                          parso_alac_decoder **out_decoder) {
    if (out_decoder) *out_decoder = nullptr;
    return PARSO_ALAC_CODEC_ERROR;
}

extern "C" void parso_alac_decoder_destroy(parso_alac_decoder *) {}

extern "C" uint32_t parso_alac_decoder_sample_rate(const parso_alac_decoder *) { return 0; }
extern "C" uint32_t parso_alac_decoder_channels(const parso_alac_decoder *) { return 0; }
extern "C" uint32_t parso_alac_decoder_bit_depth(const parso_alac_decoder *) { return 0; }
extern "C" uint32_t parso_alac_decoder_frames_per_packet(const parso_alac_decoder *) { return 0; }
extern "C" uint32_t parso_alac_decoder_bytes_per_frame(const parso_alac_decoder *) { return 0; }

extern "C" int parso_alac_decoder_decode(parso_alac_decoder *, const uint8_t *, uint32_t,
                                          uint8_t *, uint32_t, uint32_t *out_frames) {
    if (out_frames) *out_frames = 0;
    return PARSO_ALAC_CODEC_ERROR;
}

extern "C" void parso_alac_free(void *) {}
