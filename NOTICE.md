# Third-Party Notices

`parso-audio-engine` is MIT-licensed (see `LICENSE`). It links Apple system
frameworks and vendors the following **permissive** third-party libraries. Each
retains its own license; none use a prohibited copyleft license.

| Component | License | Upstream | Role |
|---|---|---|---|
| libFLAC | BSD-3-Clause | https://xiph.org/flac/ | FLAC decode/encode |
| libebur128 | MIT | https://github.com/jiixyj/libebur128 | EBU R128 loudness |
| libsamplerate (≥ 0.2.2) | BSD-2-Clause | https://github.com/libsndfile/libsamplerate | Offline sample-rate conversion |
| stb_vorbis | MIT / Public Domain | https://github.com/nothings/stb | Ogg Vorbis decode |
| libogg | BSD-3-Clause | https://github.com/xiph/ogg | Ogg container (Opus) |
| libopus | BSD-3-Clause | https://github.com/xiph/opus | Opus decode |
| libopusfile | BSD-3-Clause | https://github.com/xiph/opusfile | Ogg Opus file reader |
| Signalsmith Stretch | MIT | https://github.com/Signalsmith-Audio/signalsmith-stretch | Time-stretch / pitch-shift |
| Signalsmith Linear | MIT | https://github.com/Signalsmith-Audio/linear | Stretch FFT and DSP support |
| Freeverb (reverb constants) | Public Domain | Jezar at Dreampoint | Reverb tuning reference |

Apple frameworks used under the Apple SDK license (linked, not redistributed):
AVFoundation, AudioToolbox, Accelerate.

> **Vendoring policy:** when adding each C/C++ dependency, place its unmodified
> source under the corresponding `Sources/C*/` target, keep its upstream
> `LICENSE` file alongside, and record the source commit in a `VENDOR.md`. CI
> fails if a disallowed copyleft identifier appears in the tree.

Test-only audio fixtures (Creative Commons, **fetched at test time, not
redistributed in this repo**) are attributed in `ATTRIBUTION.md`.

## BSD-only portable-codec notice

The portable replacement for any removed Apple public-source codec material
must be independently authored and use only BSD-2-Clause/BSD-3-Clause (or
public-domain) implementation code. No implementation code from Apple's
public-source ALAC repository is used in this project. Its implementation files
were removed; only the upstream Apache-2.0 header declarations remain in
`Sources/Calac/vendor/codec`, are not compiled or linked, and do not provide a
portable ALAC implementation. Apple platforms use the system AudioToolbox
implementation; portable ALAC is currently unavailable elsewhere.
