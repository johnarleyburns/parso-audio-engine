PARSO_API parso_status_t parso_src_options_init(parso_src_options_t *options) {
    if (!options) return fail(PARSO_STATUS_INVALID_ARGUMENT, "SRC options are null");
    std::memset(options, 0, sizeof(*options));
    options->size = sizeof(*options);
    options->abi_version = PARSO_ABI_VERSION;
    options->destination_sample_rate_hz = 48000;
    options->quality = PARSO_SRC_QUALITY_BEST;
    return PARSO_STATUS_OK;
}

PARSO_API parso_status_t parso_src_convert(
    const parso_pcm_buffer_t *input, const parso_src_options_t *options,
    parso_pcm_buffer_t *outBuffer
) {
    try {
        const parso_status_t outputStatus = validateEmptyPCMBuffer(outBuffer);
        if (outputStatus != PARSO_STATUS_OK) return outputStatus;
        const parso_status_t inputStatus = validatePCMBuffer(input);
        if (inputStatus != PARSO_STATUS_OK) return inputStatus;
        const parso_status_t optionsStatus = validateSRCOptions(options);
        if (optionsStatus != PARSO_STATUS_OK) return optionsStatus;
        const uint32_t sourceRate = options->source_sample_rate_hz != 0
            ? options->source_sample_rate_hz : input->sample_rate_hz;
        const uint32_t channels = options->channel_count != 0
            ? options->channel_count : input->channel_count;
        if (sourceRate != input->sample_rate_hz || channels != input->channel_count) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "SRC options do not match input PCM");
        }
        if (input->frames > static_cast<uint64_t>(std::numeric_limits<long>::max())) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "SRC input is too large");
        }
        const double ratio = static_cast<double>(options->destination_sample_rate_hz) /
                             static_cast<double>(sourceRate);
        if (src_is_valid_ratio(ratio) == 0) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "SRC ratio is outside supported limits");
        }
        if (input->frames == 0) {
            outBuffer->channel_count = channels;
            outBuffer->sample_rate_hz = options->destination_sample_rate_hz;
            lastError = "ok";
            return PARSO_STATUS_OK;
        }
        const double estimated = std::ceil(static_cast<double>(input->frames) * ratio) + 256.0;
        if (!std::isfinite(estimated) ||
            estimated > static_cast<double>(std::numeric_limits<long>::max()) ||
            estimated > static_cast<double>(std::numeric_limits<size_t>::max() / sizeof(float) /
                                             channels)) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "SRC output is too large");
        }
        const long outputCapacity = static_cast<long>(estimated);
        const uint64_t sampleCount = static_cast<uint64_t>(outputCapacity) * channels;
        std::vector<float> samples(static_cast<size_t>(sampleCount));
        SRC_DATA data{};
        data.data_in = input->samples;
        data.data_out = samples.data();
        data.input_frames = static_cast<long>(input->frames);
        data.output_frames = outputCapacity;
        data.end_of_input = 1;
        data.src_ratio = ratio;
        const int error = src_simple(&data, static_cast<int>(options->quality),
                                     static_cast<int>(channels));
        if (error != 0) return fail(PARSO_STATUS_INTERNAL, src_strerror(error));
        samples.resize(static_cast<size_t>(data.output_frames_gen) * channels);
        const parso_status_t copyStatus = copyPCM(
            samples, options->destination_sample_rate_hz, channels, outBuffer
        );
        if (copyStatus == PARSO_STATUS_OK) lastError = "ok";
        return copyStatus;
    } catch (const std::bad_alloc &) {
        return fail(PARSO_STATUS_OUT_OF_MEMORY, "SRC allocation failed");
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while converting sample rate");
    }
}

PARSO_API parso_status_t parso_loudness_options_init(parso_loudness_options_t *options) {
    if (!options) return fail(PARSO_STATUS_INVALID_ARGUMENT, "loudness options are null");
    std::memset(options, 0, sizeof(*options));
    options->size = sizeof(*options);
    options->abi_version = PARSO_ABI_VERSION;
    options->target_lufs = -14.0;
    return PARSO_STATUS_OK;
}

PARSO_API parso_status_t parso_loudness_result_init(parso_loudness_result_t *result) {
    if (!result) return fail(PARSO_STATUS_INVALID_ARGUMENT, "loudness result is null");
    std::memset(result, 0, sizeof(*result));
    result->size = sizeof(*result);
    result->abi_version = PARSO_ABI_VERSION;
    result->integrated_lufs = -HUGE_VAL;
    result->true_peak_dbtp = -HUGE_VAL;
    result->gain_to_target_db = HUGE_VAL;
    return PARSO_STATUS_OK;
}

PARSO_API parso_status_t parso_loudness_measure(
    const parso_pcm_buffer_t *input, const parso_loudness_options_t *options,
    parso_loudness_result_t *result
) {
    try {
        const parso_status_t resultStatus = validateLoudnessResult(result);
        if (resultStatus != PARSO_STATUS_OK) return resultStatus;
        const parso_status_t inputStatus = validatePCMBuffer(input);
        if (inputStatus != PARSO_STATUS_OK) return inputStatus;
        const parso_status_t optionsStatus = validateLoudnessOptions(options);
        if (optionsStatus != PARSO_STATUS_OK) return optionsStatus;
        const int mode = EBUR128_MODE_I | EBUR128_MODE_LRA | EBUR128_MODE_TRUE_PEAK;
        ebur128_state *state = ebur128_init(
            input->channel_count, input->sample_rate_hz, mode
        );
        if (!state) return fail(PARSO_STATUS_OUT_OF_MEMORY, "loudness state allocation failed");
        const int addStatus = ebur128_add_frames_float(
            state, input->samples, static_cast<size_t>(input->frames)
        );
        if (addStatus != EBUR128_SUCCESS) {
            ebur128_destroy(&state);
            return fail(PARSO_STATUS_INTERNAL, "loudness frame processing failed");
        }
        double integrated = -HUGE_VAL;
        if (ebur128_loudness_global(state, &integrated) != EBUR128_SUCCESS) {
            ebur128_destroy(&state);
            return fail(PARSO_STATUS_INTERNAL, "integrated loudness measurement failed");
        }
        double peak = 0.0;
        for (uint32_t channel = 0; channel < input->channel_count; ++channel) {
            double channelPeak = 0.0;
            if (ebur128_true_peak(state, channel, &channelPeak) != EBUR128_SUCCESS) {
                ebur128_destroy(&state);
                return fail(PARSO_STATUS_INTERNAL, "true peak measurement failed");
            }
            peak = std::max(peak, channelPeak);
        }
        double range = 0.0;
        if (ebur128_loudness_range(state, &range) != EBUR128_SUCCESS ||
            !std::isfinite(range) || range < 0.0) {
            range = 0.0;
        }
        ebur128_destroy(&state);
        result->integrated_lufs = integrated;
        result->true_peak_dbtp = peak > 0.0 ? 20.0 * std::log10(peak) : -HUGE_VAL;
        result->gain_to_target_db = options->target_lufs - integrated;
        result->loudness_range_lu = range;
        lastError = "ok";
        return PARSO_STATUS_OK;
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while measuring loudness");
    }
}

PARSO_API parso_status_t parso_analysis_options_init(parso_analysis_options_t *options) {
    if (!options) return fail(PARSO_STATUS_INVALID_ARGUMENT, "analysis options are null");
    std::memset(options, 0, sizeof(*options));
    options->size = sizeof(*options);
    options->abi_version = PARSO_ABI_VERSION;
    options->hop_frames = 256;
    options->min_bpm = 60;
    options->max_bpm = 190;
    return PARSO_STATUS_OK;
}

PARSO_API parso_status_t parso_analysis_result_init(parso_analysis_result_t *result) {
    if (!result) return fail(PARSO_STATUS_INVALID_ARGUMENT, "analysis result is null");
    std::memset(result, 0, sizeof(*result));
    result->size = sizeof(*result);
    result->abi_version = PARSO_ABI_VERSION;
    return PARSO_STATUS_OK;
}

PARSO_API parso_status_t parso_analysis_measure(
    const parso_pcm_buffer_t *input, const parso_analysis_options_t *options,
    parso_analysis_result_t *result
) {
    try {
        const parso_status_t resultStatus = validateAnalysisResult(result);
        if (resultStatus != PARSO_STATUS_OK) return resultStatus;
        const parso_status_t inputStatus = validatePCMBuffer(input);
        if (inputStatus != PARSO_STATUS_OK) return inputStatus;
        const parso_status_t optionsStatus = validateAnalysisOptions(options);
        if (optionsStatus != PARSO_STATUS_OK) return optionsStatus;
        if (input->frames == 0) return fail(PARSO_STATUS_INVALID_ARGUMENT, "analysis input is empty");

        const uint32_t hop = options->hop_frames == 0 ? 256u : options->hop_frames;
        const uint32_t minBpm = options->min_bpm == 0 ? 60u : options->min_bpm;
        const uint32_t maxBpm = options->max_bpm == 0 ? 190u : options->max_bpm;
        double sumSquares = 0.0;
        double peak = 0.0;
        const uint64_t sampleCount = input->frames * input->channel_count;
        for (uint64_t index = 0; index < sampleCount; ++index) {
            const double sample = std::isfinite(input->samples[index])
                ? static_cast<double>(input->samples[index]) : 0.0;
            sumSquares += sample * sample;
            peak = std::max(peak, std::abs(sample));
        }

        const uint64_t envelopeCount = (input->frames + hop - 1u) / hop;
        std::vector<double> envelope(static_cast<size_t>(envelopeCount), 0.0);
        for (uint64_t block = 0; block < envelopeCount; ++block) {
            const uint64_t start = block * hop;
            const uint64_t end = std::min<uint64_t>(input->frames, start + hop);
            double energy = 0.0;
            for (uint64_t frame = start; frame < end; ++frame) {
                double magnitude = 0.0;
                for (uint32_t channel = 0; channel < input->channel_count; ++channel) {
                    const float raw = input->samples[frame * input->channel_count + channel];
                    magnitude += std::abs(std::isfinite(raw) ? static_cast<double>(raw) : 0.0);
                }
                energy += magnitude / static_cast<double>(input->channel_count);
            }
            envelope[static_cast<size_t>(block)] = energy / static_cast<double>(end - start);
        }

        std::vector<double> onset(envelope.size(), 0.0);
        for (size_t index = 1; index < envelope.size(); ++index) {
            onset[index] = std::max(0.0, envelope[index] - envelope[index - 1]);
        }
        double bestScore = 0.0;
        double bestBpm = 0.0;
        for (uint32_t bpmTimesTwo = minBpm * 2u; bpmTimesTwo <= maxBpm * 2u; ++bpmTimesTwo) {
            const double bpm = static_cast<double>(bpmTimesTwo) * 0.5;
            const uint64_t lag = std::max<uint64_t>(1u, static_cast<uint64_t>(std::llround(
                static_cast<double>(input->sample_rate_hz) * 60.0 /
                (bpm * static_cast<double>(hop)))));
            if (lag >= onset.size()) continue;
            double score = 0.0;
            double energyA = 0.0;
            double energyB = 0.0;
            for (size_t index = static_cast<size_t>(lag); index < onset.size(); ++index) {
                const double a = onset[index];
                const double b = onset[index - static_cast<size_t>(lag)];
                score += a * b;
                energyA += a * a;
                energyB += b * b;
            }
            if (energyA > 0.0 && energyB > 0.0) {
                score /= std::sqrt(energyA * energyB);
                if (score > bestScore) {
                    bestScore = score;
                    bestBpm = bpm;
                }
            }
        }

        result->duration_seconds = static_cast<double>(input->frames) /
                                   static_cast<double>(input->sample_rate_hz);
        result->rms = std::sqrt(sumSquares / static_cast<double>(sampleCount));
        result->peak = peak;
        result->bpm = bestBpm;
        result->bpm_confidence = bestScore;
        lastError = "ok";
        return PARSO_STATUS_OK;
    } catch (const std::bad_alloc &) {
        return fail(PARSO_STATUS_OUT_OF_MEMORY, "analysis allocation failed");
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while measuring analysis");
    }
}
