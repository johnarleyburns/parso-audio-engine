/*
 * parso.hpp — small move-only C++17 convenience wrapper over parso.h.
 * No STL or C++ types cross the public C ABI.
 */
#ifndef PARSO_HPP
#define PARSO_HPP

#include "parso.h"

namespace parso {

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
