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
publishes an A/B mixer snapshot with a bounded position in `[-1, 1]`; the
acceptance renderer can exercise the same two-deck timeline as the native runner:

```bash
python3 bindings/python/examples/render_acceptance.py \
  --library build-native/libparso.so \
  --scenario crossfader-sweep \
  --output-dir /tmp/parso-python-crossfader
```

Device IO remains a platform milestone; analysis, DJ control, and recording are
native services surfaced through this facade.
