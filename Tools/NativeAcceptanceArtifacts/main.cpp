#include "parso.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace {

constexpr uint32_t kSampleRate = 48000;
constexpr uint32_t kBlockSize = 512;
constexpr double kPi = 3.14159265358979323846;

bool requireOk(parso_status_t status, const char *operation) {
    if (status == PARSO_STATUS_OK) return true;
    std::cerr << operation << ": " << parso_status_string(status)
              << " (" << parso_last_error() << ")\n";
    return false;
}

bool writeArtifact(const std::filesystem::path &outputDirectory, double seconds) {
    if (seconds < 30.0) {
        std::cerr << "acceptance artifacts require at least 30 seconds\n";
        return false;
    }
    const uint64_t totalFrames = static_cast<uint64_t>(seconds * kSampleRate);
    if (totalFrames == 0 || totalFrames > static_cast<uint64_t>(INT64_MAX)) {
        std::cerr << "requested duration is outside the supported range\n";
        return false;
    }
    const size_t frameCount = static_cast<size_t>(totalFrames);
    std::vector<float> source(frameCount);
    std::vector<float> renderedLeft(frameCount);
    std::vector<float> renderedRight(frameCount);
    std::vector<float> interleaved(frameCount * 2);
    for (size_t index = 0; index < frameCount; ++index) {
        const double frequency = index < frameCount / 2 ? 220.0 : 330.0;
        source[index] = static_cast<float>(0.18 * std::sin(
            2.0 * kPi * frequency * static_cast<double>(index) / kSampleRate));
    }
    const float *planes[] = {source.data()};

    parso_engine_options_t engineOptions{};
    parso_control_t control{};
    parso_pcm_view_t view{};
    parso_output_view_t output{};
    parso_command_t command{};
    parso_engine_t *engine = nullptr;
    bool ok = requireOk(parso_engine_options_init(&engineOptions), "engine options init") &&
              requireOk(parso_control_init(&control), "control init") &&
              requireOk(parso_pcm_view_init(&view), "PCM view init") &&
              requireOk(parso_output_view_init(&output), "output view init") &&
              requireOk(parso_command_init(&command), "command init");
    if (!ok) return false;
    engineOptions.max_frames = kBlockSize;
    view.planes = planes;
    view.frames = totalFrames;
    view.channel_count = 1;
    view.sample_rate_hz = kSampleRate;
    control.master_level = 0.8f;
    control.xfade_assign[0] = 2.0f;
    control.fader[0] = 1.0f;
    control.trim[0] = 1.0f;
    command.type = PARSO_COMMAND_PLAY;
    command.deck = 0;
    ok = requireOk(parso_engine_create(&engineOptions, &engine), "engine create");
    if (ok) ok = requireOk(parso_engine_set_control(engine, &control), "set control");
    if (ok) ok = requireOk(parso_engine_set_deck_buffer(engine, 0, &view), "set deck buffer");
    if (ok) ok = requireOk(parso_engine_post_command(engine, &command), "post play");
    for (uint64_t offset = 0; ok && offset < totalFrames; offset += kBlockSize) {
        const uint32_t frames = static_cast<uint32_t>(
            std::min<uint64_t>(kBlockSize, totalFrames - offset));
        output.left = renderedLeft.data() + offset;
        output.right = renderedRight.data() + offset;
        output.frames = frames;
        ok = requireOk(parso_engine_render(engine, &output), "render acceptance block");
    }
    if (engine) ok = requireOk(parso_engine_destroy(&engine), "engine destroy") && ok;
    if (!ok) return false;

    for (size_t index = 0; index < frameCount; ++index) {
        interleaved[index * 2] = renderedLeft[index];
        interleaved[index * 2 + 1] = renderedRight[index];
    }
    parso_pcm_buffer_t pcm{};
    parso_codec_options_t codecOptions{};
    parso_bytes_t encoded{};
    ok = requireOk(parso_pcm_buffer_init(&pcm), "PCM buffer init") &&
         requireOk(parso_codec_options_init(&codecOptions), "codec options init") &&
         requireOk(parso_bytes_init(&encoded), "byte buffer init");
    if (!ok) return false;
    pcm.samples = interleaved.data();
    pcm.frames = totalFrames;
    pcm.channel_count = 2;
    pcm.sample_rate_hz = kSampleRate;
    codecOptions.bits_per_sample = 16;
    ok = requireOk(parso_codec_write(&pcm, PARSO_CODEC_WAV, &codecOptions, &encoded), "WAV encode");
    std::filesystem::create_directories(outputDirectory);
    const auto stem = outputDirectory / "native-headless-tone";
    if (ok) {
        std::ofstream wav(stem.string() + ".wav", std::ios::binary);
        wav.write(reinterpret_cast<const char *>(encoded.data),
                  static_cast<std::streamsize>(encoded.size_bytes));
        ok = wav.good();
    }
    parso_bytes_release(&encoded);
    pcm.samples = nullptr;
    parso_pcm_buffer_release(&pcm);
    if (!ok) return false;
    std::ofstream sidecar(stem.string() + ".json");
    sidecar << "{\n"
            << "  \"fixtureID\": \"generated-native-tone\",\n"
            << "  \"scenario\": \"native-headless-tone\",\n"
            << "  \"audioDuration\": " << seconds << ",\n"
            << "  \"analysisDuration\": " << seconds << ",\n"
            << "  \"sampleRateHz\": " << kSampleRate << ",\n"
            << "  \"channelCount\": 2,\n"
            << "  \"events\": [{\"time\": 0.0, \"type\": \"play\"}]\n"
            << "}\n";
    return sidecar.good();
}

} // namespace

int main(int argc, char **argv) {
    std::filesystem::path outputDirectory;
    double seconds = 30.0;
    for (int index = 1; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--output-dir" && index + 1 < argc) {
            outputDirectory = argv[++index];
        } else if (argument == "--seconds" && index + 1 < argc) {
            seconds = std::stod(argv[++index]);
        } else {
            std::cerr << "usage: " << argv[0] << " --output-dir PATH [--seconds N]\n";
            return 2;
        }
    }
    if (outputDirectory.empty()) {
        std::cerr << "--output-dir is required\n";
        return 2;
    }
    return writeArtifact(outputDirectory, seconds) ? 0 : 1;
}
