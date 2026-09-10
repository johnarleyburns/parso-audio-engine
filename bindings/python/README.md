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
and loudness services. Device IO, analysis, DJ control, and recording remain
separate native milestones.
