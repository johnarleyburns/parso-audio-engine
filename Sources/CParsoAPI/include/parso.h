/*
 * parso.h — versioned public C ABI for the portable headless engine.
 *
 * The API intentionally exposes opaque handles and fixed-width POD fields.
 * PCM views are borrowed: callers must keep their planes alive until the next
 * buffer replacement or engine destruction. Control and buffer operations
 * belong to one serialized producer; render belongs to one audio thread.
 */
#ifndef PARSO_H
#define PARSO_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) && defined(PARSO_BUILD_SHARED)
#  if defined(PARSO_BUILDING_LIBRARY)
#    define PARSO_API __declspec(dllexport)
#  else
#    define PARSO_API __declspec(dllimport)
#  endif
#elif defined(__GNUC__) || defined(__clang__)
#  define PARSO_API __attribute__((visibility("default")))
#else
#  define PARSO_API
#endif

#define PARSO_ABI_VERSION 1u
#define PARSO_MAX_DECKS 4u

/* Container capability bits. A bit is set only when that operation is
 * implemented by the current native build; callers must handle missing bits
 * as an explicit unsupported-format result. */
#define PARSO_CONTAINER_WAV UINT64_C(1)
#define PARSO_CONTAINER_FLAC UINT64_C(2)
#define PARSO_CONTAINER_OGG_VORBIS UINT64_C(4)
#define PARSO_CONTAINER_OPUS UINT64_C(8)
#define PARSO_CONTAINER_MP3 UINT64_C(16)
#define PARSO_CONTAINER_AAC UINT64_C(32)
#define PARSO_CONTAINER_ALAC UINT64_C(64)
#define PARSO_CONTAINER_AIFF UINT64_C(128)
#define PARSO_CONTAINER_CAF UINT64_C(256)

/* Raw PCM sample-format capability bits. PCM buffers exposed by this ABI are
 * always interleaved float32; these bits describe the on-disk/raw byte forms
 * accepted by the offline conversion functions. */
#define PARSO_PCM_FORMAT_S8 UINT64_C(1)
#define PARSO_PCM_FORMAT_S16_LE UINT64_C(2)
#define PARSO_PCM_FORMAT_S24_LE UINT64_C(4)
#define PARSO_PCM_FORMAT_S32_LE UINT64_C(8)
#define PARSO_PCM_FORMAT_F32_LE UINT64_C(16)
#define PARSO_PCM_FORMAT_F64_LE UINT64_C(32)

/* Offline service capability bits. */
#define PARSO_OFFLINE_SERVICE_SRC UINT64_C(1)
#define PARSO_OFFLINE_SERVICE_LOUDNESS UINT64_C(2)

/* Explicit byte-oriented codec selectors. These values intentionally do not
 * depend on C enum layout so they remain stable across language bindings. */
#define PARSO_CODEC_WAV 1u
#define PARSO_CODEC_FLAC 2u
#define PARSO_CODEC_OGG_VORBIS 3u
#define PARSO_CODEC_OPUS 4u
#define PARSO_CODEC_MP3 5u
#define PARSO_CODEC_AAC 6u

/* Use this value for a constant-bitrate encode. */
#define PARSO_CODEC_VBR_CBR UINT32_MAX

typedef int32_t parso_status_t;
enum {
    PARSO_STATUS_OK = 0,
    PARSO_STATUS_INVALID_ARGUMENT = -1,
    PARSO_STATUS_INVALID_SIZE = -2,
    PARSO_STATUS_UNSUPPORTED = -3,
    PARSO_STATUS_OUT_OF_MEMORY = -4,
    PARSO_STATUS_QUEUE_FULL = -5,
    PARSO_STATUS_CLOSED = -6,
    PARSO_STATUS_INTERNAL = -7
};

typedef struct parso_engine parso_engine_t;

typedef struct {
    uint32_t size;
    uint32_t abi_version;
    uint64_t decode_containers;
    uint64_t encode_containers;
    uint64_t pcm_read_formats;
    uint64_t pcm_write_formats;
    uint32_t max_channels;
    uint32_t max_sample_rate_hz;
    /* Reuses the original eight-byte reserved tail without changing layout. */
    uint64_t offline_services;
} parso_capabilities_t;

/* Interleaved float32 PCM owned by the native library after a read. The
 * caller must release it with parso_pcm_buffer_release. */
typedef struct {
    uint32_t size;
    uint32_t abi_version;
    float *samples;
    uint64_t frames;
    uint32_t channel_count;
    uint32_t sample_rate_hz;
} parso_pcm_buffer_t;

/* Byte storage returned by an offline writer. The caller must release it with
 * parso_bytes_release; it is never borrowed from an input buffer. */
typedef struct {
    uint32_t size;
    uint32_t abi_version;
    uint8_t *data;
    uint64_t size_bytes;
    uint32_t reserved[2];
} parso_bytes_t;

typedef struct {
    uint32_t size;
    uint32_t abi_version;
    uint32_t compression_level; /* FLAC: 0...8; default 5 */
    uint32_t bitrate_kbps;      /* MP3/AAC/Opus; default 192 */
    uint32_t bits_per_sample;  /* FLAC/WAV integer output; default 16 */
    uint32_t wav_is_float;     /* WAV only: 0 integer, 1 IEEE float */
    uint32_t quality;          /* Glint quality: 0 speed, 1 normal, 2 best */
    uint32_t vbr_quality;      /* 0...9, or PARSO_CODEC_VBR_CBR */
    uint32_t reserved[2];
} parso_codec_options_t;

typedef struct {
    uint32_t size;
    uint32_t abi_version;
    uint32_t sample_rate_hz;
    uint32_t max_frames;
    uint32_t deck_count;
    uint32_t reserved;
} parso_engine_options_t;

enum {
    PARSO_SRC_QUALITY_BEST = 0u,
    PARSO_SRC_QUALITY_MEDIUM = 1u,
    PARSO_SRC_QUALITY_FASTEST = 2u
};

typedef struct {
    uint32_t size;
    uint32_t abi_version;
    uint32_t source_sample_rate_hz;      /* 0: use the input buffer rate */
    uint32_t destination_sample_rate_hz;
    uint32_t channel_count;              /* 0: use the input buffer channels */
    uint32_t quality;                    /* one of PARSO_SRC_QUALITY_* */
    uint32_t reserved[2];
} parso_src_options_t;

typedef struct {
    uint32_t size;
    uint32_t abi_version;
    double target_lufs;
    uint32_t reserved[2];
} parso_loudness_options_t;

typedef struct {
    uint32_t size;
    uint32_t abi_version;
    double integrated_lufs;
    double true_peak_dbtp;
    double gain_to_target_db;
    double loudness_range_lu;
} parso_loudness_result_t;

typedef struct {
    uint32_t size;
    uint32_t abi_version;
    float crossfader;
    float xfade_curve;
    float master_level;
    float limiter_ceiling_db;
    float limiter_enabled;
    float xfade_assign[PARSO_MAX_DECKS];
    float fader[PARSO_MAX_DECKS];
    float trim[PARSO_MAX_DECKS];
} parso_control_t;

/* Planar, non-interleaved, borrowed 32-bit float PCM. */
typedef struct {
    uint32_t size;
    uint32_t abi_version;
    const float *const *planes;
    uint64_t frames;
    uint32_t channel_count; /* 1 or 2 */
    uint32_t sample_rate_hz;
} parso_pcm_view_t;

typedef struct {
    uint32_t size;
    uint32_t abi_version;
    float *left;
    float *right;
    uint32_t frames;
    uint32_t reserved;
} parso_output_view_t;

enum {
    PARSO_COMMAND_PLAY = 0u,
    PARSO_COMMAND_PAUSE = 1u
};

typedef struct {
    uint32_t size;
    uint32_t abi_version;
    uint32_t type;
    int32_t deck;
    int32_t i0;
    int32_t i1;
    int32_t i2;
    float f0;
    float f1;
} parso_command_t;

typedef struct {
    uint32_t size;
    uint32_t abi_version;
    uint64_t master_frame;
    uint64_t starved_frames;
    uint32_t deck_count;
    uint32_t reserved;
} parso_stats_t;

PARSO_API const char *parso_last_error(void);
PARSO_API const char *parso_status_string(parso_status_t status);

PARSO_API parso_status_t parso_capabilities_init(parso_capabilities_t *capabilities);
PARSO_API parso_status_t parso_capabilities_get(parso_capabilities_t *capabilities);
PARSO_API parso_status_t parso_pcm_buffer_init(parso_pcm_buffer_t *buffer);
/* Idempotent; clears the buffer after releasing its owned samples. */
PARSO_API parso_status_t parso_pcm_buffer_release(parso_pcm_buffer_t *buffer);
PARSO_API parso_status_t parso_bytes_init(parso_bytes_t *bytes);
/* Idempotent; clears the byte buffer after releasing its owned storage. */
PARSO_API parso_status_t parso_bytes_release(parso_bytes_t *bytes);

/* Byte-oriented codec services. Input bytes and PCM samples are borrowed for
 * the duration of the call. Results own their storage and must be released by
 * the matching idempotent release function. Ogg Vorbis uses Xiph libvorbisenc.
 * AAC is ADTS and Opus is Ogg Opus. */
PARSO_API parso_status_t parso_codec_options_init(parso_codec_options_t *options);
PARSO_API parso_status_t parso_codec_read(
    const uint8_t *data, uint64_t size_bytes, uint32_t codec,
    const parso_codec_options_t *options, parso_pcm_buffer_t *out_buffer
);
PARSO_API parso_status_t parso_codec_write(
    const parso_pcm_buffer_t *input, uint32_t codec,
    const parso_codec_options_t *options, parso_bytes_t *out_bytes
);

/* Offline WAV/PCM services. Input bytes and writer input samples are borrowed
 * for the duration of the call. Raw PCM uses little-endian integer PCM with
 * 8/16/24/32 bits; 8-bit PCM is unsigned as required by RIFF/WAVE. */
PARSO_API parso_status_t parso_wav_read(
    const uint8_t *data, uint64_t size_bytes, parso_pcm_buffer_t *out_buffer
);
PARSO_API parso_status_t parso_pcm_read(
    const uint8_t *data, uint64_t size_bytes, uint32_t sample_rate_hz,
    uint32_t channel_count, uint32_t bits_per_sample, parso_pcm_buffer_t *out_buffer
);
PARSO_API parso_status_t parso_wav_write(
    const parso_pcm_buffer_t *buffer, uint32_t bits_per_sample,
    uint32_t is_float, parso_bytes_t *out_bytes
);
PARSO_API parso_status_t parso_pcm_write(
    const parso_pcm_buffer_t *buffer, uint32_t bits_per_sample,
    parso_bytes_t *out_bytes
);

/* Offline sample-rate conversion. The input is borrowed; the output owns its
 * interleaved float32 samples and is released with parso_pcm_buffer_release. */
PARSO_API parso_status_t parso_src_options_init(parso_src_options_t *options);
PARSO_API parso_status_t parso_src_convert(
    const parso_pcm_buffer_t *input, const parso_src_options_t *options,
    parso_pcm_buffer_t *out_buffer
);

/* Offline EBU R128 loudness measurement. Negative infinity represents a
 * measurement with no gated loudness, such as digital silence. */
PARSO_API parso_status_t parso_loudness_options_init(parso_loudness_options_t *options);
PARSO_API parso_status_t parso_loudness_result_init(parso_loudness_result_t *result);
PARSO_API parso_status_t parso_loudness_measure(
    const parso_pcm_buffer_t *input, const parso_loudness_options_t *options,
    parso_loudness_result_t *result
);

PARSO_API parso_status_t parso_engine_options_init(parso_engine_options_t *options);
PARSO_API parso_status_t parso_control_init(parso_control_t *control);
PARSO_API parso_status_t parso_pcm_view_init(parso_pcm_view_t *view);
PARSO_API parso_status_t parso_output_view_init(parso_output_view_t *view);
PARSO_API parso_status_t parso_command_init(parso_command_t *command);
PARSO_API parso_status_t parso_stats_init(parso_stats_t *stats);

PARSO_API parso_status_t parso_engine_create(
    const parso_engine_options_t *options,
    parso_engine_t **out_engine
);
/* Destroys and clears *engine; calling again with the same variable is safe. */
PARSO_API parso_status_t parso_engine_destroy(parso_engine_t **engine);
PARSO_API parso_status_t parso_engine_set_control(
    parso_engine_t *engine,
    const parso_control_t *control
);
PARSO_API parso_status_t parso_engine_set_deck_buffer(
    parso_engine_t *engine,
    uint32_t deck,
    const parso_pcm_view_t *view
);
PARSO_API parso_status_t parso_engine_post_command(
    parso_engine_t *engine,
    const parso_command_t *command
);
PARSO_API parso_status_t parso_engine_render(
    parso_engine_t *engine,
    const parso_output_view_t *output
);
PARSO_API parso_status_t parso_engine_get_stats(
    const parso_engine_t *engine,
    parso_stats_t *stats
);

#ifdef __cplusplus
}
#endif

#endif /* PARSO_H */
