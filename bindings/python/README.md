# parso-audio

The Python binding uses the versioned Parso C ABI through the standard-library
`ctypes` module. The package does not bundle a native library: pass its path to
`CodecServices`, set `PARSO_AUDIO_LIBRARY`, or install `libparso` where the
platform loader can find it.

```python
from parso_audio import AudioCodec, CodecServices

with CodecServices("/path/to/libparso.so") as audio:
    encoded = audio.encode(samples, 48_000, 2, AudioCodec.OGG_VORBIS)
    decoded = audio.decode(encoded, AudioCodec.OGG_VORBIS)
```

This initial package covers synchronous offline codec, sample-rate conversion,
loudness, and bounded headless rendering services. `Engine.set_crossfader(position)`
publishes an A/B mixer snapshot with a bounded position in `[-1, 1]`; the extended
`Engine.set_mixer_controls(...)` surface publishes channel EQ, color FX, Beat FX,
master reverb, deck mix controls, and `IsolatorProfile.WARM2` engine topology for deterministic listening scenarios. The Linux
acceptance renderer can load real MP3 fixtures into both decks:

```bash
./scripts/download-fixtures.sh
python3 bindings/python/examples/render_acceptance.py \
  --library build-native/libparso.so \
  --scenario crossfader-sweep \
  --output-dir /tmp/parso-python-music \
  --seconds 30 \
  --input-mp3-a Tests/Fixtures/audio/gostreyshen_world.mp3 \
  --input-mp3-b Tests/Fixtures/audio/tea_roots_isrc_usuan1100472.mp3 \
  --fixture-a gostreyshen_world \
  --fixture-b tea_roots_isrc_usuan1100472
```

Device IO remains a platform milestone; analysis, DJ control, and recording are
native services surfaced through this facade.

For analysis and notebook workflows, install the optional NumPy extra:

```bash
python -m pip install 'parso-audio[numpy]'
```

`DecodedPcm.as_numpy()` returns a `(frames, channels)` float32 array. By default
it is a read-only zero-copy view over the decoded PCM; use `copy=True` when a
writable array or independent lifetime is required. NumPy is not needed by the
core binding or by real-time rendering.
