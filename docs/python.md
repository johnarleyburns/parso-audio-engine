# Python binding

The initial Python binding lives in `bindings/python` and uses only the Python
standard library (`ctypes` plus `array`) to call the versioned C ABI. It does
not bundle or download a native library. Use a CMake install, a system
`libparso`, or set `PARSO_AUDIO_LIBRARY` to an explicit shared-library path.

## Quickstart

```python
from parso_audio import AudioCodec, CodecServices

with CodecServices() as audio:
    capabilities = audio.capabilities
    encoded = audio.encode(samples, 48_000, 2, AudioCodec.OGG_VORBIS)
    decoded = audio.decode(encoded, AudioCodec.OGG_VORBIS)
    print(decoded.frames, decoded.channel_count, decoded.sample_rate_hz)
```

`encode` accepts an iterable or a contiguous one-dimensional buffer of
numeric samples and copies it into temporary native-call storage. `decode`
returns an `array('f')` in `DecodedPcm`; native-owned buffers are released
before the call returns. `CodecServices.close()` is idempotent and operations
after close raise `ParsoError`.

The current offline gate covers WAV, FLAC, Xiph Ogg Vorbis, Opus, MP3, and AAC
where the loaded native capability bits advertise them. ALAC, AIFF, CAF,
analysis, DJ controls, recording, and device IO remain explicit future gates.

## Local verification

After building the native package with CMake:

```bash
PYTHONPATH=bindings/python python3 -m unittest discover \
  -s bindings/python/tests -v
PARSO_AUDIO_LIBRARY="$PWD/build-native/libparso.so" \
  PYTHONPATH=bindings/python python3 bindings/python/examples/vorbis_roundtrip.py
```

The package's `pyproject.toml` builds a pure-Python wheel. Native artifacts
are intentionally supplied by the platform package rather than embedded in
that wheel; wheel installation and native-library discovery remain packaging
matrix work for CP-PY.
