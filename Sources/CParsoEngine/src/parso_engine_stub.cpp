// CParsoEngine's allocation-free two-deck render core.
// Control-side setup may allocate the handle; pe_render/pe_step only consume
// resident caller-owned PCM and fixed-size command/control state.
#include "parso_engine.h"
#include "parso_dsp.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <new>

#include "parso_engine_state.inc"
using namespace pe_detail;
#include "parso_engine_core.inc"
#include "parso_engine_commands.inc"
#include "parso_engine_effects.inc"
#include "parso_engine_render_a.inc"
#include "parso_engine_render_b.inc"
#include "parso_engine_api_lifecycle.inc"
#include "parso_engine_api_commands.inc"
#include "parso_engine_api_stats.inc"
