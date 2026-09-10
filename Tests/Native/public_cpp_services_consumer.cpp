#include "parso.hpp"

#include <cmath>
#include <cstdint>
#include <cstdio>

int main() {
    constexpr uint32_t frames = 48000;
    float samples[frames]{};
    for (uint32_t index = 0; index < frames; ++index) {
        samples[index] = 0.25f * std::sin(static_cast<float>(index) * 0.03f);
    }

    parso_capabilities_t capabilities{};
    parso_pcm_buffer_t input{};
    parso::PcmBuffer converted;
    parso_src_options_t srcOptions{};
    parso_loudness_options_t loudnessOptions{};
    parso_loudness_result_t loudness{};
    if (parso_capabilities_init(&capabilities) != PARSO_STATUS_OK ||
        parso_capabilities_get(&capabilities) != PARSO_STATUS_OK ||
        (capabilities.offline_services & PARSO_OFFLINE_SERVICE_SRC) == 0 ||
        (capabilities.offline_services & PARSO_OFFLINE_SERVICE_LOUDNESS) == 0 ||
        parso_pcm_buffer_init(&input) != PARSO_STATUS_OK ||
        parso_src_options_init(&srcOptions) != PARSO_STATUS_OK ||
        parso_loudness_options_init(&loudnessOptions) != PARSO_STATUS_OK ||
        parso_loudness_result_init(&loudness) != PARSO_STATUS_OK) return 1;

    input.samples = samples;
    input.frames = frames;
    input.channel_count = 1;
    input.sample_rate_hz = 48000;
    srcOptions.destination_sample_rate_hz = 24000;
    if (parso_src_convert(&input, &srcOptions, converted.cHandle()) != PARSO_STATUS_OK ||
        converted.frames() < 23990 || converted.frames() > 24010 ||
        converted.sampleRate() != 24000 ||
        parso_loudness_measure(&input, &loudnessOptions, &loudness) != PARSO_STATUS_OK ||
        !std::isfinite(loudness.integrated_lufs) ||
        !std::isfinite(loudness.true_peak_dbtp)) {
        std::fprintf(stderr, "public_cpp_services_consumer: invalid service result: %s\n",
                     parso_last_error());
        input.samples = nullptr;
        parso_pcm_buffer_release(&input);
        return 1;
    }

    input.samples = nullptr;
    return parso_pcm_buffer_release(&input) == PARSO_STATUS_OK ? 0 : 1;
}
