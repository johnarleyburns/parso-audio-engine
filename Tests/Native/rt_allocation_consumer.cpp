#include "parso_engine.h"

#include <atomic>
#include <cstddef>
#include <cstdlib>
#include <new>

namespace {

std::atomic<bool> measuring{false};
std::atomic<unsigned long long> allocations{0};

void *allocate(std::size_t size) {
    void *memory = std::malloc(size == 0 ? 1u : size);
    if (!memory) throw std::bad_alloc();
    if (measuring.load(std::memory_order_relaxed)) {
        allocations.fetch_add(1u, std::memory_order_relaxed);
    }
    return memory;
}

} // namespace

void *operator new(std::size_t size) { return allocate(size); }
void *operator new[](std::size_t size) { return allocate(size); }
void operator delete(void *memory) noexcept { std::free(memory); }
void operator delete[](void *memory) noexcept { std::free(memory); }
void operator delete(void *memory, std::size_t) noexcept { std::free(memory); }
void operator delete[](void *memory, std::size_t) noexcept { std::free(memory); }

int main() {
    constexpr int maxFrames = 256;
    constexpr int sampleRate = 48'000;
    float deck[maxFrames * 2]{};
    float outputLeft[maxFrames]{};
    float outputRight[maxFrames]{};
    const float *planes[] = {deck, deck + maxFrames};

    pe_engine *engine = pe_create(sampleRate, maxFrames, 2);
    if (!engine) return 1;
    pe_deck_set_buffer(engine, 0, planes, 2, maxFrames, sampleRate);

    pe_control control{};
    control.master_level = 1.0f;
    control.fader[0] = 1.0f;
    control.fader[1] = 1.0f;
    control.trim[0] = 1.0f;
    control.trim[1] = 1.0f;
    pe_set_control(engine, &control);
    pe_command play{};
    play.type = PE_CMD_PLAY;
    play.deck = 0;
    if (!pe_post_command(engine, &play)) {
        pe_destroy(engine);
        return 1;
    }

    /* Warm every path before measuring; setup and first-use state are control-side. */
    for (int index = 0; index < 16; ++index) {
        pe_step(engine, outputLeft, outputRight, maxFrames);
        pe_render(engine, outputLeft, outputRight, maxFrames);
    }

    allocations.store(0u, std::memory_order_relaxed);
    measuring.store(true, std::memory_order_release);
    constexpr int blockSizes[] = {17, 32, 64, 127, 256, 96};
    for (int index = 0; index < 512; ++index) {
        const int frames = blockSizes[index % (sizeof(blockSizes) / sizeof(blockSizes[0]))];
        pe_step(engine, outputLeft, outputRight, frames);
        pe_render(engine, outputLeft, outputRight, frames);
    }
    measuring.store(false, std::memory_order_release);

    const unsigned long long count = allocations.load(std::memory_order_acquire);
    pe_destroy(engine);
    return count == 0u ? 0 : 1;
}
