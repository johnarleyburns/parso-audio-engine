# Portable ALAC status

The Apple public-source ALAC implementation previously present in this target
was removed on 2026-09-02 after legal review. The upstream Apache-2.0 headers
remain only because that review permits retaining the declarations; they are not
compiled or linked. No implementation code from Apple's public-source ALAC
repository is used by this project.

`include/parso_alac.h` and `src/parso_alac.cpp` are first-party C API material.
The current bridge deliberately reports portable ALAC as unavailable. A future
replacement must be independently authored and use only the project's approved
BSD-only permissive dependency policy. Until then, Apple platforms use
AudioToolbox for ALAC and Linux rejects portable ALAC encoding/decoding.
