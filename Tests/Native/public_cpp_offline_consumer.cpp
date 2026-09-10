#include "parso.hpp"

#include <cmath>
#include <cstdint>
#include <cstdio>

int main() {
    parso_capabilities_t capabilities{};
    if (parso_capabilities_init(&capabilities) != PARSO_STATUS_OK ||
        parso_capabilities_get(&capabilities) != PARSO_STATUS_OK ||
        (capabilities.decode_containers & PARSO_CONTAINER_WAV) == 0) return 1;

    constexpr uint32_t frames = 3;
    constexpr uint32_t channels = 1;
    const float samples[frames] = {-0.75f, 0.0f, 0.75f};
    parso::PcmBuffer source;
    parso::Bytes wav;
    parso::Bytes raw;

    parso_pcm_buffer_t borrowed{};
    if (parso_pcm_buffer_init(&borrowed) != PARSO_STATUS_OK) return 1;
    borrowed.samples = const_cast<float *>(samples);
    borrowed.frames = frames;
    borrowed.channel_count = channels;
    borrowed.sample_rate_hz = 44100;

    // The C++ wrapper is move-only and owns read results, while a borrowed
    // C view remains sufficient for an offline write operation.
    if (parso_wav_write(&borrowed, 32, 1, wav.cHandle()) != PARSO_STATUS_OK ||
        wav.size() != 44u + frames * sizeof(float)) return 1;

    if (parso::PcmBuffer::readWav(wav.data(), wav.size(), &source) != PARSO_STATUS_OK ||
        source.frames() != frames || source.channels() != channels ||
        source.sampleRate() != 44100 ||
        std::fabs(source.samples()[0] - samples[0]) > 1.0e-7f ||
        std::fabs(source.samples()[2] - samples[2]) > 1.0e-7f) return 1;

    if (source.writePCM(8, &raw) != PARSO_STATUS_OK || raw.size() != frames) return 1;
    parso::PcmBuffer roundTrip;
    if (parso::PcmBuffer::readPCM(raw.data(), raw.size(), 44100, 1, 8, &roundTrip) !=
            PARSO_STATUS_OK ||
        std::fabs(roundTrip.samples()[0] - samples[0]) > 1.0e-2f ||
        std::fabs(roundTrip.samples()[2] - samples[2]) > 1.0e-2f) return 1;

    borrowed.samples = nullptr;
    if (parso_pcm_buffer_release(&borrowed) != PARSO_STATUS_OK ||
        parso_pcm_buffer_release(&borrowed) != PARSO_STATUS_OK) return 1;
    return 0;
}
