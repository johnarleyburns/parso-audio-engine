#!/usr/bin/env python3
"""Render a Parso acceptance sidecar and WAV as a reviewable MP4.

This is a developer-side visualization helper. ffmpeg is intentionally not a package
dependency and is not linked into the shipping Swift products.
"""

import argparse
import json
import shutil
import subprocess
import sys


FONT = {
    "A": "01110 10001 10001 11111 10001 10001 10001", "B": "11110 10001 10001 11110 10001 10001 11110",
    "C": "01111 10000 10000 10000 10000 10000 01111", "D": "11110 10001 10001 10001 10001 10001 11110",
    "E": "11111 10000 10000 11110 10000 10000 11111", "F": "11111 10000 10000 11110 10000 10000 10000",
    "G": "01111 10000 10000 10111 10001 10001 01111", "H": "10001 10001 10001 11111 10001 10001 10001",
    "I": "11111 00100 00100 00100 00100 00100 11111", "J": "00111 00010 00010 00010 10010 10010 01100",
    "K": "10001 10010 10100 11000 10100 10010 10001", "L": "10000 10000 10000 10000 10000 10000 11111",
    "M": "10001 11011 10101 10101 10001 10001 10001", "N": "10001 11001 10101 10011 10001 10001 10001",
    "O": "01110 10001 10001 10001 10001 10001 01110", "P": "11110 10001 10001 11110 10000 10000 10000",
    "Q": "01110 10001 10001 10001 10101 10010 01101", "R": "11110 10001 10001 11110 10100 10010 10001",
    "S": "01111 10000 10000 01110 00001 00001 11110", "T": "11111 00100 00100 00100 00100 00100 00100",
    "U": "10001 10001 10001 10001 10001 10001 01110", "V": "10001 10001 10001 10001 10001 01010 00100",
    "W": "10001 10001 10001 10101 10101 11011 10001", "X": "10001 10001 01010 00100 01010 10001 10001",
    "Y": "10001 10001 01010 00100 00100 00100 00100", "Z": "11111 00001 00010 00100 01000 10000 11111",
    "0": "01110 10001 10011 10101 11001 10001 01110", "1": "00100 01100 00100 00100 00100 00100 01110",
    "2": "01110 10001 00001 00010 00100 01000 11111", "3": "11110 00001 00001 01110 00001 00001 11110",
    "4": "00010 00110 01010 10010 11111 00010 00010", "5": "11111 10000 10000 11110 00001 00001 11110",
    "6": "01110 10000 10000 11110 10001 10001 01110", "7": "11111 00001 00010 00100 01000 01000 01000",
    "8": "01110 10001 10001 01110 10001 10001 01110", "9": "01110 10001 10001 01111 00001 00001 01110",
    ".": "00000 00000 00000 00000 00000 00110 00110", ":": "00000 00110 00110 00000 00110 00110 00000",
    "-": "00000 00000 00000 11111 00000 00000 00000", "/": "00001 00010 00010 00100 01000 01000 10000",
    "_": "00000 00000 00000 00000 00000 00000 11111", "(": "00010 00100 01000 01000 01000 00100 00010",
    ")": "01000 00100 00010 00010 00010 00100 01000", " ": "00000 00000 00000 00000 00000 00000 00000",
}


def color_for_section(kind):
    return {
        "intro": (30, 110, 190), "buildup": (180, 120, 30), "drop": (190, 45, 45),
        "verse": (50, 145, 100), "chorus": (130, 65, 175), "breakdown": (50, 120, 145),
        "outro": (100, 100, 120), "unknown": (70, 70, 80),
    }.get(kind, (70, 70, 80))


def put_pixel(frame, width, height, x, y, color):
    if 0 <= x < width and 0 <= y < height:
        offset = (y * width + x) * 3
        frame[offset:offset + 3] = bytes(color)


def rect(frame, width, height, x0, y0, x1, y1, color):
    x0, x1 = max(0, int(x0)), min(width, int(x1))
    y0, y1 = max(0, int(y0)), min(height, int(y1))
    if x1 <= x0 or y1 <= y0:
        return
    row = bytes(color) * (x1 - x0)
    for y in range(y0, y1):
        offset = (y * width + x0) * 3
        frame[offset:offset + len(row)] = row


def line(frame, width, height, x0, y0, x1, y1, color):
    x0, y0, x1, y1 = int(x0), int(y0), int(x1), int(y1)
    dx, sx = abs(x1 - x0), 1 if x0 < x1 else -1
    dy, sy = -abs(y1 - y0), 1 if y0 < y1 else -1
    error = dx + dy
    while True:
        put_pixel(frame, width, height, x0, y0, color)
        if x0 == x1 and y0 == y1:
            break
        twice = 2 * error
        if twice >= dy:
            error += dy
            x0 += sx
        if twice <= dx:
            error += dx
            y0 += sy


def text(frame, width, height, value, x, y, color=(220, 225, 235), scale=2):
    cursor = int(x)
    for character in value.upper():
        glyph = FONT.get(character, FONT[" "]).split()
        for row, bits in enumerate(glyph):
            for column, bit in enumerate(bits):
                if bit == "1":
                    rect(frame, width, height, cursor + column * scale, y + row * scale,
                         cursor + (column + 1) * scale, y + (row + 1) * scale, color)
        cursor += 6 * scale


def make_frame(artifact, width, height, now):
    frame = bytearray(bytes((16, 19, 27)) * (width * height))
    duration = max(float(artifact.get("audioDuration", 0)), 0.001)
    left, right = 48, width - 48
    plot_top, plot_bottom = 145, int(height * 0.65)
    plot_width = right - left
    text(frame, width, height, f"PARSO {artifact.get('fixtureID', 'TRACK')}", left, 28, scale=3)
    text(frame, width, height, f"SCENARIO {artifact.get('scenario', 'UNKNOWN')}", left, 78,
         color=(130, 185, 220), scale=2)
    text(frame, width, height,
         f"BPM {artifact.get('bpm', 0):.1f}  KEY {artifact.get('key', 'UNKNOWN')}  LUFS {artifact.get('loudnessLUFS', 0):.1f}",
         left, 105, color=(185, 195, 210), scale=1)

    # Phrase/section bands make boundaries visible even when the waveform is quiet.
    sections = artifact.get("sections", [])
    for index, section in enumerate(sections):
        start = float(section.get("start", 0))
        end = float(sections[index + 1].get("start", duration)) if index + 1 < len(sections) else duration
        x0, x1 = left + plot_width * start / duration, left + plot_width * end / duration
        color = color_for_section(section.get("kind", "unknown"))
        rect(frame, width, height, x0, plot_top - 20, x1, plot_bottom + 30,
             tuple(min(255, int(component * 0.35)) for component in color))
        if x1 - x0 > 55:
            text(frame, width, height, section.get("kind", "unknown"), x0 + 5, plot_top - 17,
                 color=color, scale=1)

    # Waveform overview: a frequency-colored min/max envelope. Rekordbox-style
    # RGB cues are useful during review: low = blue, mid = green, high = red.
    # Brightness is driven by the bucket's RMS and peak envelope, not by a
    # decorative animation, so quiet/high-frequency sections remain meaningful.
    waveform = artifact.get("waveform", [])
    center = (plot_top + plot_bottom) // 2
    half_height = (plot_bottom - plot_top) * 0.44
    if waveform:
        band_max = [max(float(point.get(name, 0)) for point in waveform) for name in ("low", "mid", "high")]
        rms_max = max(float(point.get("rms", 0)) for point in waveform)
        for index, point in enumerate(waveform):
            x = left + (index / max(1, len(waveform) - 1)) * plot_width
            y_min = center - float(point.get("max", 0)) * half_height
            y_max = center - float(point.get("min", 0)) * half_height
            bands = [max(0.0, float(point.get(name, 0))) / maximum
                     if maximum > 0 else 0.0
                     for name, maximum in zip(("low", "mid", "high"), band_max)]
            band_total = sum(bands)
            if band_total > 0:
                blue, green, red = (bands[0] / band_total, bands[1] / band_total, bands[2] / band_total)
            else:
                blue, green, red = 0.34, 0.33, 0.33
            peak = max(abs(float(point.get("min", 0))), abs(float(point.get("max", 0))))
            rms = max(0.0, float(point.get("rms", 0))) / rms_max if rms_max > 0 else 0.0
            intensity = min(1.0, 0.25 + 0.45 * min(1.0, peak) + 0.30 * rms)
            color = (
                int(35 + 220 * red * intensity),
                int(35 + 220 * green * intensity),
                int(35 + 220 * blue * intensity),
            )
            line(frame, width, height, x, y_min, x, y_max, color)

    # Beatgrid markers. Downbeats are thicker/brighter.
    downbeats = {round(float(value), 4) for value in artifact.get("downbeats", [])}
    for beat in artifact.get("beats", []):
        beat = float(beat)
        if beat < 0 or beat > duration:
            continue
        x = left + plot_width * beat / duration
        is_downbeat = any(abs(beat - downbeat) < 0.01 for downbeat in downbeats)
        marker_color = (245, 215, 90) if is_downbeat else (75, 105, 135)
        marker_top = plot_top - (38 if is_downbeat else 12)
        line(frame, width, height, x, marker_top, x, plot_bottom + 22, marker_color)

    line(frame, width, height, left, center, right, center, (45, 55, 70))
    cursor_x = left + plot_width * min(max(now / duration, 0), 1)
    line(frame, width, height, cursor_x, plot_top - 42, cursor_x, plot_bottom + 35, (255, 255, 255))
    text(frame, width, height, f"TIME {now:06.2f} / {duration:06.2f}", left, height - 75,
         color=(230, 235, 245), scale=2)
    text(frame, width, height, "DOWNBEAT", right - 170, height - 75, color=(245, 215, 90), scale=1)
    return frame


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audio", required=True, help="WAV produced by ParsoAcceptanceArtifacts")
    parser.add_argument("--analysis", required=True, help="JSON sidecar produced by ParsoAcceptanceArtifacts")
    parser.add_argument("--output", required=True, help="MP4 output path")
    parser.add_argument("--fps", type=int, default=30)
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=720)
    args = parser.parse_args()
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        parser.error("ffmpeg is required for video output; install it as a developer tool")
    with open(args.analysis, "r", encoding="utf-8") as stream:
        artifact = json.load(stream)
    duration = max(0.001, float(artifact.get("audioDuration", 0)))
    frame_count = max(1, int(duration * args.fps + 0.999))
    command = [
        ffmpeg, "-y", "-loglevel", "error",
        "-f", "image2pipe", "-vcodec", "ppm", "-r", str(args.fps), "-i", "-",
        "-i", args.audio, "-map", "0:v:0", "-map", "1:a:0", "-t", f"{duration:.6f}",
        "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-b:a", "192k", args.output,
    ]
    try:
        process = subprocess.Popen(command, stdin=subprocess.PIPE)
        assert process.stdin is not None
        for index in range(frame_count):
            now = min(duration, index / args.fps)
            frame = make_frame(artifact, args.width, args.height, now)
            process.stdin.write(f"P6\n{args.width} {args.height}\n255\n".encode("ascii"))
            process.stdin.write(frame)
        process.stdin.close()
        result = process.wait()
    except BrokenPipeError:
        result = process.wait()
    if result != 0:
        raise SystemExit(f"ffmpeg failed with exit code {result}")
    print(args.output)


if __name__ == "__main__":
    main()
