# Vendoring Opus decode (BSD-3)
Vendor three upstream libraries (all BSD-3):
  - libogg      https://github.com/xiph/ogg
  - libopus     https://github.com/xiph/opus
  - libopusfile https://github.com/xiph/opusfile   (high-level .opus file reader: op_open_file / op_read_float)
Place their C sources under src/ and public headers under include/. libopusfile depends on libogg+libopus.
Keep each upstream COPYING/LICENSE. Remove shim + placeholder.
Source commits: <fill in>
