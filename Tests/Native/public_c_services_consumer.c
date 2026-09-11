#include "parso.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>

static int require_ok(parso_status_t status, const char *operation) {
    if (status == PARSO_STATUS_OK) return 1;
    fprintf(stderr, "public_c_services_consumer: %s: %s (%s)\n",
            operation, parso_status_string(status), parso_last_error());
    return 0;
}

int main(void) {
    enum { frames = 48000 };
    enum { analysis_frames = 384000 };
    float samples[frames];
    static float key_samples[frames];
    static float click_track[analysis_frames];
    static float structure_samples[analysis_frames];
    for (uint32_t index = 0; index < frames; ++index) {
        samples[index] = 0.25f;
    }
    for (uint32_t beat = 0; beat < analysis_frames; beat += 24000) {
        for (uint32_t index = beat; index < beat + 128; ++index) click_track[index] = 1.0f;
    }
    for (uint32_t index = 0; index < frames; ++index) {
        const double time = (double)index / 48000.0;
        key_samples[index] = (float)(0.25 * sin(6.283185307179586 * 110.0 * time) +
                                     0.20 * sin(6.283185307179586 * 220.0 * time) +
                                     0.20 * sin(6.283185307179586 * 261.63 * time) +
                                     0.20 * sin(6.283185307179586 * 329.63 * time));
    }
    for (uint32_t index = 96000; index < 192000; ++index) {
        structure_samples[index] = (float)(0.1 * sin(6.283185307179586 * 110.0 * index / 48000.0));
    }
    for (uint32_t index = 192000; index < 288000; ++index) {
        structure_samples[index] = (float)(0.5 * sin(6.283185307179586 * 220.0 * index / 48000.0));
    }
    for (uint32_t index = 288000; index < analysis_frames; ++index) {
        structure_samples[index] = (float)(0.1 * sin(6.283185307179586 * 110.0 * index / 48000.0));
    }

    parso_capabilities_t capabilities;
    parso_pcm_buffer_t input;
    parso_pcm_buffer_t converted;
    parso_src_options_t src_options;
    parso_loudness_options_t loudness_options;
    parso_loudness_result_t loudness;
    parso_analysis_options_t analysis_options;
    parso_analysis_result_t analysis;
    parso_key_options_t key_options;
    parso_key_result_t key;
    parso_structure_options_t structure_options;
    parso_structure_section_t structure[16];
    uint32_t structure_count = 0;
    float waveform_min[4];
    float waveform_max[4];
    if (!require_ok(parso_capabilities_init(&capabilities), "capabilities init") ||
        !require_ok(parso_capabilities_get(&capabilities), "capabilities get") ||
        (capabilities.offline_services & (PARSO_OFFLINE_SERVICE_SRC |
                                          PARSO_OFFLINE_SERVICE_LOUDNESS |
                                          PARSO_OFFLINE_SERVICE_ANALYSIS)) !=
            (PARSO_OFFLINE_SERVICE_SRC | PARSO_OFFLINE_SERVICE_LOUDNESS |
             PARSO_OFFLINE_SERVICE_ANALYSIS) ||
        !require_ok(parso_pcm_buffer_init(&input), "input init") ||
        !require_ok(parso_pcm_buffer_init(&converted), "converted init") ||
        !require_ok(parso_src_options_init(&src_options), "SRC options init") ||
        !require_ok(parso_loudness_options_init(&loudness_options), "loudness options init") ||
        !require_ok(parso_loudness_result_init(&loudness), "loudness result init") ||
        !require_ok(parso_analysis_options_init(&analysis_options), "analysis options init") ||
        !require_ok(parso_analysis_result_init(&analysis), "analysis result init") ||
        !require_ok(parso_key_options_init(&key_options), "key options init") ||
        !require_ok(parso_key_result_init(&key), "key result init") ||
        !require_ok(parso_structure_options_init(&structure_options), "structure options init")) return 1;

    input.samples = samples;
    input.frames = frames;
    input.channel_count = 1;
    input.sample_rate_hz = 48000;
    src_options.destination_sample_rate_hz = 24000;
    if (!require_ok(parso_src_convert(&input, &src_options, &converted), "SRC convert") ||
        converted.channel_count != 1 || converted.sample_rate_hz != 24000 ||
        converted.frames < 23990 || converted.frames > 24010 ||
        !require_ok(parso_loudness_measure(&input, &loudness_options, &loudness),
                    "loudness measure") ||
        !isfinite(loudness.integrated_lufs) ||
        !isfinite(loudness.true_peak_dbtp) ||
        (loudness.gain_to_target_db -
             (loudness_options.target_lufs - loudness.integrated_lufs)) > 1.0e-9 ||
        (loudness.gain_to_target_db -
             (loudness_options.target_lufs - loudness.integrated_lufs)) < -1.0e-9) {
        fprintf(stderr, "public_c_services_consumer: invalid service result\n");
        parso_pcm_buffer_release(&converted);
        input.samples = NULL;
        parso_pcm_buffer_release(&input);
        return 1;
    }

    parso_pcm_buffer_t analysis_input = {
        .size = sizeof(parso_pcm_buffer_t), .abi_version = PARSO_ABI_VERSION,
        .samples = click_track, .frames = analysis_frames,
        .channel_count = 1, .sample_rate_hz = 48000
    };
    if (!require_ok(parso_analysis_measure(&analysis_input, &analysis_options, &analysis),
                    "analysis measure") || analysis.bpm < 118.0 || analysis.bpm > 122.0 ||
        analysis.bpm_confidence < 0.5) {
        fprintf(stderr, "public_c_services_consumer: invalid analysis result bpm=%f confidence=%f\n",
                analysis.bpm, analysis.bpm_confidence);
        parso_pcm_buffer_release(&converted);
        input.samples = NULL;
        parso_pcm_buffer_release(&input);
        return 1;
    }
    if (!require_ok(parso_waveform_generate(&analysis_input, 4, waveform_min, waveform_max),
                    "waveform generate") || waveform_min[0] > waveform_max[0] ||
        waveform_max[0] < 0.9f) {
        fprintf(stderr, "public_c_services_consumer: invalid waveform result\n");
        parso_pcm_buffer_release(&converted);
        input.samples = NULL;
        parso_pcm_buffer_release(&input);
        return 1;
    }
    parso_pcm_buffer_t key_input = {
        .size = sizeof(parso_pcm_buffer_t), .abi_version = PARSO_ABI_VERSION,
        .samples = key_samples, .frames = frames, .channel_count = 1, .sample_rate_hz = 48000
    };
    if (!require_ok(parso_key_measure(&key_input, &key_options, &key), "key measure") ||
        key.tonic_pitch_class != 9 || key.is_minor != 1 || key.camelot_number != 8 ||
        key.camelot_letter != 1 || key.confidence < 0.3) {
        fprintf(stderr, "public_c_services_consumer: invalid key result tonic=%u mode=%u camelot=%u%c confidence=%f\n",
                key.tonic_pitch_class, key.is_minor, key.camelot_number,
                key.camelot_letter ? 'A' : 'B', key.confidence);
        parso_pcm_buffer_release(&converted);
        input.samples = NULL;
        parso_pcm_buffer_release(&input);
        return 1;
    }
    parso_pcm_buffer_t structure_input = {
        .size = sizeof(parso_pcm_buffer_t), .abi_version = PARSO_ABI_VERSION,
        .samples = structure_samples, .frames = analysis_frames,
        .channel_count = 1, .sample_rate_hz = 48000
    };
    if (!require_ok(parso_structure_measure(&structure_input, &structure_options,
                                           structure, 16, &structure_count), "structure measure") ||
        structure_count < 3 || structure[0].kind != 0 || structure[1].start_seconds <= 0.0) {
        fprintf(stderr, "public_c_services_consumer: invalid structure count=%u\n", structure_count);
        parso_pcm_buffer_release(&converted);
        input.samples = NULL;
        parso_pcm_buffer_release(&input);
        return 1;
    }

    src_options.quality = 99;
    const int rejected = parso_src_convert(&input, &src_options, &converted) ==
                         PARSO_STATUS_INVALID_ARGUMENT;
    parso_pcm_buffer_release(&converted);
    input.samples = NULL;
    parso_pcm_buffer_release(&input);
    return rejected ? 0 : 1;
}
