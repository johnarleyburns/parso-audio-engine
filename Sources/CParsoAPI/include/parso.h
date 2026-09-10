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
    uint32_t sample_rate_hz;
    uint32_t max_frames;
    uint32_t deck_count;
    uint32_t reserved;
} parso_engine_options_t;

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
