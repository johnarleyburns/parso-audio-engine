/*
 * parso_engine.h — C-clean public API for the real-time DJ render graph.
 * Up to PE_MAX_DECKS decks -> channel processing -> crossfader -> master chain
 * -> limiter. Deck count is fixed at pe_create time (2..PE_MAX_DECKS); the
 * CDJ-3000 booth target is 4 (docs/CDJ3000-parity-research.md C1).
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

/* Maximum decks / mixer channels the render graph can be created with. */
#define PE_MAX_DECKS 4

typedef struct pe_engine pe_engine;

/* Continuous, latest-wins parameters (atomics inside). Swift writes; RT reads+smooths. */
typedef struct {
    float crossfader;        /* -1..+1 */
    float xfade_curve;       /* 0 smooth .. 1 sharp */
    float master_level;      /* 0..1 */
    float limiter_ceiling_db;/* dBTP, normally -0.3 */
    float mic_level;         /* 0..1 */
    /* Mic section (CDJ3000 parity C5 — the DJM mic strip). */
    float mic_eq_low, mic_eq_high;   /* dB, 2-band mic EQ, 0 == flat */
    float mic_talkover_on;           /* 0/1 auto-duck the music when the mic is live */
    float mic_talkover_depth_db;     /* attenuation applied to the music, e.g. -14 */
    float mic_talkover_threshold;    /* mic block-RMS above which talkover engages, ~0.02 */
    float mic_fx_on;                 /* 0/1 route the mic through the Beat FX (all/master assign) */
    float cue_master_mix;    /* 0..1 (headphone blend) */
    float master_cue;        /* 0/1 */
    float headphone_level;   /* 0..1 */
    float cue_pfl[PE_MAX_DECKS];        /* per-channel pre-listen 0/1 */
    float xfade_assign[PE_MAX_DECKS];   /* 0=A side, 1=B side, 2=thru */
    float fader_start[PE_MAX_DECKS];    /* 0/1 */
    /* per channel [0..PE_MAX_DECKS-1]; 0/1 are the classic A/B */
    float trim[PE_MAX_DECKS];
    float eq_low[PE_MAX_DECKS], eq_mid[PE_MAX_DECKS], eq_high[PE_MAX_DECKS]; /* dB, -INFINITY == kill */
    float color_amount[PE_MAX_DECKS];   /* -1..+1 */
    float color_kind[PE_MAX_DECKS];     /* Color FX enum value */
    float beatfx_kind;       /* Beat FX enum value (0..19) */
    float beatfx_beats;      /* beat division, expressed in quarter notes */
    float beatfx_depth;      /* 0..1 wet amount */
    float beatfx_assign;     /* 0=A, 1=B, 2=both, 3=master */
    float beatfx_on;         /* 0/1 */
    float beatfx_xpad;       /* 0..1 X-Pad sweep of the primary param; <0 == not touched (CDJ3000 C4) */
    float beatfx_band;       /* FX-input band limit: 0 all, 1 low, 2 mid, 3 high (CDJ3000 C4) */
    float fader[PE_MAX_DECKS];          /* 0..1 */
    float deck_time_ratio[PE_MAX_DECKS];
    float deck_pitch[PE_MAX_DECKS];     /* semitones */
    float deck_keylock[PE_MAX_DECKS];   /* 0/1 — per-deck key-lock (time-pitch) engage */
    float limiter_enabled;   /* 0/1, default 1 — 0 bypasses the master brickwall limiter */
    float cue_mode;          /* 0 off, 1 splitOutput, 2 cueInPlace, 3 multichannel (§44.2a) */
    /* Master isolator — 3-band EQ/kill on the master bus, post-fader / pre-limiter
     * (CDJ3000 parity C3 — the DJM MASTER ISOLATOR). dB, -INFINITY == kill,
     * 0 == flat (bit-transparent, the default). */
    float master_eq_low, master_eq_mid, master_eq_high;
    /* Sound Color FX (CDJ3000 C4): per-channel parameter knob + center lock. */
    float color_param[PE_MAX_DECKS];   /* 0..1 depth / resonance, default 0.5 */
    /* Master reverb send (CDJ3000 C7) — an 8-line FDN on the master bus,
     * post-isolator / pre-limiter. send 0 == fully dry (default). */
    float master_reverb_send;
    float master_reverb_size, master_reverb_decay, master_reverb_damp;
    /* Booth output (CDJ3000 parity C3 — DJM BOOTH). Independent level + 3-band
     * EQ, fed from the final master. booth_level default 0.8; EQ 0 == flat. */
    float booth_level;
    float booth_eq_low, booth_eq_mid, booth_eq_high;
} pe_control;

/* Discrete commands (SPSC ring). One struct, tagged. */
typedef enum {
    PE_CMD_PLAY, PE_CMD_PAUSE, PE_CMD_SET_CUE, PE_CMD_JUMP_CUE,
    PE_CMD_HOTCUE_SET, PE_CMD_HOTCUE_JUMP, PE_CMD_HOTCUE_DELETE,
    PE_CMD_LOOP_IN, PE_CMD_LOOP_OUT, PE_CMD_RELOOP_EXIT, PE_CMD_BEATLOOP, PE_CMD_LOOP_SCALE,
    PE_CMD_LOOP_MOVE, PE_CMD_SET_LOOP, PE_CMD_SET_LOOP_ACTIVE,
    PE_CMD_BEATJUMP, PE_CMD_SYNC, PE_CMD_SET_MASTER, PE_CMD_SET_KEYLOCK, PE_CMD_SET_SLIP,
    PE_CMD_JOG_TOUCH, PE_CMD_JOG_MOVE, PE_CMD_JOG_RELEASE, PE_CMD_SEEK,
    PE_CMD_UNSYNC, PE_CMD_STEM_ARM, PE_CMD_STEM_GAIN, PE_CMD_STEM_MUTE, PE_CMD_STEM_SOLO,
    PE_CMD_SET_REVERSE,  /* i0 = reverse on/off (CDJ3000 parity C2 — REV / Slip Reverse) */
    PE_CMD_VINYL_SPEED,  /* f0 = brake seconds, f1 = spin-up seconds (CDJ3000 Vinyl Speed Adjust) */
    PE_CMD_ECHO_SET,  /* per-deck beat echo: i0=on, f0=beats, f1=depth, i1=feedback*1000 */
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

/*
 * Integer-sample transport (Phase 6b item 6). SEEK / SET_CUE / HOTCUE_SET /
 * SET_LOOP accept sample-exact endpoints so precision survives past ~5.8 min
 * (the float32 integer limit at 48 kHz). SEEK / SET_CUE / HOTCUE_SET: i2 == 1
 * selects integer mode with i1 = sample (HOTCUE_SET keeps i0 = slot). SET_LOOP:
 * f0 == -1 selects integer mode with i0 = active, i1 = start sample,
 * i2 = end sample. The float-seconds paths are unchanged and still bit-exact
 * for the offline harness.
 */

/* Events pushed RT -> Swift (SPSC ring). */
typedef enum { PE_EVT_PLAYHEAD, PE_EVT_PEAK, PE_EVT_STATE, PE_EVT_END_OF_TRACK, PE_EVT_BUFFER_RELEASED } pe_evt_type;
typedef struct { pe_evt_type type; int32_t deck; int64_t frame; float f0, f1; } pe_event;

/*
 * Render-side telemetry atomics (Phase 6b item 2). Polled at display cadence by
 * the control side; the adapter assembles the app-facing telemetry struct.
 */
typedef struct {
    int64_t master_frame;          /* monotonic, advances by `frames` per render */
    double  master_bpm;            /* effective BPM of the master deck, 0 if none */
    double  downbeat_phase;        /* 0..1 within the master bar, 0 if no grid */
    double  deck_effective_bpm[PE_MAX_DECKS]; /* per-deck track BPM * time ratio */
    double  deck_beat_phase[PE_MAX_DECKS];    /* 0..1 within the deck beat */
    int32_t deck_synced[PE_MAX_DECKS];        /* 0/1 authoritative per-deck sync engage */
    double  render_load;           /* last block: render time / buffer period, 0..~ */
    int64_t starved_frames;        /* frames output as silence because a deck underran */
} pe_stats;
void pe_get_stats(pe_engine*, pe_stats* out);
/* Publish the master-clock inputs the control actor computes (Phase 6b item 2). */
void pe_set_master_clock(pe_engine*, int32_t master_deck /*-1 none*/, double master_bpm,
                         double downbeat_phase);
/* Publish a per-deck effective BPM + sync-engage state for telemetry. */
void pe_set_deck_sync(pe_engine*, int deck, int synced, double effective_bpm, double beat_phase);

/* deck_count is clamped to 2..PE_MAX_DECKS. */
pe_engine* pe_create(double sample_rate, int max_frames, int deck_count);
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
/* Per-deck 4-voice stems (Phase 6b item 1): voice 0=vocals 1=drums 2=bass 3=other.
 * Resident caller-owned PCM per voice; shares the deck playhead + grid. Pass
 * channels=NULL to clear one voice. pe_deck_clear_stems disarms the overlay so
 * the deck reverts bit-for-bit to its single-source reader. */
void pe_deck_set_stem_buffer(pe_engine*, int deck, int voice, const float* const* channels,
                             int channel_count, int64_t frames);
void pe_deck_clear_stems(pe_engine*, int deck);

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
/* Optional third bus: booth output — the last rendered master through the booth
 * level + booth EQ. Call once per cycle, right after pe_render, with the same
 * frame count (CDJ3000 parity C3). */
void pe_render_booth(pe_engine*, float* out_l, float* out_r, int frames);

/* Synchronous, device-free advance for deterministic tests. Identical DSP to pe_render. */
void pe_step(pe_engine*, float* out_l, float* out_r, int frames);

/*
 * Insert / send-return seam (CDJ3000 parity C3 — the DJM SEND/RETURN and an
 * "bring your own effect" hook, mirroring the BYO-codec seam). The engine calls
 * `fn(left, right, frames, ctx)` in place on the named bus, on the render thread.
 * THE CALLBACK MUST BE REALTIME-SAFE: no locks, no allocation, no syscalls,
 * bounded work. Set it once before audio starts; pass fn = NULL to remove it.
 * For a channel insert the signal is mono (left == right). For an external
 * hardware send/return loop, the app's callback does the round trip.
 */
typedef void (*pe_insert_fn)(float* left, float* right, int frames, void* ctx);
enum { PE_INSERT_CH0 = 0, PE_INSERT_CH1, PE_INSERT_CH2, PE_INSERT_CH3, PE_INSERT_MASTER, PE_INSERT_COUNT };
void pe_set_insert(pe_engine*, int point, pe_insert_fn fn, void* ctx);

/*
 * Master-bus record tap (Phase 6b item 4). While active, every rendered master
 * block is copied into a bounded ring on the render thread. The control side
 * drains it at its own cadence into the file encoder. If the control side falls
 * behind and the ring fills, the oldest frames are dropped and counted — the
 * render thread never blocks.
 */
void    pe_record_set_active(pe_engine*, int active);
int     pe_record_drain(pe_engine*, float* out_l, float* out_r, int max_frames); /* frames written */
int64_t pe_record_dropped_frames(pe_engine*);
void    pe_record_reset(pe_engine*);  /* clears the ring + drop counter (segment boundary) */

#ifdef __cplusplus
}
#endif
#endif /* PARSO_ENGINE_H */
