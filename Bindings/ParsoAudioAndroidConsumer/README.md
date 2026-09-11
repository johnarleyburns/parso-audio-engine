# Android AAR consumer smoke project

This application resolves `com.parsoaudio:parso-audio-android:0.1.0` from the
local Maven repository produced by `Bindings/ParsoAudioAndroid`. It verifies
that an external Android project can resolve and compile against the analysis,
offline, Vorbis, and engine facade types, package the AAR, and include its two
native libraries. `MainActivity` runs `ConsumerScenario`, a small end-to-end
sample that exercises summary/key/structure analysis, SRC, loudness, Xiph Ogg
Vorbis round-trip, engine rendering, and the record tap. The activity is also a
manual emulator/device smoke path; the normal package build does not claim
runtime execution by itself.

The consumer also has an instrumentation test for that scenario. Hosted CI
runs it on the same x86_64 API 35 emulator after installing the producer's
instrumentation suite.

Build the producer first, then run:

```bash
gradle --project-dir Bindings/ParsoAudioAndroid \
  publishReleasePublicationToLocalStagingRepository
gradle --project-dir Bindings/ParsoAudioAndroidConsumer assembleDebug
```
