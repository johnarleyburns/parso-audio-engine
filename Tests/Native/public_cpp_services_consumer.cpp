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
    parso_key_options_t keyOptions{};
    parso_key_result_t key{};
    if (parso_capabilities_init(&capabilities) != PARSO_STATUS_OK ||
        parso_capabilities_get(&capabilities) != PARSO_STATUS_OK ||
        (capabilities.offline_services & PARSO_OFFLINE_SERVICE_SRC) == 0 ||
        (capabilities.offline_services & PARSO_OFFLINE_SERVICE_LOUDNESS) == 0 ||
        parso_pcm_buffer_init(&input) != PARSO_STATUS_OK ||
        parso_src_options_init(&srcOptions) != PARSO_STATUS_OK ||
        parso_loudness_options_init(&loudnessOptions) != PARSO_STATUS_OK ||
        parso_loudness_result_init(&loudness) != PARSO_STATUS_OK ||
        parso_key_options_init(&keyOptions) != PARSO_STATUS_OK ||
        parso_key_result_init(&key) != PARSO_STATUS_OK) return 1;

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
    parso_codec_options_t codecOptions{};
    parso::PcmBuffer codecInput;
    parso::Bytes encoded;
    parso::PcmBuffer decoded;
    codecInput.cHandle()->samples = samples;
    codecInput.cHandle()->frames = frames;
    codecInput.cHandle()->channel_count = 1;
    codecInput.cHandle()->sample_rate_hz = 48000;
    if (codecInput.estimateKey(keyOptions, &key) != PARSO_STATUS_OK ||
        key.tonic_pitch_class >= 12 || key.camelot_number < 1 || key.camelot_number > 12) {
        std::fprintf(stderr, "public_cpp_services_consumer: invalid key result: %s\n",
                     parso_last_error());
        codecInput.cHandle()->samples = nullptr;
        input.samples = nullptr;
        parso_pcm_buffer_release(&input);
        return 1;
    }
    if (parso_codec_options_init(&codecOptions) != PARSO_STATUS_OK ||
        codecInput.writeCodec(PARSO_CODEC_OGG_VORBIS, codecOptions,
                              &encoded) != PARSO_STATUS_OK) {
        std::fprintf(stderr, "public_cpp_services_consumer: invalid codec setup: %s\n",
                     parso_last_error());
        codecInput.cHandle()->samples = nullptr;
        input.samples = nullptr;
        parso_pcm_buffer_release(&input);
        return 1;
    }

    // Exercise the C++ codec wrapper with the same borrowed input used by the
    // service checks. The static read helper is intentionally called on the
    // decoded object so ownership remains RAII-managed by PcmBuffer.
    if (parso::PcmBuffer::readCodec(encoded.data(), encoded.size(),
                                    PARSO_CODEC_OGG_VORBIS, codecOptions,
                                    &decoded) != PARSO_STATUS_OK ||
        decoded.frames() == 0 || decoded.channels() != 1 ||
        decoded.sampleRate() != 48000) {
        std::fprintf(stderr, "public_cpp_services_consumer: invalid Vorbis round trip: %s\n",
                     parso_last_error());
        codecInput.cHandle()->samples = nullptr;
        input.samples = nullptr;
        parso_pcm_buffer_release(&input);
        return 1;
    }

    codecInput.cHandle()->samples = nullptr;
    input.samples = nullptr;
    return parso_pcm_buffer_release(&input) == PARSO_STATUS_OK ? 0 : 1;
}
