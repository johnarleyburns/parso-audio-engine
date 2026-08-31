# Vendoring Ogg Vorbis decode (stb_vorbis, Public Domain / MIT-0)
Drop `stb_vorbis.c` and its header into src/ + include/ (single-file decoder).
Expose a tiny C-clean shim in include/ if you prefer (e.g. `parso_vorbis_decode(path, ...)`).
Alternative (BSD): libogg + libvorbis + libvorbisfile. Remove shim + placeholder.
Source: https://github.com/nothings/stb  — commit: <fill in>
