"""Small helpers shared by the Linux human-listening acceptance tools."""

from __future__ import annotations

import math


def mp3_prefix(data: bytes, minimum_seconds: float, padding_seconds: float = 2.0) -> bytes:
    """Return an MP3 prefix containing the requested decoded duration.

    The portable Glint decoder is whole-buffer based and intentionally does not
    seek. Human-review artifacts only need the opening portion of a track, so
    trimming at a complete MPEG frame keeps the acceptance run bounded while
    still exercising the real MP3 decoder and source music.
    """

    if minimum_seconds <= 0.0 or not math.isfinite(minimum_seconds):
        raise ValueError("minimum_seconds must be finite and positive")
    if padding_seconds < 0.0 or not math.isfinite(padding_seconds):
        raise ValueError("padding_seconds must be finite and non-negative")
    if len(data) < 4:
        raise ValueError("MP3 data is too short")

    offset = 0
    if data[:3] == b"ID3" and len(data) >= 10:
        tag_size = sum((data[index] & 0x7F) << shift
                       for index, shift in zip(range(6, 10), (21, 14, 7, 0)))
        offset = 10 + tag_size
        if offset > len(data):
            raise ValueError("MP3 ID3 tag extends past the input")

    samples = 0
    target_samples = 0
    last_frame_end = offset
    bitrate_v1 = (0, 32, 40, 48, 56, 64, 80, 96, 112, 128,
                  160, 192, 224, 256, 320)
    bitrate_v2 = (0, 8, 16, 24, 32, 40, 48, 56,
                  64, 80, 96, 112, 128, 144, 160)
    sample_rates_v1 = (44_100, 48_000, 32_000)

    while offset + 4 <= len(data):
        if data[offset] != 0xFF or data[offset + 1] & 0xE0 != 0xE0:
            offset += 1
            continue
        version = (data[offset + 1] >> 3) & 0x03
        layer = (data[offset + 1] >> 1) & 0x03
        bitrate_index = data[offset + 2] >> 4
        sample_rate_index = (data[offset + 2] >> 2) & 0x03
        if version == 1 or layer != 1 or bitrate_index in (0, 15) or sample_rate_index == 3:
            offset += 1
            continue

        sample_rate = sample_rates_v1[sample_rate_index]
        bitrate = bitrate_v1[bitrate_index] if version == 3 else bitrate_v2[bitrate_index]
        if version == 2:
            sample_rate //= 2
        elif version == 0:
            sample_rate //= 4
        frame_bytes = (144_000 if version == 3 else 72_000) * bitrate // sample_rate
        frame_bytes += (data[offset + 2] >> 1) & 1
        if frame_bytes <= 0 or offset + frame_bytes > len(data):
            break

        samples_per_frame = 1_152 if version == 3 else 576
        if target_samples == 0:
            target_samples = math.ceil((minimum_seconds + padding_seconds) * sample_rate)
        samples += samples_per_frame
        last_frame_end = offset + frame_bytes
        offset = last_frame_end
        if samples >= target_samples:
            return data[:last_frame_end]

    raise ValueError("MP3 input does not contain the requested number of complete frames")
