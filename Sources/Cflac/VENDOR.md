# Vendoring libFLAC (native FLAC only)

Vendored from the upstream `1.4.3` release tag (`28e4f0528c76b296c561e922ba67d43751990599`).
The libFLAC C sources and public/private headers are unmodified. Ogg mapping sources are excluded,
so this target has no libogg dependency. `COPYING.Xiph` is retained as the upstream BSD-3-Clause
license.
