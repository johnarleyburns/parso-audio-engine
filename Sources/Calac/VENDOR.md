# AppleALAC vendored codec

This target vendors the codec implementation from
`https://github.com/macosforge/alac` at revision
`c38887c5c5e64a4b31108733bd79ca9b2496d987`.

The selected codec source files carry Apple Apache License 2.0 headers and are
distributed with the upstream Apache-2.0 `LICENSE` file. The converter utility,
its file/container code, build artifacts, and the separate `APPLE_LICENSE.txt`
file are not part of this target. Container parsing and muxing remain a
separate layer.

The files under `vendor/codec` are unmodified upstream sources. The C-clean
wrapper in `include/` and `src/` is first-party MIT-licensed code and does not
expose the upstream C++ classes through the module interface.
