# Parso Audio Android library

This module packages the checked-in Kotlin `ParsoEngine`, `ParsoAnalysis`, `ParsoVorbis`, `ParsoOffline`, and `ParsoRecorder` facades together with the
shared C ABI and JNI bridge into an Android library/AAR. It uses the same root
`CMakeLists.txt` as the Linux and standalone Android NDK builds; no second DSP or
codec implementation is introduced.

From a host with Gradle, the Android SDK, and the declared NDK/CMake versions:

```bash
gradle --project-dir Bindings/ParsoAudioAndroid assembleRelease
```

The generated AAR is under
`Bindings/ParsoAudioAndroid/build/outputs/aar/`. The Kotlin facade requires API
26 or newer and retains direct PCM buffers until replacement or `close()`. `ParsoEngine` also exposes
mixer control, typed transport/loop commands, copied frame/starvation stats, and bounded event
polling. `ParsoAnalysis`
provides synchronous off-audio-thread summary, key, and structure calls over borrowed
direct native-order float buffers. `ParsoRecorder` copies drained stereo blocks on the control side
and encodes WAV, FLAC, or AAC through the shared native codec service; MP3 and Ogg recording remain
explicitly unavailable. `ParsoAudioDevice` adds an Oboe low-latency output callback and
bounded mono capture ring; `ParsoAudioRoute` owns API 26+ audio focus and reopens the device
on route changes. Emulator lifecycle/callback coverage is enabled; physical microphone
permissions, route recovery, latency, and listening acceptance remain device gates.

To stage a local Maven artifact for an application consumer:

```bash
gradle --project-dir Bindings/ParsoAudioAndroid \
  testReleaseUnitTest publishReleasePublicationToLocalStagingRepository
```

The repository is written under `build/maven-repository/` and is not a remote
publication or a device/runtime validation.
