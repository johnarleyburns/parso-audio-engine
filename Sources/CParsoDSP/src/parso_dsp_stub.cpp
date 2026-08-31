// Stub bodies so the target links before the DSP is implemented.
// Replace each with a real, allocation-free implementation per docs/SPEC.md §13.
// (When implementing, include the vendored Signalsmith header for pd_timepitch key-lock.)
#include "parso_dsp.h"

extern "C" {
pd_eq3* pd_eq3_create(double, double, double) { return nullptr; }
void pd_eq3_set(pd_eq3*, float, float, float) {}
void pd_eq3_process(pd_eq3*, const float* in, float* out, int frames) { for (int i=0;i<frames;++i) out[i]=in?in[i]:0.f; }
void pd_eq3_destroy(pd_eq3*) {}

pd_filter* pd_filter_create(double) { return nullptr; }
void pd_filter_set(pd_filter*, float, float) {}
void pd_filter_process(pd_filter*, const float* in, float* out, int frames) { for (int i=0;i<frames;++i) out[i]=in?in[i]:0.f; }
void pd_filter_destroy(pd_filter*) {}

pd_timepitch* pd_tp_create(double, int, int) { return nullptr; }
void pd_tp_set_mode(pd_timepitch*, pd_tp_mode) {}
void pd_tp_set_time_ratio(pd_timepitch*, double) {}
void pd_tp_set_pitch_semitones(pd_timepitch*, double) {}
void pd_tp_reset(pd_timepitch*) {}
int  pd_tp_process(pd_timepitch*, const float* const*, int, float* const*, int out_frames) { return out_frames; }
void pd_tp_destroy(pd_timepitch*) {}

pd_delay* pd_delay_create(double, double) { return nullptr; }
void pd_delay_set(pd_delay*, double, float, float) {}
void pd_delay_process(pd_delay*, const float* in, float* out, int frames) { for (int i=0;i<frames;++i) out[i]=in?in[i]:0.f; }
void pd_delay_destroy(pd_delay*) {}

pd_reverb* pd_reverb_create(double) { return nullptr; }
void pd_reverb_set(pd_reverb*, float, float, float, float) {}
void pd_reverb_process(pd_reverb*, const float* il, const float* ir, float* ol, float* or_, int n) { for(int i=0;i<n;++i){ol[i]=il?il[i]:0.f;or_[i]=ir?ir[i]:0.f;} }
void pd_reverb_destroy(pd_reverb*) {}

pd_limiter* pd_limiter_create(double, float) { return nullptr; }
void pd_limiter_process(pd_limiter*, float*, float*, int) {}
void pd_limiter_destroy(pd_limiter*) {}

pd_ring* pd_ring_create(size_t, size_t) { return nullptr; }
int  pd_ring_push(pd_ring*, const void*) { return 0; }
int  pd_ring_pop(pd_ring*, void*) { return 0; }
void pd_ring_destroy(pd_ring*) {}

void pd_enable_ftz(void) {}
} // extern "C"
