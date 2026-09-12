#include "parso.h"

#include <oboe/Oboe.h>
#include <jni.h>

#include <atomic>
#include <cstdint>
#include <cstring>
#include <memory>
#include <vector>

namespace {

class AndroidAudioDevice final : public oboe::AudioStreamDataCallback,
                                 public oboe::AudioStreamErrorCallback {
public:
    AndroidAudioDevice(parso_engine_t *engine, int32_t sampleRate, int32_t maxFrames,
                       int32_t captureFrames)
        : engine_(engine), sampleRate_(sampleRate), maxFrames_(maxFrames),
          left_(static_cast<size_t>(maxFrames), 0.0f),
          right_(static_cast<size_t>(maxFrames), 0.0f),
          capture_(static_cast<size_t>(captureFrames), 0.0f) {}

    ~AndroidAudioDevice() override { stop(); }

    bool start() {
        if (state_.load(std::memory_order_acquire) == 1) return true;
        error_.store(0, std::memory_order_release);
        if (!openOutput()) {
            state_.store(3, std::memory_order_release);
            return false;
        }
        // Capture is optional for playback. A permission or route failure is
        // reported as state 2 while the output stream remains usable.
        const bool inputOpened = openInput();
        if (output_->requestStart() != oboe::Result::OK) {
            closeStreams();
            state_.store(3, std::memory_order_release);
            return false;
        }
        if (inputOpened && input_->requestStart() != oboe::Result::OK) {
            input_->close();
            input_.reset();
        }
        state_.store(input_ ? 1 : 2, std::memory_order_release);
        return true;
    }

    bool stop() {
        closeStreams();
        state_.store(0, std::memory_order_release);
        return true;
    }

    int state() const { return state_.load(std::memory_order_acquire); }

    int readCapture(float *output, int32_t maxFrames) {
        if (!output || maxFrames <= 0) return -1;
        uint32_t read = read_.load(std::memory_order_relaxed);
        const uint32_t write = write_.load(std::memory_order_acquire);
        const uint32_t capacity = static_cast<uint32_t>(capture_.size());
        uint32_t available = write - read;
        if (available > capacity) available = capacity;
        const uint32_t count = available < static_cast<uint32_t>(maxFrames)
            ? available : static_cast<uint32_t>(maxFrames);
        for (uint32_t index = 0; index < count; ++index) {
            output[index] = capture_[(read + index) % capacity];
        }
        read_.store(read + count, std::memory_order_release);
        return static_cast<int>(count);
    }

    int availableCapture() const {
        const uint32_t write = write_.load(std::memory_order_acquire);
        const uint32_t read = read_.load(std::memory_order_relaxed);
        const uint32_t capacity = static_cast<uint32_t>(capture_.size());
        const uint32_t available = write - read;
        return static_cast<int>(available > capacity ? capacity : available);
    }

    int64_t droppedCapture() const {
        return dropped_.load(std::memory_order_relaxed);
    }

    oboe::DataCallbackResult onAudioReady(oboe::AudioStream *stream, void *audioData,
                                          int32_t numFrames) override {
        if (stream == output_.get()) return renderOutput(audioData, numFrames);
        if (stream == input_.get()) return captureInput(audioData, numFrames);
        return oboe::DataCallbackResult::Stop;
    }

    void onErrorBeforeClose(oboe::AudioStream *, oboe::Result error) override {
        error_.store(static_cast<int32_t>(error), std::memory_order_release);
    }

    void onErrorAfterClose(oboe::AudioStream *, oboe::Result error) override {
        error_.store(static_cast<int32_t>(error), std::memory_order_release);
        state_.store(3, std::memory_order_release);
    }

private:
    bool openOutput() {
        oboe::AudioStreamBuilder builder;
        builder.setDirection(oboe::Direction::Output)
            ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
            ->setSharingMode(oboe::SharingMode::Exclusive)
            ->setFormat(oboe::AudioFormat::Float)
            ->setChannelCount(2)
            ->setSampleRate(sampleRate_)
            ->setDataCallback(this)
            ->setErrorCallback(this);
        oboe::Result result = builder.openStream(output_);
        if (result != oboe::Result::OK) {
            builder.setSharingMode(oboe::SharingMode::Shared);
            result = builder.openStream(output_);
        }
        if (result != oboe::Result::OK || !output_) {
            output_.reset();
            return false;
        }
        output_->setBufferSizeInFrames(maxFrames_);
        return true;
    }

    bool openInput() {
        oboe::AudioStreamBuilder builder;
        builder.setDirection(oboe::Direction::Input)
            ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
            ->setSharingMode(oboe::SharingMode::Exclusive)
            ->setFormat(oboe::AudioFormat::Float)
            ->setChannelCount(1)
            ->setSampleRate(sampleRate_)
            ->setDataCallback(this)
            ->setErrorCallback(this);
        oboe::Result result = builder.openStream(input_);
        if (result != oboe::Result::OK) {
            builder.setSharingMode(oboe::SharingMode::Shared);
            result = builder.openStream(input_);
        }
        if (result != oboe::Result::OK || !input_) {
            input_.reset();
            return false;
        }
        input_->setBufferSizeInFrames(maxFrames_);
        return true;
    }

    void closeStreams() {
        if (input_) {
            input_->requestStop();
            input_->close();
            input_.reset();
        }
        if (output_) {
            output_->requestStop();
            output_->close();
            output_.reset();
        }
    }

    oboe::DataCallbackResult renderOutput(void *audioData, int32_t numFrames) {
        if (!audioData || numFrames <= 0 || numFrames > maxFrames_) {
            if (audioData && numFrames > 0) {
                std::memset(audioData, 0, static_cast<size_t>(numFrames) * 2U * sizeof(float));
            }
            return oboe::DataCallbackResult::Continue;
        }
        parso_output_view_t view{};
        if (parso_output_view_init(&view) != PARSO_STATUS_OK) return silence(audioData, numFrames);
        view.left = left_.data();
        view.right = right_.data();
        view.frames = static_cast<uint32_t>(numFrames);
        if (parso_engine_render(engine_, &view) != PARSO_STATUS_OK) {
            return silence(audioData, numFrames);
        }
        float *interleaved = static_cast<float *>(audioData);
        for (int32_t frame = 0; frame < numFrames; ++frame) {
            interleaved[2 * frame] = left_[static_cast<size_t>(frame)];
            interleaved[2 * frame + 1] = right_[static_cast<size_t>(frame)];
        }
        return oboe::DataCallbackResult::Continue;
    }

    oboe::DataCallbackResult silence(void *audioData, int32_t numFrames) {
        std::memset(audioData, 0, static_cast<size_t>(numFrames) * 2U * sizeof(float));
        return oboe::DataCallbackResult::Continue;
    }

    oboe::DataCallbackResult captureInput(void *audioData, int32_t numFrames) {
        if (!audioData || numFrames <= 0) return oboe::DataCallbackResult::Continue;
        const float *input = static_cast<const float *>(audioData);
        uint32_t write = write_.load(std::memory_order_relaxed);
        uint32_t read = read_.load(std::memory_order_acquire);
        const uint32_t capacity = static_cast<uint32_t>(capture_.size());
        for (int32_t frame = 0; frame < numFrames; ++frame) {
            if (write - read >= capacity) {
                ++read;
                dropped_.fetch_add(1, std::memory_order_relaxed);
            }
            capture_[write % capacity] = input[frame];
            ++write;
        }
        read_.store(read, std::memory_order_release);
        write_.store(write, std::memory_order_release);
        return oboe::DataCallbackResult::Continue;
    }

    parso_engine_t *engine_;
    int32_t sampleRate_;
    int32_t maxFrames_;
    std::vector<float> left_;
    std::vector<float> right_;
    std::vector<float> capture_;
    std::shared_ptr<oboe::AudioStream> output_;
    std::shared_ptr<oboe::AudioStream> input_;
    std::atomic<uint32_t> read_{0};
    std::atomic<uint32_t> write_{0};
    std::atomic<int64_t> dropped_{0};
    std::atomic<int32_t> error_{0};
    std::atomic<int32_t> state_{0};
};

AndroidAudioDevice *fromDeviceHandle(jlong handle) noexcept {
    return reinterpret_cast<AndroidAudioDevice *>(static_cast<uintptr_t>(handle));
}

jlong toDeviceHandle(AndroidAudioDevice *device) noexcept {
    return static_cast<jlong>(reinterpret_cast<uintptr_t>(device));
}

} // namespace

extern "C" {

JNIEXPORT jlong JNICALL Java_com_parsoaudio_ParsoNative_nativeDeviceCreate(
    JNIEnv *, jclass, jlong engineHandle, jint sampleRateHz, jint maxFrames, jint captureFrames
) {
    if (engineHandle == 0 || sampleRateHz <= 0 || maxFrames <= 0 || captureFrames < maxFrames) {
        return 0;
    }
    auto *device = new AndroidAudioDevice(
        reinterpret_cast<parso_engine_t *>(static_cast<uintptr_t>(engineHandle)),
        sampleRateHz, maxFrames, captureFrames);
    return toDeviceHandle(device);
}

JNIEXPORT void JNICALL Java_com_parsoaudio_ParsoNative_nativeDeviceDestroy(
    JNIEnv *, jclass, jlong handle
) {
    delete fromDeviceHandle(handle);
}

JNIEXPORT jboolean JNICALL Java_com_parsoaudio_ParsoNative_nativeDeviceStart(
    JNIEnv *, jclass, jlong handle
) {
    auto *device = fromDeviceHandle(handle);
    return device && device->start() ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL Java_com_parsoaudio_ParsoNative_nativeDeviceStop(
    JNIEnv *, jclass, jlong handle
) {
    auto *device = fromDeviceHandle(handle);
    return device && device->stop() ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jint JNICALL Java_com_parsoaudio_ParsoNative_nativeDeviceState(
    JNIEnv *, jclass, jlong handle
) {
    auto *device = fromDeviceHandle(handle);
    return device ? device->state() : 3;
}

JNIEXPORT jint JNICALL Java_com_parsoaudio_ParsoNative_nativeDeviceReadCapture(
    JNIEnv *env, jclass, jlong handle, jobject output, jint maxFrames
) {
    auto *device = fromDeviceHandle(handle);
    if (!device || !env || !output || maxFrames <= 0) return -1;
    void *address = env->GetDirectBufferAddress(output);
    const jlong capacity = env->GetDirectBufferCapacity(output);
    if (!address || capacity < static_cast<jlong>(maxFrames) * static_cast<jlong>(sizeof(float))) {
        return -1;
    }
    return device->readCapture(static_cast<float *>(address), maxFrames);
}

JNIEXPORT jint JNICALL Java_com_parsoaudio_ParsoNative_nativeDeviceAvailableCapture(
    JNIEnv *, jclass, jlong handle
) {
    auto *device = fromDeviceHandle(handle);
    return device ? device->availableCapture() : 0;
}

JNIEXPORT jlong JNICALL Java_com_parsoaudio_ParsoNative_nativeDeviceDroppedCapture(
    JNIEnv *, jclass, jlong handle
) {
    auto *device = fromDeviceHandle(handle);
    return device ? static_cast<jlong>(device->droppedCapture()) : -1;
}

}
