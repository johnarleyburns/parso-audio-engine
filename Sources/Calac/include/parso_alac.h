#ifndef PARSO_ALAC_H
#define PARSO_ALAC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct parso_alac_encoder parso_alac_encoder;
typedef struct parso_alac_decoder parso_alac_decoder;

enum {
    PARSO_ALAC_OK = 0,
    PARSO_ALAC_INVALID_ARGUMENT = 1,
    PARSO_ALAC_OUT_OF_MEMORY = 2,
    PARSO_ALAC_CODEC_ERROR = 3,
    PARSO_ALAC_BUFFER_TOO_SMALL = 4
};

/*
 * Creates an offline encoder for native-endian, signed, packed integer PCM.
 * Supported depths are 16, 20, 24, and 32 bits; frames_per_packet is at most
 * 16384. The handle and all codec allocations are control-thread objects.
 */
int parso_alac_encoder_create(uint32_t sample_rate,
                              uint32_t channels,
                              uint32_t bit_depth,
                              uint32_t frames_per_packet,
                              int fast_mode,
                              parso_alac_encoder **out_encoder);

void parso_alac_encoder_destroy(parso_alac_encoder *encoder);

/* The cookie is the raw 24- or 48-byte ALAC magic cookie, without an atom. */
int parso_alac_encoder_copy_magic_cookie(const parso_alac_encoder *encoder,
                                         uint8_t *buffer,
                                         uint32_t buffer_capacity,
                                         uint32_t *inout_size);

/* Encodes one packet. The returned packet must be released with parso_alac_free. */
int parso_alac_encoder_encode(parso_alac_encoder *encoder,
                              const uint8_t *pcm,
                              uint32_t frames,
                              uint8_t **out_packet,
                              uint32_t *out_packet_bytes);

int parso_alac_decoder_create(const uint8_t *magic_cookie,
                              uint32_t magic_cookie_size,
                              parso_alac_decoder **out_decoder);

void parso_alac_decoder_destroy(parso_alac_decoder *decoder);

uint32_t parso_alac_decoder_sample_rate(const parso_alac_decoder *decoder);
uint32_t parso_alac_decoder_channels(const parso_alac_decoder *decoder);
uint32_t parso_alac_decoder_bit_depth(const parso_alac_decoder *decoder);
uint32_t parso_alac_decoder_frames_per_packet(const parso_alac_decoder *decoder);
uint32_t parso_alac_decoder_bytes_per_frame(const parso_alac_decoder *decoder);

/* Decodes one packet to native-endian, signed, packed integer PCM. */
int parso_alac_decoder_decode(parso_alac_decoder *decoder,
                              const uint8_t *packet,
                              uint32_t packet_bytes,
                              uint8_t *pcm,
                              uint32_t pcm_capacity,
                              uint32_t *out_frames);

void parso_alac_free(void *pointer);

#ifdef __cplusplus
}
#endif

#endif
