# Vendoring Xiph Ogg Vorbis encode/decode

Vendored from the upstream `libvorbis-1.3.7` release (`0657aee69dec8508a0011f47f3b69d7538e9d262f`).
The target includes the reference `libvorbis`, `libvorbisenc`, and `libvorbisfile` sources under
`xiph/`, with the upstream `COPYING` retained beside them. Its Ogg dependency is the separate
`Cogg` target, vendored from libogg 1.3.5 and recorded in `Sources/Cogg/VENDOR.md`.

The public bridge uses `libvorbisfile` for decoding and `libvorbis`/`libvorbisenc` for encoding.
This replaces the former `stb_vorbis` decode-only implementation; no GPL encoder is required or
linked. The generated `xiph/src/config.h` contains only build-feature defaults and is not upstream
codec implementation code.
