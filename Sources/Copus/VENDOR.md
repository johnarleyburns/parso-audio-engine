# Vendoring Opus decode (BSD-3)

Vendored from these upstream release tags:

- libogg `v1.3.5` (`65b355cc20171010ecabf245e7b339aeab8ddbb9`)
- libopus `v1.5.2` (`5ec2f3c915d0529b94a3a302969c673531654824`)
- libopusfile `v0.12` (`0c237f414280000141a0fc0b21b17f12c8ae5ae0`)

The native C sources and public/internal headers are unmodified. The optional platform-specific
assembly, SIMD, examples, and tests are not compiled. Each upstream license is retained as
`COPYING.ogg`, `COPYING.opus`, and `COPYING.opusfile`.
