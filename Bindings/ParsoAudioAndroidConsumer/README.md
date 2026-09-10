# Android AAR consumer smoke project

This application resolves `com.parsoaudio:parso-audio-android:0.1.0` from the
local Maven repository produced by `Bindings/ParsoAudioAndroid`. It verifies
that an external Android project can resolve and package the AAR and its two
native libraries; it intentionally does not claim emulator or physical-device
execution.

Build the producer first, then run:

```bash
gradle --project-dir Bindings/ParsoAudioAndroid \
  publishReleasePublicationToLocalStagingRepository
gradle --project-dir Bindings/ParsoAudioAndroidConsumer assembleDebug
```
