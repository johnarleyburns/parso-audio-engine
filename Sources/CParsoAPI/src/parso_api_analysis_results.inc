PARSO_API parso_status_t parso_key_options_init(parso_key_options_t *options) {
    if (!options) return fail(PARSO_STATUS_INVALID_ARGUMENT, "key options are null");
    std::memset(options, 0, sizeof(*options));
    options->size = sizeof(*options);
    options->abi_version = PARSO_ABI_VERSION;
    options->window_frames = 8192;
    options->hop_frames = 4096;
    options->min_midi = 36;
    options->max_midi = 96;
    return PARSO_STATUS_OK;
}

PARSO_API parso_status_t parso_key_result_init(parso_key_result_t *result) {
    if (!result) return fail(PARSO_STATUS_INVALID_ARGUMENT, "key result is null");
    std::memset(result, 0, sizeof(*result));
    result->size = sizeof(*result);
    result->abi_version = PARSO_ABI_VERSION;
    return PARSO_STATUS_OK;
}

PARSO_API parso_status_t parso_key_measure(
    const parso_pcm_buffer_t *input, const parso_key_options_t *options,
    parso_key_result_t *result
) {
    try {
        const parso_status_t resultStatus = validateKeyResult(result);
        if (resultStatus != PARSO_STATUS_OK) return resultStatus;
        const parso_status_t inputStatus = validatePCMBuffer(input);
        if (inputStatus != PARSO_STATUS_OK) return inputStatus;
        const parso_status_t optionsStatus = validateKeyOptions(options);
        if (optionsStatus != PARSO_STATUS_OK) return optionsStatus;
        if (input->frames == 0) return fail(PARSO_STATUS_INVALID_ARGUMENT, "key input is empty");

        const uint32_t requestedWindow = options->window_frames == 0 ? 8192u : options->window_frames;
        uint32_t window = static_cast<uint32_t>(std::min<uint64_t>(
            input->frames, requestedWindow));
        const uint32_t hop = options->hop_frames == 0 ? 4096u : options->hop_frames;
        const uint32_t minMidi = options->min_midi == 0 ? 36u : options->min_midi;
        const uint32_t maxMidi = options->max_midi == 0 ? 96u : options->max_midi;
        if (window < 32 || minMidi > maxMidi) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "key input or MIDI range is invalid");
        }

        // This is the portable counterpart to Swift's STFT/HPCP path. It
        // computes a dependency-free radix-2 FFT, folds each positive-frequency
        // bin onto its nearest pitch class, and correlates the aggregate
        // against the normative Krumhansl-Schmuckler profiles. The service is
        // offline and therefore does not affect RT safety.
        static constexpr double majorProfile[12] = {
            6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19,
            2.39, 3.66, 2.29, 2.88
        };
        static constexpr double minorProfile[12] = {
            6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75,
            3.98, 2.69, 3.34, 3.17
        };
        // A short final window is still useful for callers analyzing a clip
        // shorter than the nominal STFT size; keep the FFT power-of-two.
        while ((window & (window - 1u)) != 0u) window &= window - 1u;
        if (window < 32) return fail(PARSO_STATUS_INVALID_ARGUMENT, "key FFT window is too small");
        const uint32_t fftSize = window <= 4096u ? window * 4u : window;
        std::vector<double> real(fftSize, 0.0);
        std::vector<double> imaginary(fftSize, 0.0);
        double aggregate[12] = {};
        uint64_t frameCount = 0;
        const uint64_t lastStart = input->frames > window ? input->frames - window : 0;
        for (uint64_t start = 0; start <= lastStart; start += hop) {
            double chroma[12] = {};
            double chromaNorm = 0.0;
            std::fill(real.begin(), real.end(), 0.0);
            std::fill(imaginary.begin(), imaginary.end(), 0.0);
            for (uint32_t offset = 0; offset < window; ++offset) {
                const uint64_t frame = start + offset;
                double sample = 0.0;
                for (uint32_t channel = 0; channel < input->channel_count; ++channel) {
                    const float raw = input->samples[frame * input->channel_count + channel];
                    sample += std::isfinite(raw) ? static_cast<double>(raw) : 0.0;
                }
                sample /= static_cast<double>(input->channel_count);
                real[offset] = sample * (0.5 - 0.5 * std::cos(
                    2.0 * kPi * static_cast<double>(offset) / static_cast<double>(window)));
                imaginary[offset] = 0.0;
            }
            for (uint32_t index = 1, reversed = 0; index < fftSize; ++index) {
                uint32_t bit = fftSize >> 1u;
                for (; reversed & bit; bit >>= 1u) reversed ^= bit;
                reversed ^= bit;
                if (index < reversed) {
                    std::swap(real[index], real[reversed]);
                    std::swap(imaginary[index], imaginary[reversed]);
                }
            }
            for (uint32_t length = 2; length <= fftSize; length <<= 1u) {
                const double angle = -2.0 * kPi / static_cast<double>(length);
                const double stepCos = std::cos(angle);
                const double stepSin = std::sin(angle);
                for (uint32_t base = 0; base < fftSize; base += length) {
                    double oscillatorCos = 1.0;
                    double oscillatorSin = 0.0;
                    const uint32_t half = length / 2u;
                    for (uint32_t offset = 0; offset < half; ++offset) {
                        const uint32_t left = base + offset;
                        const uint32_t right = left + half;
                        const double productReal = oscillatorCos * real[right] -
                                                   oscillatorSin * imaginary[right];
                        const double productImaginary = oscillatorCos * imaginary[right] +
                                                        oscillatorSin * real[right];
                        const double leftReal = real[left];
                        const double leftImaginary = imaginary[left];
                        real[left] = leftReal + productReal;
                        imaginary[left] = leftImaginary + productImaginary;
                        real[right] = leftReal - productReal;
                        imaginary[right] = leftImaginary - productImaginary;
                        const double nextCos = oscillatorCos * stepCos - oscillatorSin * stepSin;
                        oscillatorSin = oscillatorSin * stepCos + oscillatorCos * stepSin;
                        oscillatorCos = nextCos;
                    }
                }
            }
            for (uint32_t bin = 1; bin <= fftSize / 2u; ++bin) {
                const double frequency = static_cast<double>(bin) *
                                         static_cast<double>(input->sample_rate_hz) /
                                         static_cast<double>(fftSize);
                if (frequency < 20.0 || frequency > 8000.0) continue;
                const double midiValue = 69.0 + 12.0 * std::log2(frequency / 440.0);
                const int midi = static_cast<int>(std::llround(midiValue));
                if (midi < static_cast<int>(minMidi) || midi > static_cast<int>(maxMidi)) continue;
                const double magnitude = std::sqrt(real[bin] * real[bin] +
                                                   imaginary[bin] * imaginary[bin]);
                chroma[static_cast<uint32_t>(midi) % 12u] += magnitude;
                chromaNorm += magnitude;
            }
            if (chromaNorm > 1.0e-12) {
                for (double &value : chroma) value /= chromaNorm;
                for (size_t index = 0; index < 12; ++index) aggregate[index] += chroma[index];
                ++frameCount;
            }
            if (start > lastStart - std::min<uint64_t>(hop, lastStart)) break;
        }
        if (frameCount == 0) return fail(PARSO_STATUS_INVALID_ARGUMENT, "key spectrum is empty");
        for (double &value : aggregate) value /= static_cast<double>(frameCount);

        uint32_t bestTonic = 0;
        uint32_t bestMinor = 0;
        double bestScore = -std::numeric_limits<double>::infinity();
        double secondBest = -std::numeric_limits<double>::infinity();
        for (uint32_t tonic = 0; tonic < 12; ++tonic) {
            double rotated[12] = {};
            for (size_t index = 0; index < 12; ++index) rotated[index] = aggregate[(tonic + index) % 12];
            for (uint32_t minor = 0; minor < 2; ++minor) {
                const double score = keyProfileCorrelation(
                    rotated, minor == 0 ? majorProfile : minorProfile);
                if (score > bestScore) {
                    secondBest = bestScore;
                    bestScore = score;
                    bestTonic = tonic;
                    bestMinor = minor;
                } else if (score > secondBest) {
                    secondBest = score;
                }
            }
        }
        const double margin = std::max(0.0, bestScore - secondBest);
        result->tonic_pitch_class = bestTonic;
        result->is_minor = bestMinor;
        result->camelot_number = bestMinor == 1
            ? camelotMinorNumber(bestTonic)
            : camelotMinorNumber((bestTonic + 9u) % 12u);
        result->camelot_letter = bestMinor;
        result->confidence = std::min(1.0, margin / 0.2);
        lastError = "ok";
        return PARSO_STATUS_OK;
    } catch (const std::bad_alloc &) {
        return fail(PARSO_STATUS_OUT_OF_MEMORY, "key analysis allocation failed");
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while measuring key");
    }
}

PARSO_API parso_status_t parso_structure_options_init(
    parso_structure_options_t *options) {
    if (!options) return fail(PARSO_STATUS_INVALID_ARGUMENT, "structure options are null");
    std::memset(options, 0, sizeof(*options));
    options->size = sizeof(*options);
    options->abi_version = PARSO_ABI_VERSION;
    options->bpm = 120.0;
    options->max_sections = 256;
    return PARSO_STATUS_OK;
}

PARSO_API parso_status_t parso_structure_measure(
    const parso_pcm_buffer_t *input, const parso_structure_options_t *options,
    parso_structure_section_t *sections, uint32_t capacity, uint32_t *out_count
) {
    try {
        if (!out_count) return fail(PARSO_STATUS_INVALID_ARGUMENT, "structure count is null");
        *out_count = 0;
        const parso_status_t inputStatus = validatePCMBuffer(input);
        if (inputStatus != PARSO_STATUS_OK) return inputStatus;
        const parso_status_t optionsStatus = validateStructureOptions(options);
        if (optionsStatus != PARSO_STATUS_OK) return optionsStatus;
        if (!sections && capacity != 0) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "structure output is null");
        }
        if (input->frames == 0) return PARSO_STATUS_OK;

        const double bpm = options->bpm == 0.0 ? 120.0 : options->bpm;
        const double beatPeriod = 60.0 / bpm;
        const double duration = static_cast<double>(input->frames) /
                                static_cast<double>(input->sample_rate_hz);
        const uint64_t beatCount = std::max<uint64_t>(
            1u, static_cast<uint64_t>(std::ceil(duration / beatPeriod)));
        struct Feature { double values[5]; };
        std::vector<Feature> features;
        features.reserve(static_cast<size_t>(beatCount));
        for (uint64_t beat = 0; beat < beatCount; ++beat) {
            const uint64_t start = std::min<uint64_t>(input->frames,
                static_cast<uint64_t>(static_cast<double>(beat) * beatPeriod * input->sample_rate_hz));
            const uint64_t end = std::min<uint64_t>(input->frames,
                std::max<uint64_t>(start + 1u,
                    static_cast<uint64_t>(static_cast<double>(beat + 1u) * beatPeriod *
                                          input->sample_rate_hz)));
            if (start >= end) continue;
            double energy = 0.0;
            double low = 0.0;
            double mid = 0.0;
            double high = 0.0;
            uint64_t crossings = 0;
            double previous = 0.0;
            for (uint64_t frame = start; frame < end; ++frame) {
                double value = 0.0;
                for (uint32_t channel = 0; channel < input->channel_count; ++channel) {
                    const float raw = input->samples[frame * input->channel_count + channel];
                    value += std::isfinite(raw) ? static_cast<double>(raw) : 0.0;
                }
                value /= static_cast<double>(input->channel_count);
                energy += value * value;
                const double magnitude = std::abs(value);
                if (magnitude > 0.35) high += value * value;
                else if (magnitude > 0.1) mid += value * value;
                else low += value * value;
                if (frame > start && ((value >= 0.0) != (previous >= 0.0))) ++crossings;
                previous = value;
            }
            const double count = static_cast<double>(end - start);
            features.push_back({{
                std::sqrt(energy / count), low / count, mid / count,
                high / count, static_cast<double>(crossings) / count
            }});
        }
        if (features.empty()) return PARSO_STATUS_OK;
        double maximumEnergy = 0.0;
        for (const Feature &feature : features) maximumEnergy = std::max(maximumEnergy, feature.values[0]);
        auto cosineDistance = [](const Feature &lhs, const Feature &rhs) noexcept {
            double dot = 0.0;
            double lhsNorm = 0.0;
            double rhsNorm = 0.0;
            for (size_t index = 0; index < 5; ++index) {
                dot += lhs.values[index] * rhs.values[index];
                lhsNorm += lhs.values[index] * lhs.values[index];
                rhsNorm += rhs.values[index] * rhs.values[index];
            }
            const double denominator = std::sqrt(lhsNorm * rhsNorm);
            return denominator > 0.0 ? 1.0 - dot / denominator : 1.0;
        };
        std::vector<uint32_t> boundaries{0};
        uint32_t lastBoundary = 0;
        for (uint32_t index = 1; index < features.size(); ++index) {
            const double novelty = cosineDistance(features[index - 1], features[index]);
            const double nextNovelty = index + 1 == features.size()
                ? novelty : cosineDistance(features[index], features[index + 1]);
            const double energyChange = std::abs(
                features[index].values[0] - features[index - 1].values[0]);
            if (index + 1 == features.size() || novelty >= nextNovelty) {
                if (energyChange > std::max(0.02 * maximumEnergy, 0.08) &&
                    index - lastBoundary >= 4) {
                    boundaries.push_back(index);
                    lastBoundary = index;
                }
            }
        }
        if (boundaries.size() == 1 && features.size() > 8) {
            if (features.size() > std::numeric_limits<uint32_t>::max()) {
                return fail(PARSO_STATUS_INVALID_SIZE, "structure feature count is too large");
            }
            const size_t quarter = std::max<size_t>(1, features.size() / 4);
            boundaries.push_back(static_cast<uint32_t>(quarter));
            const size_t midpoint = std::min(features.size() - 1, quarter * 2);
            boundaries.push_back(static_cast<uint32_t>(midpoint));
        }
        std::sort(boundaries.begin(), boundaries.end());
        boundaries.erase(std::unique(boundaries.begin(), boundaries.end()), boundaries.end());
        const uint32_t maximumSections = options->max_sections == 0 ? 256u : options->max_sections;
        if (boundaries.size() > maximumSections) {
            return fail(PARSO_STATUS_INVALID_SIZE, "structure result exceeds maximum sections");
        }
        *out_count = static_cast<uint32_t>(boundaries.size());
        if (capacity < *out_count) return fail(PARSO_STATUS_INVALID_SIZE, "structure output is too small");
        for (size_t position = 0; position < boundaries.size(); ++position) {
            const uint32_t beat = boundaries[position];
            const double energy = features[std::min<size_t>(beat, features.size() - 1)].values[0];
            uint32_t kind = 7; // unknown
            if (position == 0) kind = 0; // intro
            else if (energy > maximumEnergy * 0.75) kind = 2; // drop
            else if (energy < maximumEnergy * 0.25) kind = 5; // breakdown
            sections[position].start_seconds = std::min(
                duration, static_cast<double>(beat) * beatPeriod);
            sections[position].kind = kind;
            sections[position].bar = beat / 4u + 1u;
            sections[position].energy = energy;
            sections[position].confidence = std::min(1.0,
                std::abs(energy - (position == 0 ? 0.0 :
                    features[boundaries[position - 1]].values[0])) /
                std::max(0.08, maximumEnergy));
        }
        lastError = "ok";
        return PARSO_STATUS_OK;
    } catch (const std::bad_alloc &) {
        return fail(PARSO_STATUS_OUT_OF_MEMORY, "structure analysis allocation failed");
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while measuring structure");
    }
}

PARSO_API parso_status_t parso_waveform_generate(
    const parso_pcm_buffer_t *input, uint32_t bucketCount,
    float *outMin, float *outMax
) {
    try {
        const parso_status_t inputStatus = validatePCMBuffer(input);
        if (inputStatus != PARSO_STATUS_OK) return inputStatus;
        if (input->frames == 0 || bucketCount == 0 || bucketCount > 1'000'000 ||
            !outMin || !outMax) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "waveform arguments are invalid");
        }
        for (uint32_t bucket = 0; bucket < bucketCount; ++bucket) {
            const uint64_t start = static_cast<uint64_t>(bucket) * input->frames / bucketCount;
            const uint64_t end = std::max<uint64_t>(start + 1,
                static_cast<uint64_t>(bucket + 1) * input->frames / bucketCount);
            float minimum = 1.0f;
            float maximum = -1.0f;
            for (uint64_t frame = start; frame < std::min(end, input->frames); ++frame) {
                double mono = 0.0;
                for (uint32_t channel = 0; channel < input->channel_count; ++channel) {
                    const float sample = input->samples[frame * input->channel_count + channel];
                    mono += std::isfinite(sample) ? static_cast<double>(sample) : 0.0;
                }
                const float value = static_cast<float>(mono / input->channel_count);
                minimum = std::min(minimum, value);
                maximum = std::max(maximum, value);
            }
            outMin[bucket] = minimum;
            outMax[bucket] = maximum;
        }
        lastError = "ok";
        return PARSO_STATUS_OK;
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while generating waveform");
    }
}
