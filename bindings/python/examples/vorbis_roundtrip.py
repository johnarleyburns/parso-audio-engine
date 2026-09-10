"""Encode and decode a short tone through the installed native library."""

import math
import os

from parso_audio import AudioCodec, CodecServices


library = os.environ.get("PARSO_AUDIO_LIBRARY")
with CodecServices(library) as audio:
    tone = [0.25 * math.sin(2.0 * math.pi * 440.0 * i / 48_000.0) for i in range(4_800)]
    encoded = audio.encode(tone, 48_000, 1, AudioCodec.OGG_VORBIS)
    decoded = audio.decode(encoded, AudioCodec.OGG_VORBIS)
    print(f"decoded {decoded.frames} frames at {decoded.sample_rate_hz} Hz")
