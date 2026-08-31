// Stub bodies. Replace with the real RT DJ graph per docs/SPEC.md §8.3, §11, §12.
// MUST remain allocation-free inside pe_render/pe_step once implemented.
#include "parso_engine.h"
#include <string.h>

extern "C" {
pe_engine* pe_create(double, int) { return nullptr; }
void pe_destroy(pe_engine*) {}
void pe_set_control(pe_engine*, const pe_control*) {}
int  pe_post_command(pe_engine*, const pe_command*) { return 1; }
int  pe_poll_events(pe_engine*, pe_event*, int) { return 0; }
void pe_deck_set_buffer(pe_engine*, int, const float* const*, int, int64_t, double) {}
void pe_sampler_set_slot(pe_engine*, int, const float* const*, int, int64_t) {}
void pe_render(pe_engine*, float* l, float* r, int n) { if(l) memset(l,0,sizeof(float)*n); if(r) memset(r,0,sizeof(float)*n); }
void pe_render_monitor(pe_engine*, float* l, float* r, int n) { if(l) memset(l,0,sizeof(float)*n); if(r) memset(r,0,sizeof(float)*n); }
void pe_step(pe_engine* e, float* l, float* r, int n) { pe_render(e,l,r,n); }
} // extern "C"
