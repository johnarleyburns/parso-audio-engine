#include "parso.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
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

std::size_t mp3PrefixBytes(const std::vector<uint8_t> &data, double seconds) {
    std::size_t offset = 0;
    if (data.size() >= 10 && data[0] == 'I' && data[1] == 'D' && data[2] == '3') {
        uint32_t tagSize = 0;
        for (std::size_t index = 6; index < 10; ++index)
            tagSize = (tagSize << 7u) | static_cast<uint32_t>(data[index] & 0x7Fu);
        offset = 10u + tagSize;
    }
    if (offset >= data.size()) return 0;

    constexpr int bitrateV1[] = {0, 32, 40, 48, 56, 64, 80, 96,
                                 112, 128, 160, 192, 224, 256, 320};
    constexpr int bitrateV2[] = {0, 8, 16, 24, 32, 40, 48, 56,
                                 64, 80, 96, 112, 128, 144, 160};
    constexpr int sampleRatesV1[] = {44100, 48000, 32000};
    uint64_t decodedSamples = 0;
    uint64_t targetSamples = 0;
    while (offset + 4u <= data.size()) {
        if (data[offset] != 0xFFu || (data[offset + 1u] & 0xE0u) != 0xE0u) {
            ++offset;
            continue;
        }
        const int version = (data[offset + 1u] >> 3u) & 3;
        const int layer = (data[offset + 1u] >> 1u) & 3;
        const int bitrateIndex = data[offset + 2u] >> 4u;
        const int sampleRateIndex = (data[offset + 2u] >> 2u) & 3;
        if (version == 1 || layer != 1 || bitrateIndex == 0 || bitrateIndex == 15 ||
            sampleRateIndex == 3) {
            ++offset;
            continue;
        }
        int sampleRate = sampleRatesV1[sampleRateIndex];
        if (version == 2) sampleRate /= 2;
        if (version == 0) sampleRate /= 4;
        const int bitrate = version == 3 ? bitrateV1[bitrateIndex] : bitrateV2[bitrateIndex];
        const std::size_t frameBytes = static_cast<std::size_t>(
            (version == 3 ? 144000 : 72000) * bitrate / sampleRate +
            ((data[offset + 2u] >> 1u) & 1u));
        if (frameBytes == 0 || offset + frameBytes > data.size()) break;
        if (targetSamples == 0)
            targetSamples = static_cast<uint64_t>((seconds + 2.0) * sampleRate);
        decodedSamples += static_cast<uint64_t>(version == 3 ? 1152 : 576);
        offset += frameBytes;
        if (decodedSamples >= targetSamples) return offset;
    }
    return 0;
}

bool loadMp3(const std::filesystem::path &path, double seconds,
             parso_pcm_buffer_t *decoded, parso_pcm_view_t *view,
             std::vector<float> *planar, const float *planes[2]) {
    std::ifstream file(path, std::ios::binary);
    if (!file) {
        std::cerr << "cannot open MP3 input: " << path << "\n";
        return false;
    }
    const std::vector<uint8_t> data((std::istreambuf_iterator<char>(file)),
                                    std::istreambuf_iterator<char>());
    const std::size_t prefixBytes = mp3PrefixBytes(data, seconds);
    if (prefixBytes == 0) {
        std::cerr << "MP3 input has no complete prefix for " << seconds << " seconds: "
                  << path << "\n";
        return false;
    }
    parso_codec_options_t options{};
    if (!requireOk(parso_pcm_buffer_init(decoded), "MP3 PCM init") ||
        !requireOk(parso_codec_options_init(&options), "MP3 options init") ||
        !requireOk(parso_codec_read(data.data(), prefixBytes, PARSO_CODEC_MP3,
                                    &options, decoded), "MP3 decode")) {
        return false;
    }
    if (decoded->frames == 0 || decoded->channel_count < 1 || decoded->channel_count > 2) {
        std::cerr << "MP3 decoded to an invalid PCM buffer: " << path << "\n";
        return false;
    }
    if (!requireOk(parso_pcm_view_init(view), "MP3 view init")) return false;
    if (decoded->channel_count == 1) {
        planes[0] = decoded->samples;
        planes[1] = nullptr;
    } else {
        if (decoded->frames > std::numeric_limits<std::size_t>::max() / 2u) return false;
        planar->resize(static_cast<std::size_t>(decoded->frames) * 2u);
        for (uint64_t frame = 0; frame < decoded->frames; ++frame) {
            (*planar)[static_cast<std::size_t>(frame)] = decoded->samples[frame * 2u];
            (*planar)[static_cast<std::size_t>(decoded->frames + frame)] =
                decoded->samples[frame * 2u + 1u];
        }
        planes[0] = planar->data();
        planes[1] = planar->data() + decoded->frames;
    }
    view->planes = planes;
    view->frames = decoded->frames;
    view->channel_count = decoded->channel_count;
    view->sample_rate_hz = decoded->sample_rate_hz;
    return true;
}

bool writeArtifact(const std::filesystem::path &outputDirectory, double seconds,
                   const std::string &scenario, const std::string &inputMp3A,
                   const std::string &inputMp3B, const std::string &fixtureA,
                   const std::string &fixtureB) {
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
    const bool music = !inputMp3A.empty() || !inputMp3B.empty();
    if (music && (inputMp3A.empty() || inputMp3B.empty() || !crossfaderSweep)) {
        std::cerr << "music acceptance requires two MP3 inputs and crossfader-sweep\n";
        return false;
    }
    std::vector<float> source(music ? 0 : frameCount);
    std::vector<float> sourceB(music ? 0 : (crossfaderSweep ? frameCount : 0));
    std::vector<float> planarA;
    std::vector<float> planarB;
    parso_pcm_buffer_t decodedA{};
    parso_pcm_buffer_t decodedB{};
    parso_pcm_view_t viewA{};
    parso_pcm_view_t viewB{};
    const float *planesA[2] = {nullptr, nullptr};
    const float *planesB[2] = {nullptr, nullptr};
    if (music) {
        if (!loadMp3(inputMp3A, seconds, &decodedA, &viewA, &planarA, planesA) ||
            !loadMp3(inputMp3B, seconds, &decodedB, &viewB, &planarB, planesB)) {
            parso_pcm_buffer_release(&decodedA);
            parso_pcm_buffer_release(&decodedB);
            return false;
        }
    }
    std::vector<float> renderedLeft(frameCount);
    std::vector<float> renderedRight(frameCount);
    std::vector<float> interleaved(frameCount * 2);
    if (!music) {
        for (size_t index = 0; index < frameCount; ++index) {
            const double frequency = index < frameCount / 2 ? 220.0 : 330.0;
            source[index] = static_cast<float>(0.18 * std::sin(
                2.0 * kPi * frequency * static_cast<double>(index) / kSampleRate));
            if (crossfaderSweep) {
                sourceB[index] = static_cast<float>(0.18 * std::sin(
                    2.0 * kPi * (frequency * 1.5) * static_cast<double>(index) / kSampleRate));
            }
        }
    }

    parso_engine_options_t engineOptions{};
    parso_control_t control{};
    parso_output_view_t output{};
    parso_command_t command{};
    parso_engine_t *engine = nullptr;
    bool ok = requireOk(parso_engine_options_init(&engineOptions), "engine options init") &&
              requireOk(parso_control_init(&control), "control init") &&
              requireOk(parso_output_view_init(&output), "output view init") &&
              requireOk(parso_command_init(&command), "command init");
    if (!ok) return false;
    engineOptions.max_frames = kBlockSize;
    if (!music) {
        ok = requireOk(parso_pcm_view_init(&viewA), "generated view init");
        viewA.planes = planesA;
        planesA[0] = source.data();
        viewA.frames = totalFrames;
        viewA.channel_count = 1;
        viewA.sample_rate_hz = kSampleRate;
        if (crossfaderSweep) {
            ok = ok && requireOk(parso_pcm_view_init(&viewB), "generated deck B view init");
            viewB.planes = planesB;
            planesB[0] = sourceB.data();
            viewB.frames = totalFrames;
            viewB.channel_count = 1;
            viewB.sample_rate_hz = kSampleRate;
        }
    }
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
    if (ok) ok = requireOk(parso_engine_set_deck_buffer(engine, 0, &viewA), "set deck buffer");
    if (ok) ok = requireOk(parso_engine_post_command(engine, &command), "post play");
    if (ok && crossfaderSweep) {
        ok = requireOk(parso_engine_set_deck_buffer(engine, 1, &viewB), "set deck B buffer");
        command.deck = 1;
        if (ok) ok = requireOk(parso_engine_post_command(engine, &command), "post deck B play");
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
    parso_pcm_buffer_release(&decodedA);
    parso_pcm_buffer_release(&decodedB);
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
            << (music ? "native-music-crossfader" :
                (crossfaderSweep ? "generated-native-crossfader" : "generated-native-tone"))
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
            << "  \"sourceTracks\": [";
    if (music) {
        sidecar << "{\"fixtureID\": \"" << fixtureA
                << "\", \"format\": \"mp3\", \"path\": \"" << inputMp3A
                << "\"}, {\"fixtureID\": \"" << fixtureB
                << "\", \"format\": \"mp3\", \"path\": \"" << inputMp3B << "\"}";
    }
    sidecar << "],\n"
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
    std::string inputMp3A;
    std::string inputMp3B;
    std::string fixtureA;
    std::string fixtureB;
    for (int index = 1; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--output-dir" && index + 1 < argc) {
            outputDirectory = argv[++index];
        } else if (argument == "--seconds" && index + 1 < argc) {
            seconds = std::stod(argv[++index]);
        } else if (argument == "--scenario" && index + 1 < argc) {
            scenario = argv[++index];
        } else if (argument == "--input-mp3-a" && index + 1 < argc) {
            inputMp3A = argv[++index];
        } else if (argument == "--input-mp3-b" && index + 1 < argc) {
            inputMp3B = argv[++index];
        } else if (argument == "--fixture-a" && index + 1 < argc) {
            fixtureA = argv[++index];
        } else if (argument == "--fixture-b" && index + 1 < argc) {
            fixtureB = argv[++index];
        } else {
            std::cerr << "usage: " << argv[0]
                      << " --output-dir PATH [--seconds N] [--scenario NAME]"
                      << " [--input-mp3-a PATH --input-mp3-b PATH]"
                      << " [--fixture-a ID --fixture-b ID]\n";
            return 2;
        }
    }
    if (outputDirectory.empty()) {
        std::cerr << "--output-dir is required\n";
        return 2;
    }
    return writeArtifact(outputDirectory, seconds, scenario, inputMp3A, inputMp3B,
                         fixtureA, fixtureB) ? 0 : 1;
}
