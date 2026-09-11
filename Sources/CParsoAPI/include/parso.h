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
#define PARSO_OFFLINE_SERVICE_ANALYSIS UINT64_C(4)

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
    uint32_t isolator_profile; /* 0 generic, 1 WARM2 (300 Hz / 4 kHz, 4th order) */
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
    uint32_t hop_frames; /* 0: implementation default */
    uint32_t min_bpm;    /* 0: implementation default (60) */
    uint32_t max_bpm;    /* 0: implementation default (190) */
    uint32_t reserved;
} parso_analysis_options_t;

typedef struct {
    uint32_t size;
    uint32_t abi_version;
    double duration_seconds;
    double rms;
    double peak;
    double bpm;
    double bpm_confidence;
} parso_analysis_result_t;

/* Deterministic portable key analysis. Pitch classes use C=0...B=11;
 * mode is 0 for major and 1 for minor; Camelot letters use 0 for B (major)
 * and 1 for A (minor). The result is written in place and owns no memory. */
typedef struct {
    uint32_t size;
    uint32_t abi_version;
    uint32_t window_frames; /* 0: implementation default (8192) */
    uint32_t hop_frames;    /* 0: implementation default (4096) */
    uint32_t min_midi;      /* 0: implementation default (36) */
    uint32_t max_midi;      /* 0: implementation default (96) */
} parso_key_options_t;

typedef struct {
    uint32_t size;
    uint32_t abi_version;
    uint32_t tonic_pitch_class;
    uint32_t is_minor;
    uint32_t camelot_number;
    uint32_t camelot_letter; /* 0: B/major, 1: A/minor */
    double confidence;
} parso_key_result_t;

typedef struct {
    uint32_t size;
    uint32_t abi_version;
    double bpm;              /* 0: implementation default (120) */
    uint32_t max_sections;   /* 0: implementation default (256) */
    uint32_t reserved[2];
} parso_structure_options_t;

typedef struct {
    double start_seconds;
    uint32_t kind;           /* intro, buildup, drop, verse, chorus, breakdown, outro, unknown */
    uint32_t bar;
    double energy;
    double confidence;
} parso_structure_section_t;

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
    /* Mic capture gain, 0...1. Appended to preserve the existing field order. */
    float mic_level;
    /* Portable headless mixer controls used by Linux acceptance artifacts.
     * These are appended so the original transport/mix prefix remains stable. */
    float eq_low[PARSO_MAX_DECKS];
    float eq_mid[PARSO_MAX_DECKS];
    float eq_high[PARSO_MAX_DECKS];
    float color_amount[PARSO_MAX_DECKS];
    float color_kind[PARSO_MAX_DECKS];
    float color_param[PARSO_MAX_DECKS];
    float beatfx_kind;
    float beatfx_beats;
    float beatfx_depth;
    float beatfx_assign;
    float beatfx_on;
    float beatfx_xpad;
    float beatfx_band;
    float master_reverb_send;
    float master_reverb_size;
    float master_reverb_decay;
    float master_reverb_damp;
    float master_reverb_mode;
    /* Global three-band isolator, dB. The portable core currently uses
     * 200 Hz / 2 kHz crossovers; an API-level Warm2 profile can be added
     * without changing this control shape. */
    float master_eq_low;
    float master_eq_mid;
    float master_eq_high;
    float deck_time_ratio[PARSO_MAX_DECKS];
    float deck_pitch[PARSO_MAX_DECKS];
    float deck_keylock[PARSO_MAX_DECKS];
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
    PARSO_COMMAND_PAUSE = 1u,
    PARSO_COMMAND_SET_CUE = 2u,
    PARSO_COMMAND_JUMP_CUE = 3u,
    PARSO_COMMAND_HOTCUE_SET = 4u,
    PARSO_COMMAND_HOTCUE_JUMP = 5u,
    PARSO_COMMAND_HOTCUE_DELETE = 6u,
    PARSO_COMMAND_LOOP_IN = 7u,
    PARSO_COMMAND_LOOP_OUT = 8u,
    PARSO_COMMAND_RELOOP_EXIT = 9u,
    PARSO_COMMAND_BEATLOOP = 10u,
    PARSO_COMMAND_LOOP_SCALE = 11u,
    PARSO_COMMAND_LOOP_MOVE = 12u,
    PARSO_COMMAND_SET_LOOP = 13u,
    PARSO_COMMAND_SET_LOOP_ACTIVE = 14u,
    PARSO_COMMAND_BEATJUMP = 15u,
    PARSO_COMMAND_SYNC = 16u,
    PARSO_COMMAND_SET_MASTER = 17u,
    PARSO_COMMAND_SET_KEYLOCK = 18u,
    PARSO_COMMAND_SET_SLIP = 19u,
    PARSO_COMMAND_JOG_TOUCH = 20u,
    PARSO_COMMAND_JOG_MOVE = 21u,
    PARSO_COMMAND_JOG_RELEASE = 22u,
    PARSO_COMMAND_SEEK = 23u,
    PARSO_COMMAND_UNSYNC = 24u,
    PARSO_COMMAND_STEM_ARM = 25u,
    PARSO_COMMAND_STEM_GAIN = 26u,
    PARSO_COMMAND_STEM_MUTE = 27u,
    PARSO_COMMAND_STEM_SOLO = 28u,
    PARSO_COMMAND_SET_REVERSE = 29u,
    PARSO_COMMAND_VINYL_SPEED = 30u,
    PARSO_COMMAND_ECHO_SET = 31u,
    PARSO_COMMAND_COLORFX_KIND = 32u,
    PARSO_COMMAND_BEATFX_KIND = 33u,
    PARSO_COMMAND_BEATFX_ONOFF = 34u,
    PARSO_COMMAND_BEATFX_RELEASE = 35u,
    PARSO_COMMAND_SAMPLER_TRIGGER = 36u,
    PARSO_COMMAND_SAMPLER_STOP = 37u,
    PARSO_COMMAND_SAMPLER_CONFIG = 38u,
    PARSO_COMMAND_LOAD = 39u
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

/* Render-to-control notifications drained from the bounded native event ring. */
enum {
    PARSO_EVENT_PLAYHEAD = 0u,
    PARSO_EVENT_PEAK = 1u,
    PARSO_EVENT_STATE = 2u,
    PARSO_EVENT_END_OF_TRACK = 3u,
    PARSO_EVENT_BUFFER_RELEASED = 4u
};

typedef struct {
    uint32_t size;
    uint32_t abi_version;
    uint32_t type;
    int32_t deck;
    int64_t frame;
    float f0;
    float f1;
} parso_event_t;

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

/* Deterministic portable summary analysis. The input is borrowed and the
 * result is written in place; no DJ state or render-thread code is involved. */
PARSO_API parso_status_t parso_analysis_options_init(parso_analysis_options_t *options);
PARSO_API parso_status_t parso_analysis_result_init(parso_analysis_result_t *result);
PARSO_API parso_status_t parso_analysis_measure(
    const parso_pcm_buffer_t *input, const parso_analysis_options_t *options,
    parso_analysis_result_t *result
);
PARSO_API parso_status_t parso_key_options_init(parso_key_options_t *options);
PARSO_API parso_status_t parso_key_result_init(parso_key_result_t *result);
PARSO_API parso_status_t parso_key_measure(
    const parso_pcm_buffer_t *input, const parso_key_options_t *options,
    parso_key_result_t *result
);
PARSO_API parso_status_t parso_structure_options_init(parso_structure_options_t *options);
/* Writes caller-owned section records. If capacity is too small, no records
 * are written, *out_count reports the required count, and INVALID_SIZE is
 * returned. */
PARSO_API parso_status_t parso_structure_measure(
    const parso_pcm_buffer_t *input, const parso_structure_options_t *options,
    parso_structure_section_t *sections, uint32_t capacity, uint32_t *out_count
);
/* Generate bucketed mono min/max envelopes into caller-owned arrays. */
PARSO_API parso_status_t parso_waveform_generate(
    const parso_pcm_buffer_t *input, uint32_t bucket_count,
    float *out_min, float *out_max
);

PARSO_API parso_status_t parso_engine_options_init(parso_engine_options_t *options);
PARSO_API parso_status_t parso_control_init(parso_control_t *control);
PARSO_API parso_status_t parso_pcm_view_init(parso_pcm_view_t *view);
PARSO_API parso_status_t parso_output_view_init(parso_output_view_t *view);
PARSO_API parso_status_t parso_command_init(parso_command_t *command);
PARSO_API parso_status_t parso_stats_init(parso_stats_t *stats);
PARSO_API parso_status_t parso_event_init(parso_event_t *event);

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
/* Provide a borrowed planar capture block for the mic strip. The host owns
 * the planes and must keep them alive until the next mic-buffer replacement
 * or engine destruction. The block is consumed from the start on render. */
PARSO_API parso_status_t parso_engine_set_mic_buffer(
    parso_engine_t *engine,
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
/* Render the headphone/monitor bus for the same callback block immediately
 * after parso_engine_render. The output view is caller-owned and uses the
 * engine's negotiated sample rate and frame limit. */
PARSO_API parso_status_t parso_engine_render_monitor(
    parso_engine_t *engine,
    const parso_output_view_t *output
);
/* Render the booth bus from the most recently rendered master block. Call
 * once per cycle, immediately after parso_engine_render, with the same frame
 * count. */
PARSO_API parso_status_t parso_engine_render_booth(
    parso_engine_t *engine,
    const parso_output_view_t *output
);
/* Drain up to max_events without blocking. Events are copied into caller-owned storage. */
PARSO_API parso_status_t parso_engine_poll_events(
    parso_engine_t *engine, parso_event_t *events, uint32_t max_events,
    uint32_t *out_events
);
PARSO_API parso_status_t parso_engine_get_stats(
    const parso_engine_t *engine,
    parso_stats_t *stats
);

/* Off-thread master record tap. Recording activation/reset and draining are
 * control-side operations; the render callback only copies into the bounded
 * native ring. Drain outputs are caller-owned planar float32 buffers. */
PARSO_API parso_status_t parso_engine_record_set_active(
    parso_engine_t *engine, uint32_t active
);
PARSO_API parso_status_t parso_engine_record_drain(
    parso_engine_t *engine, float *left, float *right,
    uint32_t max_frames, uint32_t *out_frames
);
PARSO_API parso_status_t parso_engine_record_dropped_frames(
    const parso_engine_t *engine, uint64_t *out_frames
);
PARSO_API parso_status_t parso_engine_record_reset(parso_engine_t *engine);

#ifdef __cplusplus
}
#endif

#endif /* PARSO_H */
