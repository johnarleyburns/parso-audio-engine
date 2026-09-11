/*
 * parso.hpp — small move-only C++17 convenience wrapper over parso.h.
 * No STL or C++ types cross the public C ABI.
 */
#ifndef PARSO_HPP
#define PARSO_HPP

#include "parso.h"

#include <limits>
#include <vector>

namespace parso {

class Bytes final {
public:
    Bytes() noexcept { parso_bytes_init(&value_); }
    ~Bytes() { parso_bytes_release(&value_); }

    Bytes(const Bytes &) = delete;
    Bytes &operator=(const Bytes &) = delete;
    Bytes(Bytes &&other) noexcept : value_(other.value_) {
        other.value_.data = nullptr;
        other.value_.size_bytes = 0;
    }
    Bytes &operator=(Bytes &&other) noexcept {
        if (this != &other) {
            parso_bytes_release(&value_);
            value_ = other.value_;
            other.value_.data = nullptr;
            other.value_.size_bytes = 0;
        }
        return *this;
    }

    uint8_t *data() noexcept { return value_.data; }
    const uint8_t *data() const noexcept { return value_.data; }
    uint64_t size() const noexcept { return value_.size_bytes; }
    parso_bytes_t *cHandle() noexcept { return &value_; }

private:
    parso_bytes_t value_{};
};

class PcmBuffer final {
public:
    PcmBuffer() noexcept { parso_pcm_buffer_init(&value_); }
    ~PcmBuffer() { parso_pcm_buffer_release(&value_); }

    PcmBuffer(const PcmBuffer &) = delete;
    PcmBuffer &operator=(const PcmBuffer &) = delete;
    PcmBuffer(PcmBuffer &&other) noexcept : value_(other.value_) {
        other.value_.samples = nullptr;
        other.value_.frames = 0;
    }
    PcmBuffer &operator=(PcmBuffer &&other) noexcept {
        if (this != &other) {
            parso_pcm_buffer_release(&value_);
            value_ = other.value_;
            other.value_.samples = nullptr;
            other.value_.frames = 0;
        }
        return *this;
    }

    static parso_status_t readWav(const uint8_t *data, uint64_t size, PcmBuffer *out) noexcept {
        return out ? parso_wav_read(data, size, &out->value_) : PARSO_STATUS_INVALID_ARGUMENT;
    }

    static parso_status_t readPCM(const uint8_t *data, uint64_t size,
                                  uint32_t sampleRate, uint32_t channels,
                                  uint32_t bits, PcmBuffer *out) noexcept {
        return out ? parso_pcm_read(data, size, sampleRate, channels, bits, &out->value_)
                   : PARSO_STATUS_INVALID_ARGUMENT;
    }

    static parso_status_t readCodec(const uint8_t *data, uint64_t size,
                                    uint32_t codec,
                                    const parso_codec_options_t &options,
                                    PcmBuffer *out) noexcept {
        return out ? parso_codec_read(data, size, codec, &options, &out->value_)
                   : PARSO_STATUS_INVALID_ARGUMENT;
    }

    parso_status_t writeWav(uint32_t bits, bool isFloat, Bytes *out) const noexcept {
        return out ? parso_wav_write(&value_, bits, isFloat ? 1u : 0u, out->cHandle())
                   : PARSO_STATUS_INVALID_ARGUMENT;
    }

    parso_status_t writePCM(uint32_t bits, Bytes *out) const noexcept {
        return out ? parso_pcm_write(&value_, bits, out->cHandle())
                   : PARSO_STATUS_INVALID_ARGUMENT;
    }

    parso_status_t writeCodec(uint32_t codec, const parso_codec_options_t &options,
                              Bytes *out) const noexcept {
        return out ? parso_codec_write(&value_, codec, &options, out->cHandle())
                   : PARSO_STATUS_INVALID_ARGUMENT;
    }

    parso_status_t estimateKey(const parso_key_options_t &options,
                               parso_key_result_t *result) const noexcept {
        return parso_key_measure(&value_, &options, result);
    }

    parso_status_t measureStructure(const parso_structure_options_t &options,
                                    parso_structure_section_t *sections,
                                    uint32_t capacity, uint32_t *outCount) const noexcept {
        return parso_structure_measure(&value_, &options, sections, capacity, outCount);
    }

    const float *samples() const noexcept { return value_.samples; }
    uint64_t frames() const noexcept { return value_.frames; }
    uint32_t channels() const noexcept { return value_.channel_count; }
    uint32_t sampleRate() const noexcept { return value_.sample_rate_hz; }
    parso_pcm_buffer_t *cHandle() noexcept { return &value_; }
    const parso_pcm_buffer_t *cHandle() const noexcept { return &value_; }

private:
    parso_pcm_buffer_t value_{};
};

class Engine final {
public:
    Engine() noexcept = default;
    ~Engine() { close(); }

    Engine(const Engine &) = delete;
    Engine &operator=(const Engine &) = delete;

    Engine(Engine &&other) noexcept : handle_(other.handle_) {
        other.handle_ = nullptr;
    }

    Engine &operator=(Engine &&other) noexcept {
        if (this != &other) {
            close();
            handle_ = other.handle_;
            other.handle_ = nullptr;
        }
        return *this;
    }

    static parso_status_t create(const parso_engine_options_t &options, Engine *out) noexcept {
        if (!out) return PARSO_STATUS_INVALID_ARGUMENT;
        out->close();
        return parso_engine_create(&options, &out->handle_);
    }

    parso_status_t close() noexcept {
        return parso_engine_destroy(&handle_);
    }

    bool isOpen() const noexcept { return handle_ != nullptr; }

    parso_status_t setControl(const parso_control_t &control) noexcept {
        return parso_engine_set_control(handle_, &control);
    }

    parso_status_t setDeckBuffer(uint32_t deck, const parso_pcm_view_t &view) noexcept {
        return parso_engine_set_deck_buffer(handle_, deck, &view);
    }

    parso_status_t postCommand(const parso_command_t &command) noexcept {
        return parso_engine_post_command(handle_, &command);
    }

    parso_status_t render(const parso_output_view_t &output) noexcept {
        return parso_engine_render(handle_, &output);
    }

    parso_status_t getStats(parso_stats_t *stats) const noexcept {
        return parso_engine_get_stats(handle_, stats);
    }

    parso_status_t pollEvents(parso_event_t *events, uint32_t maxEvents,
                              uint32_t *outEvents) noexcept {
        return parso_engine_poll_events(handle_, events, maxEvents, outEvents);
    }

    parso_status_t setRecordActive(bool active) noexcept {
        return parso_engine_record_set_active(handle_, active ? 1u : 0u);
    }

    parso_status_t drainRecord(float *left, float *right, uint32_t maxFrames,
                               uint32_t *outFrames) noexcept {
        return parso_engine_record_drain(handle_, left, right, maxFrames, outFrames);
    }

    parso_status_t recordDroppedFrames(uint64_t *outFrames) const noexcept {
        return parso_engine_record_dropped_frames(handle_, outFrames);
    }

    parso_status_t resetRecord() noexcept {
        return parso_engine_record_reset(handle_);
    }

private:
    parso_engine_t *handle_ = nullptr;
};

/* Control-side recorder for stereo blocks drained from Engine. Encoding is
 * synchronous and must remain off the render thread. */
class MixRecorder final {
public:
    explicit MixRecorder(uint32_t sampleRateHz, uint32_t codec = PARSO_CODEC_WAV,
                         uint32_t bitrateKbps = 192, uint32_t quality = 0) noexcept
        : sampleRateHz_(sampleRateHz), codec_(codec), bitrateKbps_(bitrateKbps),
          quality_(quality) {}

    MixRecorder(const MixRecorder &) = delete;
    MixRecorder &operator=(const MixRecorder &) = delete;
    MixRecorder(MixRecorder &&) noexcept = default;
    MixRecorder &operator=(MixRecorder &&) noexcept = default;

    uint64_t frames() const noexcept {
        return static_cast<uint64_t>(samples_.size() / 2u);
    }

    parso_status_t append(const float *left, const float *right,
                          uint32_t frames) noexcept {
        if (!left || !right || frames == 0 || sampleRateHz_ == 0) {
            return PARSO_STATUS_INVALID_ARGUMENT;
        }
        const size_t frameCount = static_cast<size_t>(frames);
        if (frameCount > (std::numeric_limits<size_t>::max() - samples_.size()) / 2u) {
            return PARSO_STATUS_INVALID_SIZE;
        }
        const size_t oldSize = samples_.size();
        try {
            samples_.resize(oldSize + frameCount * 2u);
        } catch (...) {
            return PARSO_STATUS_OUT_OF_MEMORY;
        }
        for (size_t index = 0; index < frameCount; ++index) {
            samples_[oldSize + index * 2u] = left[index];
            samples_[oldSize + index * 2u + 1u] = right[index];
        }
        return PARSO_STATUS_OK;
    }

    parso_status_t appendEngine(Engine &engine, uint32_t maxFrames,
                                uint32_t *outFrames) noexcept {
        if (!outFrames || maxFrames == 0) return PARSO_STATUS_INVALID_ARGUMENT;
        *outFrames = 0;
        try {
            std::vector<float> left(maxFrames);
            std::vector<float> right(maxFrames);
            parso_status_t status = engine.drainRecord(left.data(), right.data(),
                                                        maxFrames, outFrames);
            if (status != PARSO_STATUS_OK) return status;
            if (*outFrames == 0) return PARSO_STATUS_OK;
            return append(left.data(), right.data(), *outFrames);
        } catch (...) {
            return PARSO_STATUS_OUT_OF_MEMORY;
        }
    }

    parso_status_t encode(Bytes *out) const noexcept {
        if (!out || samples_.empty() || sampleRateHz_ == 0 || codec_ == 0) {
            return PARSO_STATUS_INVALID_ARGUMENT;
        }
        if (codec_ != PARSO_CODEC_WAV && codec_ != PARSO_CODEC_FLAC &&
            codec_ != PARSO_CODEC_AAC) {
            return PARSO_STATUS_UNSUPPORTED;
        }
        parso_codec_options_t options{};
        parso_pcm_buffer_t input{};
        if (parso_codec_options_init(&options) != PARSO_STATUS_OK ||
            parso_pcm_buffer_init(&input) != PARSO_STATUS_OK) {
            return PARSO_STATUS_INTERNAL;
        }
        options.bitrate_kbps = bitrateKbps_;
        options.quality = quality_;
        input.samples = const_cast<float *>(samples_.data());
        input.frames = static_cast<uint64_t>(samples_.size() / 2u);
        input.channel_count = 2;
        input.sample_rate_hz = sampleRateHz_;
        const parso_status_t status = parso_codec_write(
            &input, codec_, &options, out->cHandle());
        input.samples = nullptr;
        parso_pcm_buffer_release(&input);
        return status;
    }

    void reset() noexcept { samples_.clear(); }

private:
    uint32_t sampleRateHz_ = 0;
    uint32_t codec_ = PARSO_CODEC_WAV;
    uint32_t bitrateKbps_ = 192;
    uint32_t quality_ = 0;
    std::vector<float> samples_;
};

} // namespace parso

#endif /* PARSO_HPP */
