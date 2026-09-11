# Parso Audio Android library

This module packages the checked-in Kotlin `ParsoEngine`, `ParsoAnalysis`, `ParsoVorbis`, and `ParsoOffline` facades together with the
shared C ABI and JNI bridge into an Android library/AAR. It uses the same root
`CMakeLists.txt` as the Linux and standalone Android NDK builds; no second DSP or
codec implementation is introduced.

From a host with Gradle, the Android SDK, and the declared NDK/CMake versions:

```bash
gradle --project-dir Bindings/ParsoAudioAndroid assembleRelease
```

The generated AAR is under
`Bindings/ParsoAudioAndroid/build/outputs/aar/`. The Kotlin facade requires API
26 or newer and retains direct PCM buffers until replacement or `close()`. `ParsoAnalysis`
provides synchronous off-audio-thread summary, key, and structure calls over borrowed
direct native-order float buffers. The module is a packaging seam: device playback,
capture, route changes, Vorbis runtime fixture parity, emulator execution, and JVM lifetime instrumentation remain separate acceptance gates.

To stage a local Maven artifact for an application consumer:

```bash
gradle --project-dir Bindings/ParsoAudioAndroid \
  testReleaseUnitTest publishReleasePublicationToLocalStagingRepository
```

The repository is written under `build/maven-repository/` and is not a remote
publication or a device/runtime validation.
