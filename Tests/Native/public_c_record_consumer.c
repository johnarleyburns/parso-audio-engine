#include "parso.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>

static int require_ok(parso_status_t status, const char *operation) {
    if (status == PARSO_STATUS_OK) return 1;
    fprintf(stderr, "public_c_record_consumer: %s: %s (%s)\n",
            operation, parso_status_string(status), parso_last_error());
    return 0;
}

int main(void) {
    enum { source_frames = 4800, render_frames = 128 };
    float source[source_frames];
    float output_left[render_frames];
    float output_right[render_frames];
    float record_left[render_frames];
    float record_right[render_frames];
    for (uint32_t index = 0; index < source_frames; ++index) {
        source[index] = 0.1f * sinf((float)(2.0 * 3.141592653589793 * 220.0 * index / 48000.0));
    }
    const float *planes[] = {source};

    parso_engine_options_t options;
    parso_control_t control;
    parso_pcm_view_t view;
    parso_output_view_t output;
    parso_command_t command;
    parso_engine_t *engine = NULL;
    if (!require_ok(parso_engine_options_init(&options), "options init") ||
        !require_ok(parso_control_init(&control), "control init") ||
        !require_ok(parso_pcm_view_init(&view), "PCM init") ||
        !require_ok(parso_output_view_init(&output), "output init") ||
        !require_ok(parso_command_init(&command), "command init")) return 1;

    options.max_frames = render_frames;
    view.planes = planes;
    view.frames = source_frames;
    view.channel_count = 1;
    view.sample_rate_hz = 48000;
    output.left = output_left;
    output.right = output_right;
    output.frames = render_frames;
    command.type = PARSO_COMMAND_PLAY;
    command.deck = 0;

    if (!require_ok(parso_engine_create(&options, &engine), "create") ||
        !require_ok(parso_engine_set_control(engine, &control), "set control") ||
        !require_ok(parso_engine_set_deck_buffer(engine, 0, &view), "set buffer") ||
        !require_ok(parso_engine_post_command(engine, &command), "post play") ||
        !require_ok(parso_engine_record_reset(engine), "record reset") ||
        !require_ok(parso_engine_record_set_active(engine, 1), "record active") ||
        !require_ok(parso_engine_render(engine, &output), "render")) {
        if (engine) parso_engine_destroy(&engine);
        return 1;
    }

    uint32_t drained = 0;
    uint64_t dropped = UINT64_MAX;
    int ok = require_ok(parso_engine_record_drain(
        engine, record_left, record_right, render_frames, &drained), "record drain");
    ok = ok && drained == render_frames;
    ok = ok && require_ok(parso_engine_record_dropped_frames(engine, &dropped),
                          "dropped frame count");
    ok = ok && dropped == 0;
    ok = ok && require_ok(parso_engine_record_reset(engine), "record reset again");
    drained = UINT32_MAX;
    ok = ok && require_ok(parso_engine_record_drain(
        engine, record_left, record_right, 1, &drained), "empty record drain");
    ok = ok && drained == 0;
    ok = ok && require_ok(parso_engine_record_set_active(engine, 0), "record inactive");
    ok = ok && require_ok(parso_engine_destroy(&engine), "destroy");
    return ok && engine == NULL ? 0 : 1;
}
