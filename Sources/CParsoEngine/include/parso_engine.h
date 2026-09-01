/*
 * parso_engine.h — C-clean public API for the real-time DJ render graph.
 * Two decks -> channel processing -> crossfader -> master chain -> limiter.
 * Driven from Swift's AVAudioSourceNode render block (pe_render) OR synchronously
 * for tests (pe_step). All RT-safe. See docs/SPEC.md §8, §11, §12.
 */
#ifndef PARSO_ENGINE_H
#define PARSO_ENGINE_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct pe_engine pe_engine;

/* Continuous, latest-wins parameters (atomics inside). Swift writes; RT reads+smooths. */
typedef struct {
    float crossfader;        /* -1..+1 */
    float xfade_curve;       /* 0 smooth .. 1 sharp */
    float master_level;      /* 0..1 */
    float mic_level;         /* 0..1 */
    float cue_master_mix;    /* 0..1 (headphone blend) */
    float master_cue;        /* 0/1 */
    float headphone_level;   /* 0..1 */
    float cue_pfl[2];        /* per-channel pre-listen 0/1 */
    /* per channel [0]=A [1]=B */
    float trim[2];
    float eq_low[2], eq_mid[2], eq_high[2]; /* dB, -INFINITY == kill */
    float color_amount[2];   /* -1..+1 */
    float fader[2];          /* 0..1 */
    float deck_time_ratio[2];
    float deck_pitch[2];     /* semitones */
} pe_control;

/* Discrete commands (SPSC ring). One struct, tagged. */
typedef enum {
    PE_CMD_PLAY, PE_CMD_PAUSE, PE_CMD_SET_CUE, PE_CMD_JUMP_CUE,
    PE_CMD_HOTCUE_SET, PE_CMD_HOTCUE_JUMP, PE_CMD_HOTCUE_DELETE,
    PE_CMD_LOOP_IN, PE_CMD_LOOP_OUT, PE_CMD_RELOOP_EXIT, PE_CMD_BEATLOOP, PE_CMD_LOOP_SCALE,
    PE_CMD_LOOP_MOVE, PE_CMD_SET_LOOP, PE_CMD_SET_LOOP_ACTIVE,
    PE_CMD_BEATJUMP, PE_CMD_SYNC, PE_CMD_SET_MASTER, PE_CMD_SET_KEYLOCK, PE_CMD_SET_SLIP,
    PE_CMD_JOG_TOUCH, PE_CMD_JOG_MOVE, PE_CMD_JOG_RELEASE,
    PE_CMD_COLORFX_KIND, PE_CMD_BEATFX_KIND, PE_CMD_BEATFX_ONOFF, PE_CMD_BEATFX_RELEASE,
    PE_CMD_SAMPLER_TRIGGER, PE_CMD_SAMPLER_STOP,
    PE_CMD_LOAD  /* buffer handle in i0(ptr low), i1(ptr high), f0=sampleRate, i2=frames */
} pe_cmd_type;

typedef struct {
    pe_cmd_type type;
    int32_t deck;     /* 0=A 1=B, -1=n/a */
    int32_t i0, i1, i2;
    float   f0, f1;
} pe_command;

/* Events pushed RT -> Swift (SPSC ring). */
typedef enum { PE_EVT_PLAYHEAD, PE_EVT_PEAK, PE_EVT_STATE, PE_EVT_END_OF_TRACK, PE_EVT_BUFFER_RELEASED } pe_evt_type;
typedef struct { pe_evt_type type; int32_t deck; int64_t frame; float f0, f1; } pe_event;

pe_engine* pe_create(double sample_rate, int max_frames);
void       pe_destroy(pe_engine*);

/* Atomically publish the latest control snapshot. */
void pe_set_control(pe_engine*, const pe_control*);
/* Enqueue a discrete command (non-blocking; returns 1 ok, 0 if ring full). */
int  pe_post_command(pe_engine*, const pe_command*);
/* Drain up to max events; returns count. */
int  pe_poll_events(pe_engine*, pe_event* out, int max);

/* Provide a resident, caller-owned PCM buffer for a deck (kept alive until BUFFER_RELEASED). */
void pe_deck_set_buffer(pe_engine*, int deck, const float* const* channels, int channel_count,
                        int64_t frames, double sample_rate);
/* Provide a sampler slot buffer (0..15). */
void pe_sampler_set_slot(pe_engine*, int slot, const float* const* channels, int channel_count, int64_t frames);
/* Provide a resident mic capture block. The block is consumed from the start on the next render. */
void pe_mic_set_buffer(pe_engine*, const float* const* channels, int channel_count,
                       int64_t frames, double sample_rate);

/* RT render entry point (call from the audio render block). Interleaved-out is NOT used;
 * writes non-interleaved stereo master into out_l/out_r. */
void pe_render(pe_engine*, float* out_l, float* out_r, int frames);
/* Optional second bus: headphone/monitor mix (cue vs master). */
void pe_render_monitor(pe_engine*, float* out_l, float* out_r, int frames);

/* Synchronous, device-free advance for deterministic tests. Identical DSP to pe_render. */
void pe_step(pe_engine*, float* out_l, float* out_r, int frames);

#ifdef __cplusplus
}
#endif
#endif /* PARSO_ENGINE_H */
