# Parso Audio Android library

This module packages the checked-in Kotlin `ParsoEngine` facade together with the
shared C ABI and JNI bridge into an Android library/AAR. It uses the same root
`CMakeLists.txt` as the Linux and standalone Android NDK builds; no second DSP or
codec implementation is introduced.

From a host with Gradle, the Android SDK, and the declared NDK/CMake versions:

```bash
gradle --project-dir Bindings/ParsoAudioAndroid assembleRelease
```

The generated AAR is under
`Bindings/ParsoAudioAndroid/build/outputs/aar/`. The Kotlin facade requires API
26 or newer and retains direct PCM buffers until replacement or `close()`. The
module is a packaging seam: device playback, capture, route changes, and JVM
lifetime instrumentation remain separate acceptance gates.
