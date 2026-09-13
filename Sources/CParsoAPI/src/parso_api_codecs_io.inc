PARSO_API parso_status_t parso_codec_read(
    const uint8_t *data, uint64_t sizeBytes, uint32_t codec,
    const parso_codec_options_t *options, parso_pcm_buffer_t *outBuffer
) {
    try {
        const parso_status_t outputStatus = validateEmptyPCMBuffer(outBuffer);
        if (outputStatus != PARSO_STATUS_OK) return outputStatus;
        const parso_status_t optionsStatus = validateCodecOptions(options);
        if (optionsStatus != PARSO_STATUS_OK) return optionsStatus;
        if (!validCodec(codec) || !data || sizeBytes == 0 ||
            sizeBytes > std::numeric_limits<size_t>::max()) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "codec input is invalid");
        }
        if (codec == PARSO_CODEC_WAV)
            return parso_wav_read(data, sizeBytes, outBuffer);
#if defined(PARSO_CODEC_BRIDGES_AVAILABLE)
        if (sizeBytes > static_cast<uint64_t>(INT_MAX))
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "codec input is too large");
        if (codec == PARSO_CODEC_FLAC) {
            int32_t *decoded = nullptr;
            uint64_t frames = 0;
            uint32_t channels = 0;
            uint32_t sampleRate = 0;
            uint32_t bits = 0;
            const int status = parso_flac_decode_memory(
                data, sizeBytes, &decoded, &frames, &channels, &sampleRate, &bits
            );
            if (status != 0 || !decoded || channels < 1 || channels > 2 ||
                sampleRate == 0 || frames == 0 || !validBits(bits)) {
                parso_flac_free(decoded);
                return fail(PARSO_STATUS_INVALID_ARGUMENT,
                            "FLAC input is malformed or unsupported");
            }
            const parso_status_t copyStatus = copyIntegerPCM(
                decoded, frames * channels, sampleRate, channels, bits, outBuffer
            );
            parso_flac_free(decoded);
            if (copyStatus == PARSO_STATUS_OK) lastError = "ok";
            return copyStatus;
        }
        if (codec == PARSO_CODEC_OGG_VORBIS) {
            float *decoded = nullptr;
            uint64_t frames = 0;
            uint32_t channels = 0;
            uint32_t sampleRate = 0;
            const int status = parso_vorbis_decode_memory(
                data, sizeBytes, &decoded, &frames, &channels, &sampleRate
            );
            if (status != 0 || !decoded || channels < 1 || channels > 2 ||
                sampleRate == 0 || frames == 0) {
                parso_vorbis_free(decoded);
                return fail(PARSO_STATUS_INVALID_ARGUMENT,
                            "Ogg Vorbis input is malformed or unsupported");
            }
            const parso_status_t copyStatus = copyPCM(
                decoded, frames * channels, sampleRate, channels, outBuffer
            );
            parso_vorbis_free(decoded);
            if (copyStatus == PARSO_STATUS_OK) lastError = "ok";
            return copyStatus;
        }
        int sampleRate = 0;
        int channels = 0;
        int frames = 0;
        float *decoded = static_cast<float *>(glint_decode_audio(
            data, static_cast<int>(sizeBytes), &sampleRate, &channels, &frames
        ));
        if (!decoded || sampleRate <= 0 || channels < 1 || channels > 2 || frames <= 0) {
            glint_free(decoded);
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "codec input is malformed or unsupported");
        }
        const parso_status_t status = copyPCM(
            decoded, static_cast<uint64_t>(frames) * static_cast<uint32_t>(channels),
            static_cast<uint32_t>(sampleRate), static_cast<uint32_t>(channels), outBuffer
        );
        glint_free(decoded);
        if (status == PARSO_STATUS_OK) lastError = "ok";
        return status;
#else
        (void)codec;
        return fail(PARSO_STATUS_UNSUPPORTED, "codec bridges are unavailable");
#endif
    } catch (const std::bad_alloc &) {
        return fail(PARSO_STATUS_OUT_OF_MEMORY, "codec decode allocation failed");
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while reading codec data");
    }
}

PARSO_API parso_status_t parso_codec_write(
    const parso_pcm_buffer_t *input, uint32_t codec,
    const parso_codec_options_t *options, parso_bytes_t *outBytes
) {
    try {
        const parso_status_t outputStatus = validateEmptyBytes(outBytes);
        if (outputStatus != PARSO_STATUS_OK) return outputStatus;
        const parso_status_t inputStatus = validatePCMBuffer(input);
        if (inputStatus != PARSO_STATUS_OK) return inputStatus;
        const parso_status_t optionsStatus = validateCodecOptions(options);
        if (optionsStatus != PARSO_STATUS_OK) return optionsStatus;
        if (!validCodec(codec))
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "codec selector is invalid");
        if (codec == PARSO_CODEC_WAV)
            return parso_wav_write(input, options->bits_per_sample,
                                   options->wav_is_float, outBytes);
#if defined(PARSO_CODEC_BRIDGES_AVAILABLE)
        if (input->frames > static_cast<uint64_t>(INT_MAX) ||
            input->sample_rate_hz > static_cast<uint32_t>(INT_MAX)) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "codec input is too large");
        }
        const uint64_t sampleCount = input->frames * input->channel_count;
        if (codec == PARSO_CODEC_FLAC) {
            const uint32_t bits = options->bits_per_sample == 0
                ? 16 : options->bits_per_sample;
            if (bits != 16 && bits != 24 && bits != 32)
                return fail(PARSO_STATUS_INVALID_ARGUMENT, "FLAC bit depth is invalid");
            if (sampleCount > std::numeric_limits<size_t>::max() / sizeof(int32_t))
                return fail(PARSO_STATUS_INVALID_ARGUMENT, "codec input is too large");
            std::vector<int32_t> quantized(static_cast<size_t>(sampleCount));
            const double maximum = std::ldexp(1.0, static_cast<int>(bits) - 1) - 1.0;
            const double minimum = -std::ldexp(1.0, static_cast<int>(bits) - 1);
            for (size_t index = 0; index < quantized.size(); ++index) {
                double sample = std::isfinite(input->samples[index])
                    ? static_cast<double>(input->samples[index]) : 0.0;
                sample = std::max(-1.0, std::min(1.0, sample));
                double scaled = sample * maximum;
                if (sample < 0.0) scaled = sample * -minimum;
                int64_t value = static_cast<int64_t>(scaled + (scaled >= 0.0 ? 0.5 : -0.5));
                if (value > static_cast<int64_t>(maximum)) value = static_cast<int64_t>(maximum);
                if (static_cast<double>(value) < minimum) value = static_cast<int64_t>(minimum);
                quantized[index] = static_cast<int32_t>(value);
            }
            uint8_t *encoded = nullptr;
            uint64_t encodedSize = 0;
            const int status = parso_flac_encode_memory(
                quantized.empty() ? nullptr : quantized.data(), input->frames,
                input->channel_count, bits, input->sample_rate_hz,
                options->compression_level, &encoded, &encodedSize
            );
            if (status != 0 || !encoded || encodedSize == 0) {
                parso_flac_free(encoded);
                return fail(PARSO_STATUS_INTERNAL, "FLAC encode failed");
            }
            outBytes->data = encoded;
            outBytes->size_bytes = encodedSize;
            lastError = "ok";
            return PARSO_STATUS_OK;
        }
        if (codec == PARSO_CODEC_OGG_VORBIS) {
            const uint32_t bitrate = options->bitrate_kbps == 0 ? 192
                : options->bitrate_kbps;
            uint8_t *encoded = nullptr;
            uint64_t encodedSize = 0;
            const int status = parso_vorbis_encode_memory(
                input->samples, input->frames, input->channel_count,
                input->sample_rate_hz, bitrate, &encoded, &encodedSize
            );
            if (status != 0 || !encoded || encodedSize == 0) {
                parso_vorbis_free(encoded);
                return fail(PARSO_STATUS_INTERNAL, "Ogg Vorbis encode failed");
            }
            outBytes->data = encoded;
            outBytes->size_bytes = encodedSize;
            lastError = "ok";
            return PARSO_STATUS_OK;
        }
        const int format = codec == PARSO_CODEC_OPUS ? GLINT_ENC_OPUS
            : codec == PARSO_CODEC_MP3 ? GLINT_ENC_MP3 : GLINT_ENC_AAC;
        const int bitrate = options->bitrate_kbps == 0 ? 192
            : static_cast<int>(options->bitrate_kbps);
        const int vbrQuality = options->vbr_quality == PARSO_CODEC_VBR_CBR
            ? -1 : static_cast<int>(options->vbr_quality);
        int encodedSize = 0;
        uint8_t *encoded = glint_encode_audio(
            input->samples, static_cast<int>(input->frames),
            static_cast<int>(input->channel_count), static_cast<int>(input->sample_rate_hz),
            format, bitrate, vbrQuality, static_cast<int>(options->quality), &encodedSize
        );
        if (!encoded || encodedSize <= 0) {
            glint_free(encoded);
            return fail(PARSO_STATUS_INTERNAL, "codec encode failed");
        }
        outBytes->data = encoded;
        outBytes->size_bytes = static_cast<uint64_t>(encodedSize);
        lastError = "ok";
        return PARSO_STATUS_OK;
#else
        return fail(PARSO_STATUS_UNSUPPORTED, "codec bridges are unavailable");
#endif
    } catch (const std::bad_alloc &) {
        return fail(PARSO_STATUS_OUT_OF_MEMORY, "codec encode allocation failed");
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while writing codec data");
    }
}

PARSO_API parso_status_t parso_wav_read(
    const uint8_t *data, uint64_t sizeBytes, parso_pcm_buffer_t *outBuffer
) {
    try {
        const parso_status_t outputStatus = validateEmptyPCMBuffer(outBuffer);
        if (outputStatus != PARSO_STATUS_OK) return outputStatus;
        if (!data || sizeBytes == 0 || sizeBytes > std::numeric_limits<size_t>::max()) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "WAV input is empty or too large");
        }
        std::vector<float> samples;
        int sampleRate = 0;
        int channels = 0;
        if (!glint::wav_read(data, static_cast<size_t>(sizeBytes), samples,
                             sampleRate, channels)) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "WAV input is malformed or unsupported");
        }
        if (sampleRate <= 0 || channels < 1 || channels > 2) {
            return fail(PARSO_STATUS_UNSUPPORTED, "WAV format exceeds the native PCM contract");
        }
        const parso_status_t copyStatus = copyPCM(
            samples, static_cast<uint32_t>(sampleRate), static_cast<uint32_t>(channels), outBuffer
        );
        if (copyStatus == PARSO_STATUS_OK) lastError = "ok";
        return copyStatus;
    } catch (const std::bad_alloc &) {
        return fail(PARSO_STATUS_OUT_OF_MEMORY, "WAV decode allocation failed");
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while reading WAV");
    }
}

PARSO_API parso_status_t parso_pcm_read(
    const uint8_t *data, uint64_t sizeBytes, uint32_t sampleRateHz,
    uint32_t channelCount, uint32_t bitsPerSample, parso_pcm_buffer_t *outBuffer
) {
    try {
        const parso_status_t outputStatus = validateEmptyPCMBuffer(outBuffer);
        if (outputStatus != PARSO_STATUS_OK) return outputStatus;
        if (!data || sizeBytes == 0 || sizeBytes > std::numeric_limits<size_t>::max() ||
            !finitePositive(sampleRateHz) || sampleRateHz > static_cast<uint32_t>(INT_MAX) ||
            channelCount < 1 || channelCount > 2 ||
            !validBits(bitsPerSample)) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "raw PCM arguments are invalid");
        }
        std::vector<float> samples;
        if (!glint::pcm_read(data, static_cast<size_t>(sizeBytes),
                             static_cast<int>(sampleRateHz), static_cast<int>(channelCount),
                             static_cast<int>(bitsPerSample), samples)) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "raw PCM input is malformed");
        }
        const parso_status_t copyStatus = copyPCM(samples, sampleRateHz, channelCount, outBuffer);
        if (copyStatus == PARSO_STATUS_OK) lastError = "ok";
        return copyStatus;
    } catch (const std::bad_alloc &) {
        return fail(PARSO_STATUS_OUT_OF_MEMORY, "raw PCM decode allocation failed");
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while reading raw PCM");
    }
}

PARSO_API parso_status_t parso_wav_write(
    const parso_pcm_buffer_t *buffer, uint32_t bitsPerSample,
    uint32_t isFloat, parso_bytes_t *outBytes
) {
    try {
        const parso_status_t outputStatus = validateEmptyBytes(outBytes);
        if (outputStatus != PARSO_STATUS_OK) return outputStatus;
        const parso_status_t bufferStatus = validatePCMBuffer(buffer);
        if (bufferStatus != PARSO_STATUS_OK) return bufferStatus;
        if (!validWavBits(bitsPerSample, isFloat)) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "unsupported WAV sample format");
        }
        const uint64_t bytesPerSample = bitsPerSample / 8;
        const uint64_t samples = buffer->frames * buffer->channel_count;
        if (buffer->sample_rate_hz > static_cast<uint32_t>(INT_MAX) ||
            !multiplicationFits(samples, bytesPerSample, UINT32_MAX - 36u) ||
            buffer->frames > static_cast<uint64_t>(std::numeric_limits<long>::max())) {
            return fail(PARSO_STATUS_INVALID_ARGUMENT, "WAV output is too large");
        }
        float zero = 0.0f;
        const float *samplesPointer = buffer->samples ? buffer->samples : &zero;
        const std::vector<uint8_t> bytes = glint::wav_write(
            samplesPointer, static_cast<long>(buffer->frames),
            static_cast<int>(buffer->channel_count), static_cast<int>(buffer->sample_rate_hz),
            static_cast<int>(bitsPerSample), isFloat != 0
        );
        const parso_status_t copyStatus = copyBytes(bytes, outBytes);
        if (copyStatus == PARSO_STATUS_OK) lastError = "ok";
        return copyStatus;
    } catch (const std::bad_alloc &) {
        return fail(PARSO_STATUS_OUT_OF_MEMORY, "WAV encode allocation failed");
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while writing WAV");
    }
}

PARSO_API parso_status_t parso_pcm_write(
    const parso_pcm_buffer_t *buffer, uint32_t bitsPerSample, parso_bytes_t *outBytes
) {
    try {
        const parso_status_t outputStatus = validateEmptyBytes(outBytes);
        if (outputStatus != PARSO_STATUS_OK) return outputStatus;
        const parso_status_t sizeStatus = validateWriteSize(
            buffer, bitsPerSample, 0, static_cast<uint64_t>(std::numeric_limits<size_t>::max())
        );
        if (sizeStatus != PARSO_STATUS_OK) return sizeStatus;
        const uint64_t sampleCount = buffer->frames * buffer->channel_count;
        const size_t byteCount = static_cast<size_t>(sampleCount * (bitsPerSample / 8));
        std::vector<uint8_t> bytes;
        bytes.reserve(byteCount);
        for (uint64_t index = 0; index < sampleCount; ++index) {
            appendPCMInteger(bytes, buffer->samples[index], bitsPerSample);
        }
        const parso_status_t copyStatus = copyBytes(bytes, outBytes);
        if (copyStatus == PARSO_STATUS_OK) lastError = "ok";
        return copyStatus;
    } catch (const std::bad_alloc &) {
        return fail(PARSO_STATUS_OUT_OF_MEMORY, "raw PCM encode allocation failed");
    } catch (...) {
        return fail(PARSO_STATUS_INTERNAL, "exception caught while writing raw PCM");
    }
}
