static void crossfadeGains(float crossfader, float curve, float& gainA, float& gainB) {
    const float x = crossfader < -1.0f ? -1.0f : (crossfader > 1.0f ? 1.0f : crossfader);
    const float normalized = (x + 1.0f) * 0.5f;
    if (curve < 0.25f) {
        const float angle = normalized * kHalfPi;
        gainA = std::cos(angle);
        gainB = std::sin(angle);
    } else if (curve < 0.75f) {
        gainA = 1.0f - normalized;
        gainB = normalized;
    } else {
        // "Sharp" must be steep, not a literal zero-width step: gains are
        // computed once per render() call (block-rate, like every other
        // mixer parameter here), so a true Heaviside step here means the
        // output jump-cuts full-amplitude between two unrelated songs at
        // whatever sample lands on the boundary -- an audible click/gap on
        // real material, found via the Phase 6d A-B listening pass (see
        // current_status.md "Phase 6"). Real hardware "sharp" crossfader
        // curves are steep, not instantaneous, either. A narrow linear ramp
        // around centre keeps the cut feel while staying continuous.
        constexpr float halfWidth = 0.02f; // ~1% of full throw each side of centre
        if (normalized < 0.5f - halfWidth) {
            gainA = 1.0f;
            gainB = 0.0f;
        } else if (normalized > 0.5f + halfWidth) {
            gainA = 0.0f;
            gainB = 1.0f;
        } else {
            const float t = (normalized - (0.5f - halfWidth)) / (2.0f * halfWidth);
            gainA = 1.0f - t;
            gainB = t;
        }
    }
}

// --- Beat FX per-sample DSP primitives (CDJ3000 parity C4b) ---

// One TPT (topology-preserving transform) state-variable filter step. Returns
// the low-pass output; band-pass is kept in state for resonant sweeps.
static float bfxSvfLowpass(pe_engine* e, float in, float cutoffHz, float res) {
    const float sr = static_cast<float>(e->sampleRate);
    const float g = std::tan(kPi * std::min(cutoffHz, sr * 0.45f) / sr);
    const float k = 2.0f - 1.9f * std::min(1.0f, std::max(0.0f, res));   // damping
    const float a1 = 1.0f / (1.0f + g * (g + k));
    const float a2 = g * a1;
    const float v1 = a1 * e->bfxSvfBp + a2 * (in - e->bfxSvfLp);
    const float v2 = e->bfxSvfLp + g * v1;
    e->bfxSvfBp = 2.0f * v1 - e->bfxSvfBp;
    e->bfxSvfLp = 2.0f * v2 - e->bfxSvfLp;
    if (!std::isfinite(e->bfxSvfLp)) { e->bfxSvfLp = e->bfxSvfBp = 0.0f; }
    return e->bfxSvfLp;
}

// N-stage allpass phaser with a shared, LFO-swept coefficient + feedback.
static float bfxPhaser(pe_engine* e, float in, int stages, float coef, float feedback) {
    float x = in + e->bfxAp[std::min(stages, 6) - 1] * feedback;
    for (int s = 0; s < std::min(stages, 6); ++s) {
        const float y = -coef * x + e->bfxAp[s];
        e->bfxAp[s] = x + coef * y;
        x = y;
    }
    return x;
}

// Compact Schroeder reverb (4 damped combs in parallel -> 2 allpass in series).
static float bfxSchroeder(pe_engine* e, float in, float size, float damp, float octaveMix) {
    static constexpr int combLen[4] = {1687, 1601, 2053, 2251};
    static constexpr int apLen[2]   = {389, 307};
    const double scale = e->sampleRate / 48000.0;
    const float fb = 0.72f + 0.26f * std::min(1.0f, std::max(0.0f, size));
    const float dc = 0.15f + 0.8f * std::min(1.0f, std::max(0.0f, damp));
    const int CL = pe_engine::kBfxCombLen;
    const int AL = pe_engine::kBfxApLen;
    float combSum = 0.0f;
    for (int c = 0; c < 4; ++c) {
        int len = std::max(1, std::min(CL - 1, static_cast<int>(combLen[c] * scale)));
        uint32_t& idx = e->bfxCombIdx[c];
        const uint32_t readIdx = (idx + static_cast<uint32_t>(CL) - static_cast<uint32_t>(len)) % static_cast<uint32_t>(CL);
        float out = e->bfxComb[c][readIdx];
        if (octaveMix > 0.0f) {
            const uint32_t up = (readIdx + static_cast<uint32_t>(len / 2)) % static_cast<uint32_t>(CL);
            out += e->bfxComb[c][up] * octaveMix;
        }
        e->bfxCombLp[c] += dc * (out - e->bfxCombLp[c]);
        e->bfxComb[c][idx] = in + e->bfxCombLp[c] * fb;
        idx = (idx + 1) % static_cast<uint32_t>(CL);
        combSum += out;
    }
    float x = combSum * 0.25f;
    for (int p = 0; p < 2; ++p) {
        int len = std::max(1, std::min(AL - 1, static_cast<int>(apLen[p] * scale)));
        uint32_t& idx = e->bfxApIdx[p];
        const uint32_t readIdx = (idx + static_cast<uint32_t>(AL) - static_cast<uint32_t>(len)) % static_cast<uint32_t>(AL);
        const float buffered = e->bfxAllpassBuf[p][readIdx];
        const float y = -0.5f * x + buffered;
        e->bfxAllpassBuf[p][idx] = x + 0.5f * y;
        idx = (idx + 1) % static_cast<uint32_t>(AL);
        x = y;
    }
    return std::isfinite(x) ? x : 0.0f;
}

static float processBeatFX(pe_engine* engine, float input) {
    const bool active = engine->beatFXOn || engine->beatFXTail;
    if (!active) return input;

    // FX-input band limit (CDJ3000 C4): 0 all, 1 low, 2 mid, 3 high. One-pole
    // shelves at ~250 Hz / ~2 kHz on the FX send only — the dry path is untouched.
    const int band = std::max(0, std::min(3, static_cast<int>(std::lround(
        engine->control.beatFXBand.load(std::memory_order_relaxed)))));
    float fxIn = input;
    if (band != 0) {
        const float sr = static_cast<float>(engine->sampleRate);
        const float aLo = 1.0f - std::exp(-2.0f * kPi * 250.0f / sr);
        const float aHi = 1.0f - std::exp(-2.0f * kPi * 2000.0f / sr);
        engine->beatFXBandLP += aLo * (input - engine->beatFXBandLP);
        engine->beatFXBandHP += aHi * (input - engine->beatFXBandHP);
        if (band == 1) fxIn = engine->beatFXBandLP;                       // low
        else if (band == 3) fxIn = input - engine->beatFXBandHP;         // high
        else fxIn = engine->beatFXBandHP - engine->beatFXBandLP;         // mid
    }

    const float sr = static_cast<float>(engine->sampleRate);
    const float rawBeats = engine->control.beatFXBeats.load(std::memory_order_relaxed);
    float beats = std::isfinite(rawBeats) ? std::max(0.0625f, std::min(8.0f, rawBeats)) : 0.5f;
    // X-Pad (CDJ3000 C4): sweeps the beat division exponentially 1/16..4.
    const float xpad = engine->control.beatFXXpad.load(std::memory_order_relaxed);
    if (xpad >= 0.0f) beats = std::pow(2.0f, -4.0f + std::min(1.0f, xpad) * 6.0f);

    const int kind = engine->beatFXKind;
    const double bpm = engine->control.masterBpm.load(std::memory_order_relaxed) > 20.0
        ? engine->control.masterBpm.load(std::memory_order_relaxed) : 120.0;
    const float beatFrames = static_cast<float>(sr * 60.0 / bpm);
    // LFO advance: one cycle per `beats` (triplet kinds run 1.5x faster).
    const bool triplet = (kind == 16 || kind == 17);
    const float lfoInc = (triplet ? 1.5f : 1.0f) / std::max(1.0f, beatFrames * beats);
    engine->bfxLfoPhase += lfoInc;
    if (engine->bfxLfoPhase >= 1.0f) engine->bfxLfoPhase -= 1.0f;
    const float lfo = engine->bfxLfoPhase;
    const float lfoSin = 0.5f + 0.5f * std::sin(6.2831853f * lfo);

    int delaySamples = std::max(1, std::min(47999, static_cast<int>(sr * beats * 0.5f)));
    if (kind == 5 || kind == 6 || kind == 18) delaySamples = std::max(1, static_cast<int>(sr * 0.004f));
    if (triplet) delaySamples = std::max(1, delaySamples * 2 / 3);

    const uint32_t index = engine->beatFXDelayIndex;
    const uint32_t delayedIndex = (index + 48000u - static_cast<uint32_t>(delaySamples)) % 48000u;
    const float delayed = engine->beatFXDelay[delayedIndex];
    const float rawDepth = engine->control.beatFXDepth.load(std::memory_order_relaxed);
    const float depth = std::isfinite(rawDepth) ? std::max(0.0f, std::min(1.0f, rawDepth)) : 0.5f;

    float wet;
    float feed = fxIn;          // what gets written into the primary delay line
    float feedback = 0.55f;

    switch (kind) {
        case 2:   // Reverb — compact Schroeder.
        case 19: {// Shimmer — Schroeder + octave-up feedback.
            wet = bfxSchroeder(engine, fxIn, 0.6f + 0.35f * depth, 0.4f,
                               kind == 19 ? 0.5f : 0.0f);
            feed = 0.0f; feedback = 0.0f;   // reverb keeps its own buffers
            break;
        }
        case 5: {  // Flanger — LFO-modulated 1..5 ms delay + feedback.
            const int mod = static_cast<int>(sr * (0.001f + 0.004f * lfoSin));
            const uint32_t mi = (index + 48000u - static_cast<uint32_t>(std::max(1, mod))) % 48000u;
            wet = engine->beatFXDelay[mi];
            feed = fxIn + wet * 0.6f; feedback = 0.0f;
            break;
        }
        case 6:    // Phaser — 4-stage allpass, LFO-swept.
            wet = bfxPhaser(engine, fxIn, 4, -0.2f + 0.7f * lfoSin, 0.5f);
            feed = 0.0f; feedback = 0.0f;
            break;
        case 18:   // Enigma — deeper 6-stage phaser, more resonance + feedback.
            wet = bfxPhaser(engine, fxIn, 6, -0.1f + 0.85f * lfoSin, 0.72f);
            feed = 0.0f; feedback = 0.0f;
            break;
        case 7: {  // Trans — hard amplitude gate (50% duty square at the beat rate).
            const float gate = lfo < 0.5f ? 1.0f : 0.06f;
            wet = fxIn * gate; feed = 0.0f; feedback = 0.0f;
            break;
        }
        case 8:    // Roll
        case 17: { // Triplet Roll — capture one division into a dedicated buffer,
                   // then loop it. Fresh audio passes through during capture.
            const int rollLen = std::max(1, std::min(47999, delaySamples));
            if (engine->bfxRollAnchor < 0 || engine->bfxRollLen != rollLen) {
                engine->bfxRollAnchor = engine->bfxSampleClock;
                engine->bfxRollLen = rollLen;
            }
            const int64_t age = engine->bfxSampleClock - engine->bfxRollAnchor;
            if (age < rollLen) {
                engine->bfxRollBuf[age] = fxIn;   // still capturing
                wet = fxIn;
            } else {
                wet = engine->bfxRollBuf[age % rollLen];   // loop the captured bar
            }
            feed = fxIn; feedback = 0.0f;
            break;
        }
        case 16: { // Triplet Filter — resonant LP swept by the triplet LFO.
            const float cutoff = 150.0f * std::pow(60.0f, lfoSin);   // ~150 Hz..9 kHz
            wet = bfxSvfLowpass(engine, fxIn, cutoff, 0.85f);
            feed = 0.0f; feedback = 0.0f;
            break;
        }
        case 9:    // Spiral
        case 10:   // Pitch
        case 13:   // Helix
        case 15: { // Mobius — pitched feedback via a drifting fractional read.
            const float rate = (kind == 10) ? 1.06f
                             : (kind == 15) ? (1.0f + 0.04f * std::sin(6.2831853f * lfo))
                             : 1.03f;   // spiral / helix rise
            engine->bfxSpiralPhase += (rate - 1.0f);
            if (engine->bfxSpiralPhase > static_cast<float>(delaySamples)) engine->bfxSpiralPhase -= static_cast<float>(delaySamples);
            const float readPos = static_cast<float>(delaySamples) + engine->bfxSpiralPhase;
            const int r0 = static_cast<int>(readPos);
            const float frac = readPos - static_cast<float>(r0);
            const uint32_t i0 = (index + 96000u - static_cast<uint32_t>(r0)) % 48000u;
            const uint32_t i1 = (i0 + 47999u) % 48000u;
            wet = engine->beatFXDelay[i0] * (1.0f - frac) + engine->beatFXDelay[i1] * frac;
            feed = fxIn + wet * (kind == 13 ? 0.85f : 0.7f);  // helix sustains
            feedback = 0.0f;
            break;
        }
        case 14: { // Ping Pong — two cross-fed delay lines (folded to mono).
            const uint32_t j = engine->bfxDelay2Index;
            const uint32_t d2 = static_cast<uint32_t>(std::max(1, delaySamples * 3 / 2));
            const float tapA = delayed;
            const float tapB = engine->bfxDelay2[(j + 48000u - d2) % 48000u];
            engine->beatFXDelay[index] = fxIn + tapB * 0.62f;
            engine->bfxDelay2[j] = tapA * 0.62f;
            engine->bfxDelay2Index = (j + 1) % 48000u;
            engine->beatFXDelayIndex = (index + 1) % 48000u;
            const float out = input * (1.0f - depth) + (tapA + tapB) * depth;
            if (engine->beatFXTail) {
                engine->beatFXTailFrames -= 1;
                if (engine->beatFXTailFrames <= 0) engine->beatFXTail = false;
            }
            return out;
        }
        case 12: { // Vinyl Brake — decelerating variable-rate read of the live
            // history buffer: the read rate falls 1 -> 0 over ~0.8 s, so the
            // read point drops behind the write head and the pitch bends down.
            engine->bfxBrakeRate = std::max(0.0f, engine->bfxBrakeRate - 1.0f / (sr * 0.8f));
            engine->bfxBrakeOffset = std::min(46000.0f,
                engine->bfxBrakeOffset + (1.0f - engine->bfxBrakeRate));
            const float rp = engine->bfxBrakeOffset;
            const int r0 = static_cast<int>(rp);
            const float frac = rp - static_cast<float>(r0);
            const uint32_t i0 = (index + 96000u - static_cast<uint32_t>(r0 + 1)) % 48000u;
            const uint32_t i1 = (i0 + 47999u) % 48000u;
            wet = (engine->beatFXDelay[i0] * (1.0f - frac) + engine->beatFXDelay[i1] * frac)
                  * engine->bfxBrakeRate;
            feed = fxIn; feedback = 0.0f;
            break;
        }
        case 11:   // Low-Cut Echo — echo whose feedback path is high-passed
                   // (~120 Hz), so repeats thin out instead of building mud.
            wet = delayed;
            engine->bfxLowCutState += (1.0f - std::exp(-2.0f * kPi * 120.0f / sr))
                                      * (delayed - engine->bfxLowCutState);
            feed = fxIn + (delayed - engine->bfxLowCutState) * 0.62f;
            feedback = 0.0f;
            break;
        case 4: {  // Multi-Tap Delay — three taps.
            const uint32_t t2 = (index + 48000u - static_cast<uint32_t>(delaySamples * 2 / 3)) % 48000u;
            const uint32_t t3 = (index + 48000u - static_cast<uint32_t>(delaySamples / 3)) % 48000u;
            wet = delayed + engine->beatFXDelay[t2] * 0.6f + engine->beatFXDelay[t3] * 0.35f;
            feed = fxIn + delayed * 0.45f; feedback = 0.0f;
            break;
        }
        default:   // echo (0), echo out (1), delay (3) — clean feedback delay.
            wet = delayed;
            feed = fxIn; feedback = (kind == 1) ? 0.6f : 0.45f;
            break;
    }

    if (kind != 14) {
        engine->beatFXDelay[index] = feed + wet * feedback;
        engine->beatFXDelayIndex = (index + 1) % 48000u;
    }
    ++engine->bfxSampleClock;
    const float output = input * (1.0f - depth) + wet * depth;
    if (engine->beatFXTail) {
        if (engine->beatFXTailFrames > 0) --engine->beatFXTailFrames;
        if (engine->beatFXTailFrames == 0) engine->beatFXTail = false;
    }
    return std::isfinite(output) ? output : input;
}

// The render pipeline runs in fixed-size blocks so the CParsoDSP kernels
// (block-oriented) get a bounded, stack-resident scratch. 512 frames keeps the
// scratch at 8 KB and matches the engine's typical device period.
constexpr int kRenderBlock = 512;

// App-supplied insert on a bus (CDJ3000 parity C3). RT-thread call; the app
// guarantees the callback is RT-safe. fn is loaded before ctx and cleared
// first by pe_set_insert, so a live fn never sees a stale ctx.
static void applyInsert(pe_engine* engine, int point, float* l, float* r, int frames) {
    pe_insert_fn fn = engine->insertFn[point].load(std::memory_order_acquire);
    if (!fn) return;
    void* ctx = engine->insertCtx[point].load(std::memory_order_relaxed);
    fn(l, r ? r : l, frames, ctx);
}

// One block of the deck→EQ→ColorFX→crossfader→mic/sampler→beatFX→master→limiter
// chain. `frames` is already clamped to kRenderBlock. `deckPeaks`/`masterPeak`
// accumulate across blocks. Transport (position, loops, end-of-track) advances
// here, one source frame per output frame scaled by the deck's tempo ratio.
