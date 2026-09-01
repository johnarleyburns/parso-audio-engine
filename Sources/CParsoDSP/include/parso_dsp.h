/*
 * parso_dsp.h — C-clean public API for the real-time DSP kernels.
 * IMPLEMENTATION is C++17 (source files) but this header MUST stay C-compatible
 * so Swift/Clang can import it. No classes/templates/namespaces here.
 * All processing is allocation-free and RT-safe (see docs/SPEC.md §7).
 */
#ifndef PARSO_DSP_H
#define PARSO_DSP_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef int pd_status;            /* 0 == PD_OK, negative == error */
#define PD_OK 0
#define PD_ERR_UNIMPLEMENTED (-1)
#define PD_ERR_PARAM        (-2)

/* ---- 3-band full-kill isolator EQ ---- */
typedef struct pd_eq3 pd_eq3;
pd_eq3*   pd_eq3_create(double sample_rate, double xover_lo_hz, double xover_hi_hz);
void      pd_eq3_set(pd_eq3*, float low_db, float mid_db, float high_db); /* -INFINITY == kill */
void      pd_eq3_process(pd_eq3*, const float* in, float* out, int frames);
void      pd_eq3_destroy(pd_eq3*);

/* ---- Resonant filter (Color-FX default: LPF<->HPF sweep) ---- */
typedef struct pd_filter pd_filter;
pd_filter* pd_filter_create(double sample_rate);
void       pd_filter_set(pd_filter*, float knob /*-1..+1*/, float resonance /*0..1*/);
void       pd_filter_process(pd_filter*, const float* in, float* out, int frames);
void       pd_filter_destroy(pd_filter*);

/* ---- Time-pitch: varispeed (coupled) + key-lock (Signalsmith) ---- */
typedef enum { PD_TP_VARISPEED = 0, PD_TP_KEYLOCK = 1 } pd_tp_mode;
typedef struct pd_timepitch pd_timepitch;
pd_timepitch* pd_tp_create(double sr, int channels, int max_block);
void pd_tp_set_mode(pd_timepitch*, pd_tp_mode);
void pd_tp_set_time_ratio(pd_timepitch*, double ratio);      /* 0.06..2.0 (tempo) */
void pd_tp_set_pitch_semitones(pd_timepitch*, double semis); /* -12..+12 */
void pd_tp_reset(pd_timepitch*);                             /* on seek / hot-cue */
int  pd_tp_process(pd_timepitch*, const float* const* in, int in_frames,
                   float* const* out, int out_frames);       /* returns frames written */
void pd_tp_destroy(pd_timepitch*);

/* ---- Effects (delay/echo, reverb, flanger, phaser, bitcrush, limiter) ---- */
typedef struct pd_delay   pd_delay;
pd_delay* pd_delay_create(double sr, double max_seconds);
void      pd_delay_set(pd_delay*, double time_seconds, float feedback /*0..0.95*/, float mix);
void      pd_delay_process(pd_delay*, const float* in, float* out, int frames);
void      pd_delay_destroy(pd_delay*);

typedef struct pd_reverb pd_reverb;                 /* Freeverb topology, see docs/SPEC.md §13.4 */
pd_reverb* pd_reverb_create(double sr);
void       pd_reverb_set(pd_reverb*, float room /*0..1*/, float damp /*0..1*/, float width, float mix);
void       pd_reverb_process(pd_reverb*, const float* in_l, const float* in_r,
                             float* out_l, float* out_r, int frames);
void       pd_reverb_destroy(pd_reverb*);

typedef struct pd_limiter pd_limiter;
pd_limiter* pd_limiter_create(double sr, float ceiling_db /*~ -0.3*/);
void        pd_limiter_process(pd_limiter*, float* l, float* r, int frames);
void        pd_limiter_destroy(pd_limiter*);

/* ---- Lock-free SPSC ring (POD payload) used by the engine ---- */
typedef struct pd_ring pd_ring;
pd_ring* pd_ring_create(size_t element_size, size_t capacity_pow2);
int      pd_ring_push(pd_ring*, const void* element); /* 1 ok, 0 full */
int      pd_ring_pop(pd_ring*, void* out_element);    /* 1 ok, 0 empty */
void     pd_ring_destroy(pd_ring*);

/* Enable flush-to-zero / denormals-are-zero for the current thread. */
void pd_enable_ftz(void);

#ifdef __cplusplus
}
#endif
#endif /* PARSO_DSP_H */
