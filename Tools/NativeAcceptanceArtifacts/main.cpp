#include "parso.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <utility>
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

bool writeArtifact(const std::filesystem::path &outputDirectory, double seconds,
                   const std::string &scenario) {
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
    const bool crossfaderSweep = scenario == "crossfader-sweep";
    if (!crossfaderSweep && scenario != "native-headless-tone") {
        std::cerr << "unsupported acceptance scenario: " << scenario << "\n";
        return false;
    }
    std::vector<float> source(frameCount);
    std::vector<float> sourceB(crossfaderSweep ? frameCount : 0);
    std::vector<float> renderedLeft(frameCount);
    std::vector<float> renderedRight(frameCount);
    std::vector<float> interleaved(frameCount * 2);
    for (size_t index = 0; index < frameCount; ++index) {
        const double frequency = index < frameCount / 2 ? 220.0 : 330.0;
        source[index] = static_cast<float>(0.18 * std::sin(
            2.0 * kPi * frequency * static_cast<double>(index) / kSampleRate));
        if (crossfaderSweep) {
            sourceB[index] = static_cast<float>(0.18 * std::sin(
                2.0 * kPi * (frequency * 1.5) * static_cast<double>(index) / kSampleRate));
        }
    }
    const float *planes[] = {source.data()};
    const float *planesB[] = {sourceB.data()};

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
    control.xfade_assign[0] = crossfaderSweep ? 0.0f : 2.0f;
    control.fader[0] = 1.0f;
    control.trim[0] = 1.0f;
    if (crossfaderSweep) {
        control.xfade_assign[1] = 1.0f;
        control.fader[1] = 1.0f;
        control.trim[1] = 1.0f;
    }
    command.type = PARSO_COMMAND_PLAY;
    command.deck = 0;
    ok = requireOk(parso_engine_create(&engineOptions, &engine), "engine create");
    if (ok) ok = requireOk(parso_engine_set_control(engine, &control), "set control");
    if (ok) ok = requireOk(parso_engine_set_deck_buffer(engine, 0, &view), "set deck buffer");
    if (ok) ok = requireOk(parso_engine_post_command(engine, &command), "post play");
    if (ok && crossfaderSweep) {
        view.planes = planesB;
        ok = requireOk(parso_engine_set_deck_buffer(engine, 1, &view), "set deck B buffer");
        command.deck = 1;
        if (ok) ok = requireOk(parso_engine_post_command(engine, &command), "post deck B play");
        view.planes = planes;
        command.deck = 0;
    }
    if (ok) ok = requireOk(parso_engine_record_reset(engine), "record reset");
    if (ok) ok = requireOk(parso_engine_record_set_active(engine, 1), "record activate");
    std::vector<std::pair<double, std::string>> events;
    events.emplace_back(0.0, "play-deck-a");
    if (crossfaderSweep) {
        events.emplace_back(0.0, "play-deck-b");
        events.emplace_back(0.0, "crossfader-start-minus-one");
        events.emplace_back(seconds, "crossfader-end-plus-one");
    }
    for (uint64_t offset = 0; ok && offset < totalFrames; offset += kBlockSize) {
        const uint32_t frames = static_cast<uint32_t>(
            std::min<uint64_t>(kBlockSize, totalFrames - offset));
        if (crossfaderSweep) {
            control.crossfader = totalFrames > 1
                ? -1.0f + 2.0f * static_cast<float>(offset) /
                    static_cast<float>(totalFrames - 1)
                : -1.0f;
            ok = requireOk(parso_engine_set_control(engine, &control), "set crossfader");
        }
        output.left = renderedLeft.data() + offset;
        output.right = renderedRight.data() + offset;
        output.frames = frames;
        ok = requireOk(parso_engine_render(engine, &output), "render acceptance block");
        uint32_t recordedFrames = 0;
        if (ok) {
            ok = requireOk(parso_engine_record_drain(
                engine, renderedLeft.data() + offset, renderedRight.data() + offset,
                frames, &recordedFrames), "record drain acceptance block");
        }
        if (ok && recordedFrames != frames) {
            std::cerr << "record drain returned an incomplete acceptance block\n";
            ok = false;
        }
    }
    if (engine) ok = requireOk(parso_engine_record_set_active(engine, 0), "record deactivate") && ok;
    if (engine) ok = requireOk(parso_engine_destroy(&engine), "engine destroy") && ok;
    if (!ok) return false;

    for (size_t index = 0; index < frameCount; ++index) {
        interleaved[index * 2] = renderedLeft[index];
        interleaved[index * 2 + 1] = renderedRight[index];
    }
    parso_pcm_buffer_t pcm{};
    parso_codec_options_t codecOptions{};
    parso_bytes_t encoded{};
    parso_analysis_options_t analysisOptions{};
    parso_analysis_result_t analysis{};
    std::vector<float> waveformMin(32);
    std::vector<float> waveformMax(32);
    ok = requireOk(parso_pcm_buffer_init(&pcm), "PCM buffer init") &&
         requireOk(parso_codec_options_init(&codecOptions), "codec options init") &&
         requireOk(parso_bytes_init(&encoded), "byte buffer init") &&
         requireOk(parso_analysis_options_init(&analysisOptions), "analysis options init") &&
         requireOk(parso_analysis_result_init(&analysis), "analysis result init");
    if (!ok) return false;
    pcm.samples = interleaved.data();
    pcm.frames = totalFrames;
    pcm.channel_count = 2;
    pcm.sample_rate_hz = kSampleRate;
    codecOptions.bits_per_sample = 16;
    ok = requireOk(parso_analysis_measure(&pcm, &analysisOptions, &analysis), "analysis measure") &&
         requireOk(parso_waveform_generate(&pcm, 32, waveformMin.data(), waveformMax.data()),
                   "waveform generate") &&
         requireOk(parso_codec_write(&pcm, PARSO_CODEC_WAV, &codecOptions, &encoded), "WAV encode");
    std::filesystem::create_directories(outputDirectory);
    const auto stem = outputDirectory / (scenario == "native-headless-tone"
        ? "native-headless-tone" : "native-crossfader-sweep");
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
            << "  \"fixtureID\": \""
            << (crossfaderSweep ? "generated-native-crossfader" : "generated-native-tone")
            << "\",\n"
            << "  \"scenario\": \"" << scenario << "\",\n"
            << "  \"audioDuration\": " << seconds << ",\n"
            << "  \"analysisDuration\": " << seconds << ",\n"
            << "  \"sampleRateHz\": " << kSampleRate << ",\n"
            << "  \"channelCount\": 2,\n"
            << "  \"analysis\": {\"durationSeconds\": " << analysis.duration_seconds
            << ", \"rms\": " << analysis.rms
            << ", \"peak\": " << analysis.peak
            << ", \"bpm\": " << analysis.bpm
            << ", \"bpmConfidence\": " << analysis.bpm_confidence << "},\n"
            << "  \"waveform\": {\"min\": [";
    for (size_t index = 0; index < waveformMin.size(); ++index) {
        if (index != 0) sidecar << ", ";
        sidecar << waveformMin[index];
    }
    sidecar << "], \"max\": [";
    for (size_t index = 0; index < waveformMax.size(); ++index) {
        if (index != 0) sidecar << ", ";
        sidecar << waveformMax[index];
    }
    sidecar << "]},\n"
            << "  \"events\": [";
    for (size_t index = 0; index < events.size(); ++index) {
        if (index != 0) sidecar << ", ";
        sidecar << "{\"time\": " << events[index].first
                << ", \"type\": \"" << events[index].second << "\"}";
    }
    sidecar << "]\n}\n";
    return sidecar.good();
}

} // namespace

int main(int argc, char **argv) {
    std::filesystem::path outputDirectory;
    double seconds = 30.0;
    std::string scenario = "native-headless-tone";
    for (int index = 1; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--output-dir" && index + 1 < argc) {
            outputDirectory = argv[++index];
        } else if (argument == "--seconds" && index + 1 < argc) {
            seconds = std::stod(argv[++index]);
        } else if (argument == "--scenario" && index + 1 < argc) {
            scenario = argv[++index];
        } else {
            std::cerr << "usage: " << argv[0]
                      << " --output-dir PATH [--seconds N] [--scenario NAME]\n";
            return 2;
        }
    }
    if (outputDirectory.empty()) {
        std::cerr << "--output-dir is required\n";
        return 2;
    }
    return writeArtifact(outputDirectory, seconds, scenario) ? 0 : 1;
}
