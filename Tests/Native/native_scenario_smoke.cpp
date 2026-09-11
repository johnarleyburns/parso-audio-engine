#include "parso_engine.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

namespace {

constexpr double kSampleRate = 48000.0;
constexpr int kMaxFrames = 512;
constexpr int kFrames = 48000;
constexpr double kPi = 3.14159265358979323846;

struct Rendered {
    std::vector<float> left;
    std::vector<float> right;
};

bool require(bool condition, const char *message) {
    if (!condition) std::fprintf(stderr, "native_scenario_smoke: %s\n", message);
    return condition;
}

pe_control baseControl() {
    pe_control control{};
    control.master_level = 0.8f;
    control.limiter_enabled = 0.0f;
    control.xfade_assign[0] = 2.0f;
    control.fader[0] = 1.0f;
    control.trim[0] = 1.0f;
    control.beatfx_assign = 3.0f;
    control.beatfx_beats = 0.5f;
    control.beatfx_depth = 0.7f;
    control.color_param[0] = 0.5f;
    control.master_reverb_size = 0.6f;
    control.master_reverb_decay = 0.6f;
    control.master_reverb_damp = 0.5f;
    return control;
}

Rendered render(const std::vector<float> &source, pe_isolator_profile profile,
                const pe_control &control, const std::vector<pe_command> &commands = {}) {
    const float *channels[] = {source.data(), source.data()};
    pe_engine *engine = pe_create_with_isolator_profile(
        kSampleRate, kMaxFrames, 2, profile);
    if (!engine) return {};
    pe_deck_set_buffer(engine, 0, channels, 2, kFrames, kSampleRate);
    pe_set_control(engine, &control);

    pe_command play{};
    play.type = PE_CMD_PLAY;
    play.deck = 0;
    if (!pe_post_command(engine, &play)) {
        pe_destroy(engine);
        return {};
    }
    for (const pe_command &command : commands) {
        if (!pe_post_command(engine, &command)) {
            pe_destroy(engine);
            return {};
        }
    }

    Rendered output{std::vector<float>(kFrames), std::vector<float>(kFrames)};
    for (int offset = 0; offset < kFrames; offset += kMaxFrames) {
        pe_step(engine, output.left.data() + offset, output.right.data() + offset,
                std::min(kMaxFrames, kFrames - offset));
    }
    pe_destroy(engine);
    return output;
}

float rms(const std::vector<float> &samples, int first) {
    double sum = 0.0;
    for (int index = first; index < static_cast<int>(samples.size()); ++index) {
        sum += static_cast<double>(samples[index]) * samples[index];
    }
    return static_cast<float>(std::sqrt(sum / static_cast<double>(samples.size() - first)));
}

float difference(const Rendered &a, const Rendered &b) {
    float maximum = 0.0f;
    for (std::size_t index = 0; index < a.left.size(); ++index) {
        maximum = std::max(maximum, std::fabs(a.left[index] - b.left[index]));
        maximum = std::max(maximum, std::fabs(a.right[index] - b.right[index]));
    }
    return maximum;
}

std::vector<float> tone(double frequency) {
    std::vector<float> samples(kFrames);
    for (int index = 0; index < kFrames; ++index) {
        samples[index] = static_cast<float>(0.2 * std::sin(
            2.0 * kPi * frequency * static_cast<double>(index) / kSampleRate));
    }
    return samples;
}

bool finiteAndAudible(const Rendered &rendered) {
    bool audible = false;
    for (std::size_t index = 0; index < rendered.left.size(); ++index) {
        if (!std::isfinite(rendered.left[index]) || !std::isfinite(rendered.right[index])) {
            return false;
        }
        audible = audible || std::fabs(rendered.left[index]) > 1.0e-5f ||
                  std::fabs(rendered.right[index]) > 1.0e-5f;
    }
    return audible;
}

} // namespace

int main() {
    const pe_control flat = baseControl();
    const Rendered flatLow = render(tone(100.0), PE_ISOLATOR_PROFILE_WARM2, flat);
    const Rendered flatMid = render(tone(1000.0), PE_ISOLATOR_PROFILE_WARM2, flat);
    const Rendered flatHigh = render(tone(8000.0), PE_ISOLATOR_PROFILE_WARM2, flat);

    pe_control lowCut = flat;
    lowCut.master_eq_low = -70.0f;
    pe_control midCut = flat;
    midCut.master_eq_mid = -40.0f;
    pe_control highCut = flat;
    highCut.master_eq_high = -70.0f;
    const bool warm2 =
        require(rms(render(tone(100.0), PE_ISOLATOR_PROFILE_WARM2, lowCut).left, kFrames / 2) <
                    rms(flatLow.left, kFrames / 2) * 0.2f,
                "WARM2 bass kill did not isolate the low band") &&
        require(rms(render(tone(1000.0), PE_ISOLATOR_PROFILE_WARM2, midCut).left, kFrames / 2) <
                    rms(flatMid.left, kFrames / 2) * 0.2f,
                "WARM2 mid kill did not isolate the mid band") &&
        require(rms(render(tone(8000.0), PE_ISOLATOR_PROFILE_WARM2, highCut).left, kFrames / 2) <
                    rms(flatHigh.left, kFrames / 2) * 0.2f,
                "WARM2 treble kill did not isolate the high band");

    const std::vector<float> source = tone(440.0);
    pe_control color = flat;
    color.color_kind[0] = 2.0f;
    color.color_amount[0] = 0.8f;
    color.color_param[0] = 0.8f;
    pe_control beatFx = flat;
    beatFx.beatfx_kind = 1.0f;
    beatFx.beatfx_on = 1.0f;
    pe_control reverb = flat;
    reverb.master_reverb_send = 0.8f;
    pe_control transition = flat;
    transition.xfade_assign[0] = 2.0f;
    transition.master_eq_low = -12.0f;
    transition.deck_time_ratio[0] = 1.04f;

    pe_command setCue{};
    setCue.type = PE_CMD_SET_CUE;
    setCue.deck = 0;
    setCue.f0 = 0.1f;
    pe_command loop{};
    loop.type = PE_CMD_BEATLOOP;
    loop.deck = 0;
    loop.f0 = 4.0f;
    pe_command scratchTouch{};
    scratchTouch.type = PE_CMD_JOG_TOUCH;
    scratchTouch.deck = 0;
    scratchTouch.i0 = 1;
    scratchTouch.i1 = 1;
    pe_command scratchMove{};
    scratchMove.type = PE_CMD_JOG_MOVE;
    scratchMove.deck = 0;
    scratchMove.f0 = -18000.0f;
    pe_command scratchRelease{};
    scratchRelease.type = PE_CMD_JOG_RELEASE;
    scratchRelease.deck = 0;
    scratchRelease.i0 = 1;
    scratchRelease.i1 = 1;

    const Rendered base = render(source, PE_ISOLATOR_PROFILE_GENERIC, flat);
    const bool scenarios =
        require(finiteAndAudible(base), "flat native scenario was silent or non-finite") &&
        require(difference(base, render(source, PE_ISOLATOR_PROFILE_GENERIC, color)) > 1.0e-4f,
                "Color FX control was not rendered") &&
        require(difference(base, render(source, PE_ISOLATOR_PROFILE_GENERIC, beatFx)) > 1.0e-4f,
                "Beat FX control was not rendered") &&
        require(difference(base, render(source, PE_ISOLATOR_PROFILE_GENERIC, reverb)) > 1.0e-4f,
                "master reverb control was not rendered") &&
        require(difference(base, render(source, PE_ISOLATOR_PROFILE_GENERIC, transition)) > 1.0e-4f,
                "automated transition controls were not rendered") &&
        require(finiteAndAudible(render(source, PE_ISOLATOR_PROFILE_GENERIC, flat,
                                        {setCue, loop, scratchTouch, scratchMove, scratchRelease})),
                "loop/cue/scratch commands did not render a finite audible result");

    return (warm2 && scenarios) ? 0 : 1;
}
