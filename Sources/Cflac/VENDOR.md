# Vendoring libFLAC

1. Download a tagged libFLAC release (e.g. 1.4.x) from https://xiph.org/flac/.
2. Copy `src/libFLAC/*.c` into `src/` and `include/FLAC/*.h` + `include/share/*` into `include/`.
3. Native FLAC only: exclude `ogg_*.c` and any Ogg mapping; do not add libogg.
4. Keep the upstream `COPYING.Xiph` (BSD-3) here. Record the source commit below.
5. Delete `cflac_shim.h` and `placeholder.c`.

Source commit: <fill in>
