/*
 * CParsoMix — a lean stereo two-deck player for automatic DJ blends.
 *
 * The DJ engine (CParsoEngine) sums every deck to mono and reads with linear
 * interpolation; that suits a controller, not album playback. This core keeps
 * full stereo end to end and does only what an automatic blend needs:
 *
 *   - each deck plays caller-owned PCM at the engine's sample rate, from a
 *     source position that lands exactly on a master frame (sample-accurate,
 *     also inside a render block);
 *   - one fixed tempo per deck: keylocked time-stretch (Signalsmith Stretch,
 *     MIT) when it differs from 1 by more than 0.2 %, else a cubic varispeed
 *     read (≤ 3.4 cents). Source positions are computed from the master frame,
 *     never accumulated, so a deck cannot drift;
 *   - a 4th-order Linkwitz–Riley split at 150 Hz in every deck's path from its
 *     first sample (switching a crossover in mid-stream clicks: its band sum is
 *     an all-pass, not the dry signal);
 *   - per-sample band gains from a blend recipe evaluated on the render thread
 *     (bass swap on a downbeat, or a phrase cut).
 *
 * Threading: pm_render runs on the real-time thread and never allocates,
 * locks or calls out. Everything else is control-thread only. A deck is
 * prepared while it is idle (the render thread does not touch it), then armed
 * with pm_deck_start; the render thread hands it back by setting it finished.
 */
#ifndef PARSO_MIX_H
#define PARSO_MIX_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PM_MAX_DECKS 2

typedef struct pm_engine pm_engine;

typedef enum {
    PM_DECK_IDLE = 0,      /* control thread owns it */
    PM_DECK_ARMED = 1,     /* waiting for its start frame */
    PM_DECK_PLAYING = 2,
    PM_DECK_FINISHED = 3   /* ran out of source or was released by a recipe / stop */
} pm_deck_state;

/* sample_rate is the output rate; every deck's PCM must already be at it. */
pm_engine* pm_create(double sample_rate, int max_frames);
void pm_destroy(pm_engine*);

/*
 * Control thread, deck IDLE or FINISHED. `left`/`right` stay owned by the
 * caller and must outlive playback (right may equal left for mono).
 * `source_position` is the source frame heard at the start frame (may be
 * negative: silence until the source begins). `tempo` > 0 is source frames per
 * output frame. `gain` is a linear level (loudness match). Primes the
 * stretcher so its first output is exactly `source_position` (no latency).
 * Returns 0, or -1 for bad arguments / wrong state.
 */
int pm_deck_prepare(pm_engine*, int deck, const float* left, const float* right,
                    int64_t frames, double source_position, double tempo, float gain);
/* Arms a prepared deck: its audio begins at master frame `start_frame`. */
int pm_deck_start(pm_engine*, int deck, int64_t start_frame);
/* Asks the render thread to release the deck (it becomes FINISHED). */
void pm_deck_stop(pm_engine*, int deck);
/* Control thread: FINISHED -> IDLE so the deck can be prepared again. */
int pm_deck_reset(pm_engine*, int deck);
int pm_deck_state_of(pm_engine*, int deck);
/* Source position (frames) at the last rendered frame; NaN when not playing. */
double pm_deck_position(pm_engine*, int deck);
/* 1 when keylocked time-stretch is engaged for the prepared tempo. */
int pm_deck_keylocked(pm_engine*, int deck);

/*
 * Bass-swap blend, all times in master frames (fractional allowed), beat b
 * counted from `start_frame`, q = overlap_beats / 4:
 *   incoming highs   smoothstep(b / q)                       in over 4 bars
 *   basses swap      smoothstep((b - (2q - 0.25)) / 0.25)    completes ON beat 2q
 *   outgoing highs   1 - smoothstep((b - 3q) / q)            out over the last 4 bars
 * Before the start the incoming deck is silent; at the end the outgoing deck
 * is released and the incoming one plays flat.
 */
void pm_schedule_bass_swap(pm_engine*, int outgoing, int incoming, double start_frame,
                           double frames_per_beat, int overlap_beats);
/*
 * Phrase cut (no overlap): the outgoing fades out (cosine) over `fade_frames`
 * ending at `cut_frame`, then is released; the incoming is silent until
 * 3 ms before the cut and ramps in linearly to the cut.
 */
void pm_schedule_cut(pm_engine*, int outgoing, int incoming, double cut_frame, double fade_frames);
void pm_clear_recipe(pm_engine*);

int64_t pm_master_frame(pm_engine*);

/*
 * Offline: the whole of `in` at `tempo` exactly as a deck plays it (keylocked
 * time-stretch beyond ±0.2 %, cubic varispeed within), without the crossover.
 * Writes `out_frames` = floor(frames / tempo) frames per channel. For analysing
 * the incoming track as it will sound. Allocates; control thread only.
 * Returns 0, or -1 on bad arguments.
 */
int pm_render_tempo(double sample_rate, const float* in_left, const float* in_right, int64_t frames,
                    double tempo, float* out_left, float* out_right, int64_t out_frames);
/* Real-time thread. frames <= max_frames. Writes (not adds) both outputs. */
void pm_render(pm_engine*, float* left, float* right, int frames);

#ifdef __cplusplus
}
#endif

#endif /* PARSO_MIX_H */
