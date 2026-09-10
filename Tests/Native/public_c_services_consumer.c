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
    float samples[frames];
    for (uint32_t index = 0; index < frames; ++index) {
        samples[index] = 0.25f;
    }

    parso_capabilities_t capabilities;
    parso_pcm_buffer_t input;
    parso_pcm_buffer_t converted;
    parso_src_options_t src_options;
    parso_loudness_options_t loudness_options;
    parso_loudness_result_t loudness;
    if (!require_ok(parso_capabilities_init(&capabilities), "capabilities init") ||
        !require_ok(parso_capabilities_get(&capabilities), "capabilities get") ||
        (capabilities.offline_services & (PARSO_OFFLINE_SERVICE_SRC |
                                          PARSO_OFFLINE_SERVICE_LOUDNESS)) !=
            (PARSO_OFFLINE_SERVICE_SRC | PARSO_OFFLINE_SERVICE_LOUDNESS) ||
        !require_ok(parso_pcm_buffer_init(&input), "input init") ||
        !require_ok(parso_pcm_buffer_init(&converted), "converted init") ||
        !require_ok(parso_src_options_init(&src_options), "SRC options init") ||
        !require_ok(parso_loudness_options_init(&loudness_options), "loudness options init") ||
        !require_ok(parso_loudness_result_init(&loudness), "loudness result init")) return 1;

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

    src_options.quality = 99;
    const int rejected = parso_src_convert(&input, &src_options, &converted) ==
                         PARSO_STATUS_INVALID_ARGUMENT;
    parso_pcm_buffer_release(&converted);
    input.samples = NULL;
    parso_pcm_buffer_release(&input);
    return rejected ? 0 : 1;
}
