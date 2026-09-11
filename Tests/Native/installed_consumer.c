#include "parso.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>

static int run_engine_smoke(void)
{
    enum { frames = 128 };
    float source[frames];
    float output_left[frames];
    float output_right[frames];
    const float *planes[] = {source};
    parso_engine_options_t options;
    parso_control_t control;
    parso_pcm_view_t view;
    parso_output_view_t output;
    parso_command_t command;
    parso_engine_t *engine = NULL;

    for (uint32_t index = 0; index < frames; ++index) {
        source[index] = 0.15f * sinf((float)index * 0.05f);
        output_left[index] = 0.0f;
        output_right[index] = 0.0f;
    }
    if (parso_engine_options_init(&options) != PARSO_STATUS_OK ||
        parso_control_init(&control) != PARSO_STATUS_OK ||
        parso_pcm_view_init(&view) != PARSO_STATUS_OK ||
        parso_output_view_init(&output) != PARSO_STATUS_OK ||
        parso_command_init(&command) != PARSO_STATUS_OK) {
        fprintf(stderr, "installed consumer: engine initialization failed: %s\n",
                parso_last_error());
        return 1;
    }
    options.max_frames = frames;
    view.planes = planes;
    view.frames = frames;
    view.channel_count = 1;
    view.sample_rate_hz = 48000;
    output.left = output_left;
    output.right = output_right;
    output.frames = frames;
    command.type = PARSO_COMMAND_PLAY;
    command.deck = 0;
    if (parso_engine_create(&options, &engine) != PARSO_STATUS_OK ||
        parso_engine_set_control(engine, &control) != PARSO_STATUS_OK ||
        parso_engine_set_deck_buffer(engine, 0, &view) != PARSO_STATUS_OK ||
        parso_engine_post_command(engine, &command) != PARSO_STATUS_OK ||
        parso_engine_render(engine, &output) != PARSO_STATUS_OK) {
        fprintf(stderr, "installed consumer: engine render failed: %s\n",
                parso_last_error());
        parso_engine_destroy(&engine);
        return 1;
    }
    int signal = 0;
    for (uint32_t index = 0; index < frames; ++index) {
        if (fabsf(output_left[index]) > 1.0e-5f ||
            fabsf(output_right[index]) > 1.0e-5f) {
            signal = 1;
            break;
        }
    }
    parso_engine_destroy(&engine);
    return signal && engine == NULL ? 0 : 1;
}

int main(void)
{
    enum { frames = 1024 };
    float samples[frames];
    parso_capabilities_t capabilities;
    parso_codec_options_t options;
    parso_pcm_buffer_t input;
    parso_pcm_buffer_t decoded;
    parso_bytes_t encoded;
    parso_key_options_t key_options;
    parso_key_result_t key;
    parso_structure_options_t structure_options;
    parso_analysis_options_t analysis_options;
    parso_analysis_result_t analysis;
    parso_structure_section_t sections[8];
    float waveform_min[8];
    float waveform_max[8];
    uint32_t section_count = 0;
    uint32_t index;

    for (index = 0; index < frames; ++index)
        samples[index] = 0.25f * sinf((float)index * 0.03f);
    if (parso_capabilities_init(&capabilities) != PARSO_STATUS_OK ||
        parso_capabilities_get(&capabilities) != PARSO_STATUS_OK ||
        (capabilities.encode_containers & PARSO_CONTAINER_OGG_VORBIS) == 0 ||
        parso_codec_options_init(&options) != PARSO_STATUS_OK ||
        parso_pcm_buffer_init(&input) != PARSO_STATUS_OK ||
        parso_pcm_buffer_init(&decoded) != PARSO_STATUS_OK ||
        parso_bytes_init(&encoded) != PARSO_STATUS_OK ||
        parso_key_options_init(&key_options) != PARSO_STATUS_OK ||
        parso_key_result_init(&key) != PARSO_STATUS_OK ||
        parso_structure_options_init(&structure_options) != PARSO_STATUS_OK ||
        parso_analysis_options_init(&analysis_options) != PARSO_STATUS_OK ||
        parso_analysis_result_init(&analysis) != PARSO_STATUS_OK) {
        fprintf(stderr, "installed consumer: initialization failed: %s\n", parso_last_error());
        return 1;
    }
    input.samples = samples;
    input.frames = frames;
    input.channel_count = 1;
    input.sample_rate_hz = 48000;
    if (parso_key_measure(&input, &key_options, &key) != PARSO_STATUS_OK ||
        key.tonic_pitch_class >= 12 ||
        parso_structure_measure(&input, &structure_options, sections, 8, &section_count) !=
            PARSO_STATUS_OK || section_count == 0 || sections[0].kind > 7 ||
        parso_analysis_measure(&input, &analysis_options, &analysis) != PARSO_STATUS_OK ||
            analysis.duration_seconds <= 0.0 || !isfinite(analysis.rms) ||
            !isfinite(analysis.peak) ||
        parso_waveform_generate(&input, 8, waveform_min, waveform_max) != PARSO_STATUS_OK ||
            waveform_min[0] > waveform_max[0] || !isfinite(waveform_max[0])) {
        fprintf(stderr, "installed consumer: analysis ABI failed: %s\n", parso_last_error());
        parso_bytes_release(&encoded);
        input.samples = NULL;
        parso_pcm_buffer_release(&input);
        return 1;
    }
    if (parso_codec_write(&input, PARSO_CODEC_OGG_VORBIS, &options, &encoded) != PARSO_STATUS_OK ||
        encoded.size_bytes < 4 || encoded.data[0] != 'O' || encoded.data[1] != 'g' ||
        encoded.data[2] != 'g' || encoded.data[3] != 'S' ||
        parso_codec_read(encoded.data, encoded.size_bytes, PARSO_CODEC_OGG_VORBIS,
                         &options, &decoded) != PARSO_STATUS_OK ||
        decoded.frames == 0 || decoded.channel_count != 1 ||
        decoded.sample_rate_hz != 48000 || !isfinite(decoded.samples[0])) {
        fprintf(stderr, "installed consumer: Xiph Vorbis round trip failed: %s\n",
                parso_last_error());
        parso_pcm_buffer_release(&decoded);
        parso_bytes_release(&encoded);
        input.samples = NULL;
        parso_pcm_buffer_release(&input);
        return 1;
    }
    parso_pcm_buffer_release(&decoded);
    parso_bytes_release(&encoded);
    input.samples = NULL;
    parso_pcm_buffer_release(&input);
    return run_engine_smoke();
}
