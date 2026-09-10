# Python binding

The initial Python binding lives in `bindings/python` and uses only the Python
standard library (`ctypes` plus `array`) to call the versioned C ABI. It does
not bundle or download a native library. Use a CMake install, a system
`libparso`, or set `PARSO_AUDIO_LIBRARY` to an explicit shared-library path.

## Quickstart

```python
from parso_audio import AudioCodec, CodecServices, Engine

with CodecServices() as audio:
    capabilities = audio.capabilities
    encoded = audio.encode(samples, 48_000, 2, AudioCodec.OGG_VORBIS)
    decoded = audio.decode(encoded, AudioCodec.OGG_VORBIS)
    print(decoded.frames, decoded.channel_count, decoded.sample_rate_hz)

with Engine(max_frames=512) as engine:
    engine.set_deck_buffer(0, samples, 48_000, 2)
    engine.play(0)
    left, right = engine.render(256)
    print(engine.stats().master_frame)
```

`encode` accepts an iterable or a contiguous one-dimensional buffer of
numeric samples and copies it into temporary native-call storage. `decode`
returns an `array('f')` in `DecodedPcm`; native-owned buffers are released
before the call returns. `CodecServices.close()` is idempotent and operations
after close raise `ParsoError`.

The current offline gate covers WAV, FLAC, Xiph Ogg Vorbis, Opus, MP3, and AAC
where the loaded native capability bits advertise them. `convert_sample_rate`
and `measure_loudness` expose the native SRC and EBU R128 services. ALAC,
AIFF, CAF, analysis, DJ controls, recording, and device IO remain explicit
future gates.

`Engine` provides bounded stereo headless rendering and a master-level control;
`set_deck_buffer` copies and retains planar channel storage until replacement or
close, and `play`/`pause` queue the portable transport commands. `post_command`
exposes the versioned command payload (`i0`/`i1`/`i2` and `f0`/`f1`) for the
shared native transport, with convenience methods for absolute seek, key-lock,
and slip. Device IO,
analysis, broader DJ controls, and recording remain explicit future gates.

## Local verification

After building the native package with CMake:

```bash
PYTHONPATH=bindings/python python3 -m unittest discover \
  -s bindings/python/tests -v
PARSO_AUDIO_LIBRARY="$PWD/build-native/libparso.so" \
  PYTHONPATH=bindings/python python3 bindings/python/examples/vorbis_roundtrip.py
PARSO_AUDIO_LIBRARY="$PWD/build-native/libparso.so" \
  PYTHONPATH=bindings/python python3 bindings/python/examples/render_acceptance.py \
  --output-dir /tmp/parso-python-acceptance
```

The package's `pyproject.toml` builds a pure-Python wheel. Native artifacts
are intentionally supplied by the platform package rather than embedded in
that wheel. CI installs that wheel in a fresh virtual environment and runs its
tests against the CMake-built native library; local installation requires a
Python distribution that includes `pip` and `venv`.

`render_acceptance.py` is a small offline acceptance seam, not the completed
FLX4 scenario runner: it renders the native engine for at least 30 seconds,
drains the actual stereo output through the native record ring, encodes it as
WAV through `CodecServices`, and writes the matching duration/event sidecar.
Full analysis, DJ scenarios, and human review remain later acceptance work.
