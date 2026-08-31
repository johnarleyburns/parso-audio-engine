# Vendoring Ogg Vorbis decode (stb_vorbis, Public Domain / MIT-0)
Drop `stb_vorbis.c` and its header into src/ + include/ (single-file decoder).
Expose a tiny C-clean shim in include/ if you prefer (e.g. `parso_vorbis_decode(path, ...)`).
Alternative (BSD): libogg + libvorbis + libvorbisfile. Remove shim + placeholder.
Source: https://github.com/nothings/stb

Source commit: `2c980bb59875b0d32144a71867fbdebb2f77cd20`

Vendored files:
- `include/stb_vorbis.inc` (unmodified upstream `stb_vorbis.c` single-file decoder;
  the `.inc` suffix prevents SwiftPM from compiling the same implementation twice)
- `LICENSE` (unmodified upstream dual MIT / public-domain license)

`include/stb_vorbis.h` selects the decoder's supported declaration-only mode;
`src/stb_vorbis_impl.c` creates the single implementation translation unit.
