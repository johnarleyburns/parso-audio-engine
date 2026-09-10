#include "parso.h"

#include <math.h>
#include <stddef.h>
#include <stdio.h>

static int require_status(parso_status_t status, const char *operation) {
    if (status == PARSO_STATUS_OK) return 1;
    fprintf(stderr, "public_c_consumer: %s: %s (%s)\n",
            operation, parso_status_string(status), parso_last_error());
    return 0;
}

int main(void) {
    enum { frames = 128 };
    float left[frames];
    float right[frames];
    float output_left[frames];
    float output_right[frames];
    for (size_t index = 0; index < frames; ++index) {
        left[index] = 0.2f;
        right[index] = 0.2f;
        output_left[index] = 0.0f;
        output_right[index] = 0.0f;
    }
    const float *planes[] = {left, right};

    parso_engine_options_t options;
    parso_control_t control;
    parso_pcm_view_t view;
    parso_output_view_t output;
    parso_command_t command;
    parso_stats_t stats;
    if (!require_status(parso_engine_options_init(&options), "options init") ||
        !require_status(parso_control_init(&control), "control init") ||
        !require_status(parso_pcm_view_init(&view), "PCM init") ||
        !require_status(parso_output_view_init(&output), "output init") ||
        !require_status(parso_command_init(&command), "command init") ||
        !require_status(parso_stats_init(&stats), "stats init")) return 1;

    options.max_frames = frames;
    view.planes = planes;
    view.frames = frames;
    view.channel_count = 2;
    view.sample_rate_hz = 48000;
    output.left = output_left;
    output.right = output_right;
    output.frames = frames;
    command.type = PARSO_COMMAND_PLAY;
    command.deck = 0;

    parso_engine_t *engine = NULL;
    if (!require_status(parso_engine_create(&options, &engine), "create") ||
        !require_status(parso_engine_set_control(engine, &control), "set control") ||
        !require_status(parso_engine_set_deck_buffer(engine, 0, &view), "set buffer") ||
        !require_status(parso_engine_post_command(engine, &command), "post play") ||
        !require_status(parso_engine_render(engine, &output), "render") ||
        !require_status(parso_engine_get_stats(engine, &stats), "get stats")) {
        if (engine) parso_engine_destroy(&engine);
        return 1;
    }

    int signal = 0;
    for (size_t index = 0; index < frames; ++index) {
        if (fabsf(output_left[index]) > 1.0e-5f || fabsf(output_right[index]) > 1.0e-5f) {
            signal = 1;
            break;
        }
    }
    const int ok = signal && stats.master_frame == frames && stats.deck_count == 2;
    if (!ok) fprintf(stderr, "public_c_consumer: invalid render result\n");
    if (!require_status(parso_engine_destroy(&engine), "destroy") || engine != NULL) return 1;
    if (!require_status(parso_engine_destroy(&engine), "repeat destroy")) return 1;
    return ok ? 0 : 1;
}
