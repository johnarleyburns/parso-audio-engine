# Bring-your-own codec/DSP: using a GPL or LGPL library from an app without PAE depending on it

PAE (`parso-audio-engine`) is MIT-licensed and depended on by more than one app
(`parso-tonearm`, `parso-voxglass`, and potentially others later). PAE must
never vendor, statically link, or `import` a GPL/LGPL/AGPL library itself —
doing so would put a copyleft obligation on every consumer of PAE, including
ones that never asked for it and may not be GPL-licensed themselves.

An individual **app** can be under whatever license it wants (both Tonearm and
Voxglass are GPLv3-or-later as of this writing — see each repo's `LICENSE`),
so an app is free to link a GPL/LGPL library for its own benefit. The pattern
below is how an app does that while PAE itself stays clean: **the app
implements a small protocol PAE declares, and hands PAE an instance of its own
type.** PAE calls through the protocol; it never imports the library behind
it.

This is not a new idea invented for this doc — it is the same seam already
used for on-device models:

- `StemModelProviding` / `SeparationBackendRegistry` (`Sources/ParsoAudioNeural/Separation.swift`,
  `SeparationBackendRegistry.swift`) — a host app supplies a converted
  `.mlpackage` and a small wrapper type; PAE never ships or touches the
  weights. See README.md "On-device neural" for the full licensing survey
  behind PAE's own default backend choice (Spleeter); `parso-tonearm`'s
  `DemucsStemModel` (`Sources/DJ/Stems/StemModel.swift`) is a real, in-tree
  example of an app registering a different backend and making its own
  licensing call for its own use — see that repo's own docs for its reasoning.
- `NeuralModelProviding` (`Sources/ParsoAudioNeural/ParsoAudioNeural.swift`) —
  same idea for CLAP-style semantic models.
- `MP3Encoding` (`Sources/ParsoAudioCore/ParsoAudioCore.swift`, below) — the
  same idea for MP3 encoding, so an app can use LAME (LGPL-2.1) instead of
  PAE's built-in Glint encoder.

## The `MP3Encoding` seam

```swift
public protocol MP3Encoding: Sendable {
    /// Encode `buffer` to a complete MP3 stream (including any headers/ID3
    /// the encoder writes) at `bitrateKbps`.
    func encode(_ buffer: PCMBuffer, bitrateKbps: Int) throws -> Data
}
```

`AudioFileWriter.init` takes an optional `mp3Encoder: (any MP3Encoding)?`.
Leave it `nil` (the default) and `.mp3` codecs use PAE's built-in Glint
encoder — a from-scratch, MIT-licensed CBR MP3 encoder
(`Sources/CGlint`) that exists specifically so PAE never *has* to depend on
LAME to support MP3 at all. Pass an instance and PAE calls it instead:

```swift
let writer = try AudioFileWriter(
    url: url,
    format: format,
    codec: .mp3(bitrate: 192),
    mp3Encoder: LAMEEncoder()   // app-side type, see below — PAE never imports LAME
)
try writer.write(buffer)
try writer.finish()
```

## Worked example: adding LAME to an app

LAME (`libmp3lame`) is LGPL-2.1. An app under a compatible license (GPL,
LGPL, or one that otherwise permits linking an LGPL library — check your own
license before doing this) can vendor it and wrap it in three pieces, all
**in the app's own source tree**, none of them in PAE:

### 1. Vendor the source

Drop LAME's source (e.g. `lame-3.100/libmp3lame/`) into the app's own local
package, e.g. `Sources/CLAME/vendor/`, keeping LAME's own `COPYING`/`LICENSE`
and any `AUTHORS`/changelog files alongside it — the app's own
`ATTRIBUTION.md` should record the exact version and where it came from, the
same way this repo's own `ATTRIBUTION.md` records libFLAC, libebur128, etc.
Only the encoder library is needed — LAME's `frontend/` (the `lame` CLI) and
`test parso-lame_bridge.c`-style test harnesses are not.

### 2. A small C bridge, mirroring `CflacBridge`

PAE's own vendored-codec bridges (`Sources/CflacBridge`, `Sources/CvorbisBridge`,
`Sources/CopusBridge`) all follow the same shape: a tiny hand-written C API
that wraps the vendored library's real (much larger, much uglier) API into a
handful of clean, `Sendable`-safe entry points. Do the same thing for LAME,
in the app's package instead of PAE's:

```c
// Sources/CLAMEBridge/include/app_lame.h
#ifndef APP_LAME_H
#define APP_LAME_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* Encodes interleaved Float32 PCM to a complete MP3 stream (CBR).
 * Returns a malloc'd buffer the caller must free with app_lame_free(),
 * or NULL on failure. */
uint8_t *app_lame_encode(const float *interleaved_pcm,
                         int32_t frame_count,
                         int32_t channel_count,
                         int32_t sample_rate,
                         int32_t bitrate_kbps,
                         int32_t *out_size);
void app_lame_free(uint8_t *buffer);

#ifdef __cplusplus
}
#endif
#endif
```

```c
// Sources/CLAMEBridge/src/app_lame.c
#include "app_lame.h"
#include <lame/lame.h>   // from the vendored LAME source
#include <stdlib.h>

uint8_t *app_lame_encode(const float *interleaved_pcm, int32_t frame_count,
                         int32_t channel_count, int32_t sample_rate,
                         int32_t bitrate_kbps, int32_t *out_size) {
    lame_global_flags *gfp = lame_init();
    lame_set_num_channels(gfp, channel_count);
    lame_set_in_samplerate(gfp, sample_rate);
    lame_set_brate(gfp, bitrate_kbps);
    lame_set_VBR(gfp, vbr_off);
    if (lame_init_params(gfp) < 0) { lame_close(gfp); return NULL; }

    int mp3_cap = (int)(1.25 * frame_count) + 7200;
    uint8_t *mp3_buf = malloc((size_t)mp3_cap);
    int written = lame_encode_buffer_interleaved_ieee_float(
        gfp, interleaved_pcm, frame_count, mp3_buf, mp3_cap);
    if (written >= 0) {
        int flush = lame_encode_flush(gfp, mp3_buf + written, mp3_cap - written);
        if (flush >= 0) written += flush;
    }
    lame_close(gfp);
    if (written < 0) { free(mp3_buf); return NULL; }
    *out_size = written;
    return mp3_buf;
}

void app_lame_free(uint8_t *buffer) { free(buffer); }
```

(This sketch omits real error handling and the exact LAME API surface you'd
tune — e.g. `lame_set_quality`, ID3 tags via `id3tag_*`. It's here to show
the *shape* of the bridge, not to be copy-pasted as production code.)

### 3. The Swift conformance

```swift
// Sources/YourAppCore/LAMEEncoder.swift
import CLAMEBridge
import ParsoAudioCore

public struct LAMEEncoder: MP3Encoding {
    public init() {}

    public func encode(_ buffer: PCMBuffer, bitrateKbps: Int) throws -> Data {
        var interleaved = [Float](repeating: 0, count: buffer.frameCount * buffer.channelCount)
        for frame in 0..<buffer.frameCount {
            for channel in 0..<buffer.channelCount {
                interleaved[frame * buffer.channelCount + channel] = buffer.channel(channel)[frame]
            }
        }
        var outSize: Int32 = 0
        let encoded: UnsafeMutablePointer<UInt8>? = interleaved.withUnsafeBufferPointer { samples in
            app_lame_encode(samples.baseAddress, Int32(buffer.frameCount),
                            Int32(buffer.channelCount), Int32(buffer.format.sampleRate.rounded()),
                            Int32(bitrateKbps), &outSize)
        }
        guard let encoded, outSize > 0 else { throw AudioFileError.writeFailed("LAME encode failed") }
        defer { app_lame_free(encoded) }
        return Data(bytes: encoded, count: Int(outSize))
    }
}
```

That's the whole seam. PAE's `ParsoAudioCore` target never gains a dependency
on LAME, never links it, and ships identically for every other consumer.

## Generalizing beyond MP3: what this pattern does and doesn't cover today

The same "app supplies a protocol conformance, PAE only calls through the
protocol" shape works for **any PAE seam that already takes a
caller-supplied value at a clean Swift API boundary** — MP3 encoding and stem
separation both qualify today. It does **not** yet apply to every piece of
DSP in PAE. In particular, PAE's real-time DJ engine's time-stretch/key-lock
(`Sources/CParsoEngine/src/parso_engine_stub.cpp`) currently calls a specific
vendored algorithm (Signalsmith Stretch, MIT — already permissively licensed,
so this was never a licensing problem) directly inline in a compiled C++
render loop, not through a Swift-level protocol. Swapping that implementation
for one app only, without PAE itself depending on the replacement, would need
a new **C-level** callback/vtable seam added to the engine first — a
materially bigger change than adding a Swift protocol parameter, and not
something this document's pattern covers as-is. If a real need for that
arises, design that seam the same way this one was: identify the exact call
site, add an app-suppliable indirection at that single point, and change
nothing else.

## Checklist before adding a new BYO seam like this one

1. Identify the exact call site in PAE that would use the third-party
   library, and confirm it's reachable through a clean Swift (or C, if
   real-time) API boundary — not buried inside an existing tightly-coupled
   loop.
2. Declare a narrow protocol for exactly what that call site needs (inputs
   in, bytes/samples out) — no more surface than that.
3. Add an optional parameter carrying the protocol type, defaulting to
   PAE's existing permissively-licensed behavior so every other consumer of
   PAE is unaffected.
4. Do not import, vendor, or link the GPL/LGPL library anywhere under
   `Sources/` in this repo. The conformance and everything it depends on
   belongs in the consuming app's own source tree.
5. Document the seam here (or extend this file) with a worked example, the
   same as the LAME one above.
