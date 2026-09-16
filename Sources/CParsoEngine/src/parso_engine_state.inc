namespace pe_detail {

constexpr uint32_t kCommandCapacity = 256;
constexpr uint32_t kEventCapacity = 1024;
constexpr float kPi = 3.14159265358979323846f;
constexpr float kHalfPi = kPi * 0.5f;

// Per-deck 4-voice stem overlay (Phase 6b item 1). When armed, the deck's
// source sample is the gain-weighted sum of the present voices instead of the
// single full-mix reader. Gains are one-pole smoothed so arming/muting a voice
// never clicks.
struct StemVoice {
    const float* channels[2] = {nullptr, nullptr};
    int channelCount = 0;
    int64_t frames = 0;
    bool present = false;
    bool muted = false;
    bool soloed = false;
    float gain = 1.0f;
    float smoothedGain = 1.0f;
};

struct DeckState {
    const float* channels[2] = {nullptr, nullptr};
    int channelCount = 0;
    int64_t frames = 0;
    double sampleRate = 0.0;
    double position = 0.0;
    double shadowPosition = 0.0;
    bool playing = false;
    bool slip = false;
    bool reverse = false;   // CDJ3000 parity C2 — REV / Slip Reverse
    bool jogTouched = false;
    bool jogVinylMode = false;
    double jogVelocity = 0.0;  // scratch velocity or transient pitch-bend ratio
    double jogPressure = 1.0;  // normalized platter contact pressure
    double jogAudioPosition = 0.0;
    double jogTargetPosition = 0.0;
    bool jogAudioInitialized = false;
    float smoothedFader = 1.0f;
    bool faderInitialized = false;
    // Vinyl Speed Adjust (CDJ3000 parity C2): motorLevel eases toward motorTarget
    // (0 = stopped, 1 = full speed) at brake / spin-up rates. Zero seconds == the
    // classic instant start/stop.
    float motorLevel = 1.0f;
    float motorTarget = 1.0f;
    float brakeSeconds = 0.0f;
    float spinupSeconds = 0.0f;
    // Fade-in cue (CDJ3000 parity C6): one-shot gain ramp 0->1 after a cue jump.
    float cueFadeGain = 1.0f;
    float cueFadeRate = 0.0f;
    // Stems (item 1).
    StemVoice stems[4];
    bool stemsArmed = false;
    // Per-deck beat echo (item 3): post-fader / pre-crossfader delay line.
    bool echoOn = false;
    bool echoTail = false;
    int echoTailFrames = 0;
    float echoBeats = 1.0f;
    float echoDepth = 0.5f;
    float echoFeedback = 0.4f;
    double echoBpm = 120.0;
    // Per-deck sync + effective rate published from the control side (item 2).
    bool synced = false;
    double effectiveBpm = 0.0;
    double beatPhase = 0.0;
    // Deferred grid-quantized jump (CDJ3000 parity C1b): when a jump command
    // arrives with i2 == 2 the target is stashed and applied when the deck's
    // playhead next crosses a grid line (grain in beats, default 1).
    bool pendingJump = false;
    double pendingJumpTarget = 0.0;
    double pendingJumpCountdown = 0.0;   // frames until the jump fires
    int64_t cueFrame = 0;
    bool cueSet = false;
    int64_t hotCueFrames[8] = {};
    bool hotCueSet[8] = {};
    double loopIn = 0.0;
    double loopStart = 0.0;
    double loopEnd = 0.0;
    bool loopInSet = false;
    bool loopAvailable = false;
    bool loopActive = false;
    float eqLowGain = 1.0f;
    float eqMidGain = 1.0f;
    float eqHighGain = 1.0f;
    float lowState = 0.0f;
    float highState = 0.0f;
    float colorLowState = 0.0f;
    float colorHighState = 0.0f;
    float colorDelay[24000] = {};
    uint32_t colorDelayIndex = 0;
    uint32_t colorNoiseState = 0x13579BDFu;
};

struct SamplerSlot {
    const float* channels[2] = {nullptr, nullptr};
    int channelCount = 0;
    int64_t frames = 0;
    int64_t position = 0;
    bool playing = false;
    int mode = 0;          // 0 one-shot, 1 loop, 2 gate
    float gain = 1.0f;
};

struct MicState {
    const float* channels[2] = {nullptr, nullptr};
    int channelCount = 0;
    int64_t frames = 0;
    double sampleRate = 0.0;
    double position = 0.0;
};

struct CommandQueue {
    pe_command commands[kCommandCapacity]{};
    std::atomic<uint32_t> writeIndex{0};
    std::atomic<uint32_t> readIndex{0};
};

struct EventQueue {
    pe_event events[kEventCapacity]{};
    std::atomic<uint32_t> writeIndex{0};
    std::atomic<uint32_t> readIndex{0};
};

struct ControlState {
    std::atomic<float> crossfader{0.0f};
    std::atomic<float> curve{0.0f};
    std::atomic<float> masterLevel{0.8f};
    std::atomic<float> limiterCeilingDB{-0.3f};
    std::atomic<float> micLevel{0.0f};
    std::atomic<float> micEqLow{0.0f};
    std::atomic<float> micEqHigh{0.0f};
    std::atomic<float> micTalkoverOn{0.0f};
    std::atomic<float> micTalkoverDepthDb{-14.0f};
    std::atomic<float> micTalkoverThreshold{0.02f};
    std::atomic<float> micFxOn{0.0f};
    std::atomic<float> cueMasterMix{0.5f};
    std::atomic<float> masterCue{0.0f};
    std::atomic<float> headphoneLevel{0.7f};
    std::atomic<float> cuePFL[PE_MAX_DECKS]{{0.0f}, {0.0f}, {0.0f}, {0.0f}};
    std::atomic<float> xfadeAssign[PE_MAX_DECKS]{{2.0f}, {2.0f}, {2.0f}, {2.0f}};
    std::atomic<float> faderStart[PE_MAX_DECKS]{{0.0f}, {0.0f}, {0.0f}, {0.0f}};
    std::atomic<float> eqLow[PE_MAX_DECKS]{{0.0f}, {0.0f}, {0.0f}, {0.0f}};
    std::atomic<float> eqMid[PE_MAX_DECKS]{{0.0f}, {0.0f}, {0.0f}, {0.0f}};
    std::atomic<float> eqHigh[PE_MAX_DECKS]{{0.0f}, {0.0f}, {0.0f}, {0.0f}};
    std::atomic<float> colorAmount[PE_MAX_DECKS]{{0.0f}, {0.0f}, {0.0f}, {0.0f}};
    std::atomic<float> colorKind[PE_MAX_DECKS]{{0.0f}, {0.0f}, {0.0f}, {0.0f}};
    std::atomic<float> beatFXKind{0.0f};
    std::atomic<float> beatFXBeats{0.5f};
    std::atomic<float> beatFXDepth{0.5f};
    std::atomic<float> beatFXAssign{0.0f};
    std::atomic<float> beatFXOn{0.0f};
    std::atomic<float> beatFXXpad{-1.0f};
    std::atomic<float> beatFXBand{0.0f};
    std::atomic<float> colorParam[PE_MAX_DECKS]{{0.5f}, {0.5f}, {0.5f}, {0.5f}};
    std::atomic<float> fader[PE_MAX_DECKS]{{1.0f}, {1.0f}, {1.0f}, {1.0f}};
    std::atomic<float> trim[PE_MAX_DECKS]{{0.5f}, {0.5f}, {0.5f}, {0.5f}};
    std::atomic<float> deckTimeRatio[PE_MAX_DECKS]{{1.0f}, {1.0f}, {1.0f}, {1.0f}};
    std::atomic<float> deckPitch[PE_MAX_DECKS]{{0.0f}, {0.0f}, {0.0f}, {0.0f}};
    std::atomic<float> deckKeylock[PE_MAX_DECKS]{{0.0f}, {0.0f}, {0.0f}, {0.0f}};
    std::atomic<float> limiterEnabled{1.0f};
    std::atomic<float> cueMode{0.0f};
    std::atomic<float> masterEqLow{0.0f};
    std::atomic<float> masterEqMid{0.0f};
    std::atomic<float> masterEqHigh{0.0f};
    std::atomic<float> masterReverbSend{0.0f};
    std::atomic<float> masterReverbSize{0.6f};
    std::atomic<float> masterReverbDecay{0.6f};
    std::atomic<float> masterReverbDamp{0.5f};
    std::atomic<float> masterReverbMode{0.0f};
    std::atomic<float> boothLevel{0.8f};
    std::atomic<float> boothEqLow{0.0f};
    std::atomic<float> boothEqMid{0.0f};
    std::atomic<float> boothEqHigh{0.0f};
    // Master-clock inputs (Phase 6b item 2), published from the control actor.
    std::atomic<int32_t> masterDeck{-1};
    std::atomic<double> masterBpm{0.0};
    std::atomic<double> downbeatPhase{0.0};
};

} // namespace

struct pe_engine {
    double sampleRate;
    int maxFrames;
    int deckCount = 2;
    pe_detail::DeckState decks[PE_MAX_DECKS];
    pe_detail::SamplerSlot sampler[16];
    pe_detail::MicState mic;
    pe_detail::ControlState control;
    pe_detail::CommandQueue queue;
    pe_detail::EventQueue events;
    float previousCrossfader = 0.0f;
    bool crossfaderInitialized = false;
    int beatFXKind = 0;
    int beatFXAssign = 0;
    bool beatFXOn = false;
    bool beatFXTail = false;
    int beatFXTailFrames = 0;
    float beatFXDelay[48000] = {};
    uint32_t beatFXDelayIndex = 0;
    float beatFXBandLP = 0.0f;   // FX-input band-limit filter state (CDJ3000 C4)
    float beatFXBandHP = 0.0f;
    // Real per-sample Beat FX DSP state (CDJ3000 parity C4b).
    float bfxSvfLp = 0.0f, bfxSvfBp = 0.0f;      // TPT state-variable filter
    float bfxLfoPhase = 0.0f;                     // sweep / gate / modulation LFO
    float bfxAp[6] = {};                          // up-to-6-stage allpass phaser state
    float bfxDelay2[48000] = {};                  // ping-pong / multi-tap 2nd line
    uint32_t bfxDelay2Index = 0;
    int64_t bfxSampleClock = 0;                   // monotonic per-processBeatFX sample counter
    int64_t bfxRollAnchor = -1;                   // roll capture start (clock units), -1 = re-latch
    int bfxRollLen = 0;
    float bfxRollBuf[48000] = {};                 // dedicated roll capture buffer
    float bfxSpiralPhase = 0.0f;                  // fractional read offset for pitch kinds
    float bfxBrakeRate = 1.0f;                    // vinyl-brake read rate (1 -> 0)
    float bfxBrakeOffset = 0.0f;                  // vinyl-brake read-behind, in samples
    float bfxLowCutState = 0.0f;                  // low-cut-echo feedback high-pass state
    // Compact Schroeder reverb for the Reverb / Shimmer kinds (sized for 96 kHz).
    static constexpr int kBfxCombLen = 4800;
    static constexpr int kBfxApLen = 1600;
    float bfxComb[4][kBfxCombLen] = {};
    uint32_t bfxCombIdx[4] = {};
    float bfxCombLp[4] = {};
    float bfxAllpassBuf[2][kBfxApLen] = {};
    uint32_t bfxApIdx[2] = {};
    float limiterGain = 1.0f;
    float samplerMasterGain = 0.8f;   // CDJ3000: was a hardcoded 0.8 in the mix loop
    // CParsoDSP kernels — the shared, unit-tested DSP (docs/phase6-parity.md C1).
    // Owned by the engine: created in pe_create, freed in pe_destroy. All are
    // allocation-free once constructed, so the render path stays RT-safe.
    pd_eq3* deckEq[PE_MAX_DECKS] = {nullptr, nullptr, nullptr, nullptr};
    pd_filter* deckFilter[PE_MAX_DECKS] = {nullptr, nullptr, nullptr, nullptr};
    pd_limiter* masterLimiter = nullptr;
    pd_eq3* masterEq = nullptr;   // master isolator (CDJ3000 parity C3)
    pd_eq3* boothEq = nullptr;    // booth-output EQ (CDJ3000 parity C3)
    pd_eq3* micEq = nullptr;      // 2-band mic EQ (CDJ3000 parity C5)
    pd_fdnverb* masterReverb = nullptr;  // master reverb send (CDJ3000 parity C7)
    pd_conv* masterConv = nullptr;       // master convolution reverb (CDJ3000 parity C7c)
    float talkoverGain = 1.0f;    // smoothed music-duck under talkover
    float micBlock[512] = {};     // per-block EQ'd mono mic, filled in the mic pre-pass
    int micBlockFrames = 0;
    // Insert seam (CDJ3000 parity C3). fn cleared first / set last so the RT
    // side never calls a live fn with a stale ctx.
    std::atomic<pe_insert_fn> insertFn[PE_INSERT_COUNT]{};
    std::atomic<void*> insertCtx[PE_INSERT_COUNT]{};
    // Snapshot of the last rendered master block, for pe_render_booth.
    static constexpr int kBoothCapacity = 8192;
    float boothLeft[kBoothCapacity] = {};
    float boothRight[kBoothCapacity] = {};
    int boothFrames = 0;
    // Per-deck beat-echo delay lines (Phase 6b item 3). Sized at pe_create for
    // the worst case (8 beats at 40 BPM ≈ 12 s) so the render path never allocs.
    pd_delay* deckEcho[PE_MAX_DECKS] = {nullptr, nullptr, nullptr, nullptr};
    // Per-deck time-pitch (Phase 6b item 2a) — key-lock via signalsmith-stretch.
    pd_timepitch* deckTimePitch[PE_MAX_DECKS] = {nullptr, nullptr, nullptr, nullptr};
    // Telemetry atomics (item 2).
    std::atomic<int64_t> masterFrame{0};
    std::atomic<double> renderLoad{0.0};
    std::atomic<int64_t> starvedFrames{0};
    // Master-bus record tap (item 4). ~4 s stereo ring at the engine rate.
    static constexpr uint32_t kRecordCapacity = 1u << 18;  // 262144 frames
    float recordLeft[kRecordCapacity] = {};
    float recordRight[kRecordCapacity] = {};
    std::atomic<uint32_t> recordWrite{0};
    std::atomic<uint32_t> recordRead{0};
    std::atomic<int32_t> recordActive{0};
    std::atomic<int64_t> recordDropped{0};
};
