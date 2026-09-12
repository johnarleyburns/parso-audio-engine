#ifndef NOMINMAX
#define NOMINMAX
#endif

#include "parso.h"

#include <windows.h>
#include <initguid.h>
#include <audioclient.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace {

constexpr uint32_t kDeckSeconds = 4;
constexpr uint32_t kMaxFrames = 4096;

bool ok(HRESULT result, const char *operation) {
    if (SUCCEEDED(result)) return true;
    std::fprintf(stderr, "windows_wasapi_host: %s failed (0x%08lx)\n",
                 operation, static_cast<unsigned long>(result));
    return false;
}

bool okParso(parso_status_t status, const char *operation) {
    if (status == PARSO_STATUS_OK) return true;
    std::fprintf(stderr, "windows_wasapi_host: %s failed: %s\n",
                 operation, parso_last_error());
    return false;
}

bool isFloatFormat(const WAVEFORMATEX *format) {
    if (format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) return true;
    if (format->wFormatTag != WAVE_FORMAT_EXTENSIBLE ||
        format->cbSize < sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
        return false;
    }
    const auto *extensible = reinterpret_cast<const WAVEFORMATEXTENSIBLE *>(format);
    const GUID &subFormat = extensible->SubFormat;
    return subFormat.Data1 == WAVE_FORMAT_IEEE_FLOAT && subFormat.Data2 == 0 &&
           subFormat.Data3 == 0x0010 && subFormat.Data4[0] == 0x80 &&
           subFormat.Data4[1] == 0x00 && subFormat.Data4[2] == 0x00 &&
           subFormat.Data4[3] == 0xaa && subFormat.Data4[4] == 0x00 &&
           subFormat.Data4[5] == 0x38 && subFormat.Data4[6] == 0x9b &&
           subFormat.Data4[7] == 0x71;
}

void renderToWavFormat(const float *left, const float *right, uint32_t frames,
                       BYTE *destination, const WAVEFORMATEX *format) {
    const uint16_t channels = format->nChannels;
    const uint16_t bits = format->wBitsPerSample;
    const bool floating = isFloatFormat(format);
    for (uint32_t frame = 0; frame < frames; ++frame) {
        const float leftSample = std::clamp(left[frame], -1.0f, 1.0f);
        const float rightSample = std::clamp(right[frame], -1.0f, 1.0f);
        for (uint16_t channel = 0; channel < channels; ++channel) {
            const float sample = channel == 0 ? leftSample : rightSample;
            BYTE *slot = destination + frame * format->nBlockAlign +
                         channel * (bits / 8);
            if (floating && bits == 32) {
                *reinterpret_cast<float *>(slot) = sample;
            } else if (!floating && bits == 16) {
                const auto integer = static_cast<int16_t>(sample >= 1.0f
                    ? 32767 : sample <= -1.0f ? -32768 : sample * 32767.0f);
                *reinterpret_cast<int16_t *>(slot) = integer;
            }
        }
    }
}

bool renderAvailable(parso_engine_t *engine, IAudioRenderClient *renderClient,
                     const WAVEFORMATEX *format, uint32_t maxFrames,
                     uint32_t available, std::vector<float> &left,
                     std::vector<float> &right) {
    while (available > 0) {
        const uint32_t frames = std::min(available, maxFrames);
        BYTE *buffer = nullptr;
        if (!ok(renderClient->GetBuffer(frames, &buffer), "IAudioRenderClient::GetBuffer")) {
            return false;
        }
        parso_output_view_t output{};
        if (!okParso(parso_output_view_init(&output), "output view initialization")) {
            renderClient->ReleaseBuffer(frames, AUDCLNT_BUFFERFLAGS_SILENT);
            return false;
        }
        output.left = left.data();
        output.right = right.data();
        output.frames = frames;
        const bool rendered = okParso(parso_engine_render(engine, &output), "engine render");
        if (rendered) renderToWavFormat(left.data(), right.data(), frames, buffer, format);
        const DWORD releaseFlags = rendered ? 0u : static_cast<DWORD>(AUDCLNT_BUFFERFLAGS_SILENT);
        const HRESULT release = renderClient->ReleaseBuffer(frames, releaseFlags);
        if (!ok(release, "IAudioRenderClient::ReleaseBuffer") || !rendered) return false;
        available -= frames;
    }
    return true;
}

float decodeCaptureSample(const BYTE *slot, const WAVEFORMATEX *format) {
    if (isFloatFormat(format) && format->wBitsPerSample == 32) {
        return *reinterpret_cast<const float *>(slot);
    }
    if (!isFloatFormat(format) && format->wBitsPerSample == 16) {
        return static_cast<float>(*reinterpret_cast<const int16_t *>(slot)) / 32768.0f;
    }
    return 0.0f;
}

bool captureAvailable(parso_engine_t *engine, IAudioCaptureClient *captureClient,
                      const WAVEFORMATEX *format, uint32_t maxFrames,
                      std::vector<float> &left, std::vector<float> &right,
                      const float *const *planes) {
    while (true) {
        BYTE *buffer = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        if (!ok(captureClient->GetBuffer(&buffer, &frames, &flags, nullptr, nullptr),
                "IAudioCaptureClient::GetBuffer")) {
            return false;
        }
        if (frames == 0) {
            captureClient->ReleaseBuffer(0);
            return true;
        }
        if (frames > maxFrames) {
            std::fprintf(stderr, "windows_wasapi_host: capture block exceeds configured capacity\n");
            captureClient->ReleaseBuffer(frames);
            return false;
        }
        const bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
        const uint16_t channels = format->nChannels;
        const uint16_t bytesPerSample = format->wBitsPerSample / 8;
        for (UINT32 frame = 0; frame < frames; ++frame) {
            const BYTE *source = buffer + frame * format->nBlockAlign;
            left[frame] = silent ? 0.0f : decodeCaptureSample(source, format);
            right[frame] = channels == 1 ? left[frame]
                : silent ? 0.0f : decodeCaptureSample(source + bytesPerSample, format);
        }
        parso_pcm_view_t input{};
        if (!okParso(parso_pcm_view_init(&input), "capture view initialization")) {
            captureClient->ReleaseBuffer(frames);
            return false;
        }
        input.planes = planes;
        input.frames = frames;
        input.channel_count = channels == 1 ? 1u : 2u;
        input.sample_rate_hz = format->nSamplesPerSec;
        const bool published = okParso(
            parso_engine_set_mic_buffer(engine, &input), "mic capture publish");
        const HRESULT release = captureClient->ReleaseBuffer(frames);
        if (!ok(release, "IAudioCaptureClient::ReleaseBuffer") || !published) return false;
        return true;
    }
}

} // namespace

int main(int argc, char **argv) {
    const uint32_t seconds = argc > 1 ? static_cast<uint32_t>(std::strtoul(argv[1], nullptr, 10)) : 5u;
    bool captureRequested = false;
    bool allowUnavailable = false;
    for (int index = 2; index < argc; ++index) {
        captureRequested = captureRequested || std::strcmp(argv[index], "--capture") == 0;
        allowUnavailable = allowUnavailable || std::strcmp(argv[index], "--allow-unavailable") == 0;
    }
    if (seconds == 0 || seconds > 3600) {
        std::fprintf(stderr, "usage: windows_wasapi_host [seconds 1..3600] [--capture] [--allow-unavailable]\n");
        return 2;
    }
    if (!ok(CoInitializeEx(nullptr, COINIT_MULTITHREADED), "COM initialization")) return 1;

    IMMDeviceEnumerator *enumerator = nullptr;
    IMMDevice *device = nullptr;
    IMMDevice *captureDevice = nullptr;
    IAudioClient *audioClient = nullptr;
    IAudioClient *captureAudioClient = nullptr;
    IAudioRenderClient *renderClient = nullptr;
    IAudioCaptureClient *captureClient = nullptr;
    WAVEFORMATEX *format = nullptr;
    WAVEFORMATEX *captureFormat = nullptr;
    HANDLE event = nullptr;
    HANDLE captureEvent = nullptr;
    parso_engine_t *engine = nullptr;
    std::vector<float> source;
    std::vector<float> captureLeft;
    std::vector<float> captureRight;
    const float *capturePlanes[] = {nullptr, nullptr};
    int result = 1;

    do {
        if (!ok(CoCreateInstance(CLSID_MMDeviceEnumerator, nullptr, CLSCTX_ALL,
                                 IID_IMMDeviceEnumerator,
                                 reinterpret_cast<void **>(&enumerator)),
                "MMDeviceEnumerator creation") ||
            !ok(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device),
                "default render endpoint") ||
            !ok(device->Activate(IID_IAudioClient, CLSCTX_ALL, nullptr,
                                 reinterpret_cast<void **>(&audioClient)),
                "IAudioClient activation") ||
            !ok(audioClient->GetMixFormat(&format), "mix format query")) {
            break;
        }
        const bool floatingFormat = isFloatFormat(format);
        if (format->nChannels < 1 || format->nChannels > 2 ||
            (floatingFormat && format->wBitsPerSample != 32) ||
            (!floatingFormat && format->wBitsPerSample != 16)) {
            std::fprintf(stderr, "windows_wasapi_host: unsupported endpoint format\n");
            break;
        }

        constexpr REFERENCE_TIME bufferDuration = 100000; // 10 ms.
        UINT32 captureBufferFrames = 0;
        if (captureRequested) {
            if (!ok(enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &captureDevice),
                    "default capture endpoint") ||
                !ok(captureDevice->Activate(IID_IAudioClient, CLSCTX_ALL, nullptr,
                                            reinterpret_cast<void **>(&captureAudioClient)),
                    "capture IAudioClient activation") ||
                !ok(captureAudioClient->GetMixFormat(&captureFormat),
                    "capture mix format query")) {
                break;
            }
            const bool captureFloating = isFloatFormat(captureFormat);
            if (captureFormat->nChannels < 1 || captureFormat->nChannels > 2 ||
                (captureFloating && captureFormat->wBitsPerSample != 32) ||
                (!captureFloating && captureFormat->wBitsPerSample != 16)) {
                std::fprintf(stderr, "windows_wasapi_host: unsupported capture format\n");
                break;
            }
            if (!ok(captureAudioClient->Initialize(AUDCLNT_SHAREMODE_SHARED,
                                                   AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                                                   bufferDuration, 0, captureFormat, nullptr),
                    "capture IAudioClient initialization") ||
                !ok(captureAudioClient->GetBufferSize(&captureBufferFrames),
                    "capture buffer-size query") || captureBufferFrames == 0) {
                break;
            }
            captureEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
            if (!captureEvent || !ok(captureAudioClient->SetEventHandle(captureEvent),
                                      "capture event handle setup") ||
                !ok(captureAudioClient->GetService(IID_IAudioCaptureClient,
                                                   reinterpret_cast<void **>(&captureClient)),
                    "capture-client activation")) {
                break;
            }
            captureLeft.assign(captureBufferFrames, 0.0f);
            captureRight.assign(captureBufferFrames, 0.0f);
            capturePlanes[0] = captureLeft.data();
            capturePlanes[1] = captureRight.data();
        }

        if (!ok(audioClient->Initialize(AUDCLNT_SHAREMODE_SHARED,
                                         AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                                         bufferDuration, 0, format, nullptr),
                "IAudioClient initialization")) {
            break;
        }
        UINT32 bufferFrames = 0;
        if (!ok(audioClient->GetBufferSize(&bufferFrames), "buffer-size query") || bufferFrames == 0) {
            break;
        }
        event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!event || !ok(audioClient->SetEventHandle(event), "event handle setup") ||
            !ok(audioClient->GetService(IID_IAudioRenderClient,
                                        reinterpret_cast<void **>(&renderClient)),
                "render-client activation")) {
            break;
        }

        const uint32_t sampleRate = format->nSamplesPerSec;
        const uint32_t renderFrames = std::min(bufferFrames, kMaxFrames);
        source.resize(static_cast<size_t>(sampleRate) * kDeckSeconds);
        for (size_t index = 0; index < source.size(); ++index) {
            source[index] = 0.2f * std::sin(static_cast<float>(
                2.0 * 3.141592653589793 * 220.0 * index / sampleRate));
        }
        const float *planes[] = {source.data()};
        parso_engine_options_t options{};
        parso_control_t control{};
        parso_pcm_view_t view{};
        parso_command_t command{};
        if (!okParso(parso_engine_options_init(&options), "engine options initialization") ||
            !okParso(parso_control_init(&control), "control initialization") ||
            !okParso(parso_pcm_view_init(&view), "PCM view initialization") ||
            !okParso(parso_command_init(&command), "command initialization")) {
            break;
        }
        options.sample_rate_hz = sampleRate;
        options.max_frames = renderFrames;
        view.planes = planes;
        view.frames = source.size();
        view.channel_count = 1;
        view.sample_rate_hz = sampleRate;
        command.type = PARSO_COMMAND_PLAY;
        command.deck = 0;
        if (!okParso(parso_engine_create(&options, &engine), "engine creation") ||
            !okParso(parso_engine_set_control(engine, &control), "control publish") ||
            !okParso(parso_engine_set_deck_buffer(engine, 0, &view), "deck buffer") ||
            !okParso(parso_engine_post_command(engine, &command), "play command") ||
            !ok(audioClient->Start(), "audio client start") ||
            (captureRequested && !ok(captureAudioClient->Start(), "capture audio client start"))) {
            break;
        }

        std::vector<float> left(renderFrames, 0.0f);
        std::vector<float> right(renderFrames, 0.0f);
        const uint64_t deadline = GetTickCount64() + static_cast<uint64_t>(seconds) * 1000u;
        bool loopOk = true;
        HANDLE waitHandles[] = {event, captureEvent};
        const DWORD waitCount = captureRequested ? 2u : 1u;
        while (GetTickCount64() < deadline) {
            const DWORD wait = WaitForMultipleObjects(waitCount, waitHandles, FALSE, 2000);
            if (wait == WAIT_OBJECT_0 + 1u && captureRequested) {
                if (!captureAvailable(engine, captureClient, captureFormat, captureBufferFrames,
                                      captureLeft, captureRight, capturePlanes)) {
                    loopOk = false;
                    break;
                }
                continue;
            }
            if (wait != WAIT_OBJECT_0) {
                std::fprintf(stderr, "windows_wasapi_host: audio event timed out\n");
                loopOk = false;
                break;
            }
            UINT32 padding = 0;
            if (!ok(audioClient->GetCurrentPadding(&padding), "current padding query")) {
                loopOk = false;
                break;
            }
            const uint32_t available = bufferFrames > padding ? bufferFrames - padding : 0;
            if (!renderAvailable(engine, renderClient, format, renderFrames, available, left, right)) {
                loopOk = false;
                break;
            }
        }
        if (captureRequested) captureAudioClient->Stop();
        audioClient->Stop();
        result = loopOk ? 0 : 1;
    } while (false);

    if (engine) parso_engine_destroy(&engine);
    if (event) CloseHandle(event);
    if (captureEvent) CloseHandle(captureEvent);
    if (format) CoTaskMemFree(format);
    if (captureFormat) CoTaskMemFree(captureFormat);
    if (renderClient) renderClient->Release();
    if (captureClient) captureClient->Release();
    if (audioClient) audioClient->Release();
    if (captureAudioClient) captureAudioClient->Release();
    if (device) device->Release();
    if (captureDevice) captureDevice->Release();
    if (enumerator) enumerator->Release();
    CoUninitialize();
    return result == 0 ? 0 : allowUnavailable ? 77 : result;
}
