/*
 * parso.hpp — small move-only C++17 convenience wrapper over parso.h.
 * No STL or C++ types cross the public C ABI.
 */
#ifndef PARSO_HPP
#define PARSO_HPP

#include "parso.h"

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

private:
    parso_engine_t *handle_ = nullptr;
};

} // namespace parso

#endif /* PARSO_HPP */
