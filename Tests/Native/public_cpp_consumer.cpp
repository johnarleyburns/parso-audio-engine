#include "parso.hpp"

#include <cmath>
#include <cstdio>

int main() {
    constexpr uint32_t frames = 256;
    float left[frames] = {};
    float right[frames] = {};
    float outputLeft[frames] = {};
    float outputRight[frames] = {};
    for (uint32_t index = 0; index < frames; ++index) {
        left[index] = 0.15f;
        right[index] = 0.15f;
    }
    const float *planes[] = {left, right};

    parso_engine_options_t options{};
    parso_control_t control{};
    parso_pcm_view_t view{};
    parso_output_view_t output{};
    parso_command_t command{};
    parso_stats_t stats{};
    parso_event_t events[4]{};
    uint32_t eventCount = 0;
    if (parso_engine_options_init(&options) != PARSO_STATUS_OK ||
        parso_control_init(&control) != PARSO_STATUS_OK ||
        parso_pcm_view_init(&view) != PARSO_STATUS_OK ||
        parso_output_view_init(&output) != PARSO_STATUS_OK ||
        parso_command_init(&command) != PARSO_STATUS_OK ||
        parso_stats_init(&stats) != PARSO_STATUS_OK ||
        parso_event_init(&events[0]) != PARSO_STATUS_OK ||
        parso_event_init(&events[1]) != PARSO_STATUS_OK ||
        parso_event_init(&events[2]) != PARSO_STATUS_OK ||
        parso_event_init(&events[3]) != PARSO_STATUS_OK) return 1;

    options.max_frames = frames;
    view.planes = planes;
    view.frames = frames;
    view.channel_count = 2;
    view.sample_rate_hz = 48000;
    output.left = outputLeft;
    output.right = outputRight;
    output.frames = frames;
    command.type = PARSO_COMMAND_PLAY;
    command.deck = 0;

    parso::Engine engine;
    if (parso::Engine::create(options, &engine) != PARSO_STATUS_OK ||
        engine.setControl(control) != PARSO_STATUS_OK ||
        engine.setDeckBuffer(0, view) != PARSO_STATUS_OK ||
        engine.postCommand(command) != PARSO_STATUS_OK ||
        engine.render(output) != PARSO_STATUS_OK ||
        engine.pollEvents(events, 4, &eventCount) != PARSO_STATUS_OK ||
        engine.getStats(&stats) != PARSO_STATUS_OK) {
        std::fprintf(stderr, "public_cpp_consumer: %s\n", parso_last_error());
        return 1;
    }

    if (engine.resetRecord() != PARSO_STATUS_OK ||
        engine.setRecordActive(true) != PARSO_STATUS_OK ||
        engine.render(output) != PARSO_STATUS_OK) {
        std::fprintf(stderr, "public_cpp_consumer: record activation failed: %s\n",
                     parso_last_error());
        return 1;
    }
    uint32_t recordedFrames = 0;
    uint64_t droppedFrames = 0;
    if (engine.drainRecord(outputLeft, outputRight, frames, &recordedFrames) != PARSO_STATUS_OK ||
        recordedFrames != frames ||
        engine.recordDroppedFrames(&droppedFrames) != PARSO_STATUS_OK || droppedFrames != 0 ||
        engine.resetRecord() != PARSO_STATUS_OK ||
        engine.setRecordActive(false) != PARSO_STATUS_OK) {
        std::fprintf(stderr, "public_cpp_consumer: invalid record result: %s\n",
                     parso_last_error());
        return 1;
    }

    parso::MixRecorder recorder(48000, PARSO_CODEC_WAV);
    parso::Bytes recording;
    if (recorder.append(outputLeft, outputRight, recordedFrames) != PARSO_STATUS_OK ||
        recorder.frames() != recordedFrames ||
        recorder.encode(&recording) != PARSO_STATUS_OK || recording.size() <= 44 ||
        recording.data()[0] != 'R' || recording.data()[1] != 'I' ||
        recording.data()[2] != 'F' || recording.data()[3] != 'F') {
        std::fprintf(stderr, "public_cpp_consumer: mix recorder failed: %s\n",
                     parso_last_error());
        return 1;
    }
    recorder.reset();
    if (recorder.frames() != 0) return 1;

    bool signal = false;
    for (uint32_t index = 0; index < frames; ++index) {
        if (std::fabs(outputLeft[index]) > 1.0e-5f || std::fabs(outputRight[index]) > 1.0e-5f) {
            signal = true;
            break;
        }
    }
    if (!signal || stats.master_frame != frames || !engine.isOpen() ||
        eventCount == 0 || events[0].deck != 0) {
        std::fprintf(stderr, "public_cpp_consumer: signal=%d master_frame=%llu open=%d\n",
                     signal ? 1 : 0,
                     static_cast<unsigned long long>(stats.master_frame),
                     engine.isOpen() ? 1 : 0);
        return 1;
    }
    return 0;
}
