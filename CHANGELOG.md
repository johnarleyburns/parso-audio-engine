# Changelog

All notable changes are documented here. Format: Keep a Changelog; scheme: SemVer.
The public API is **unstable (0.x)** until it has been validated by a first real integration
(see docs/SPEC.md §17).

## [Unreleased]
### Added
- Initial repository scaffold: three SPM library products (ParsoAudioCore, ParsoAudioAnalysis, ParsoDJEngine).
- Full engineering specification (docs/SPEC.md), FLX4 feature target (docs/FLX4-feature-inventory.md), sourcing map (docs/audio-library-sourcing.md).
- Extensive test suite (synthetic + real Creative Commons fixtures) as executable specification.
- Decode support scope: FLAC (libFLAC), Ogg Vorbis (stb_vorbis), Opus (libopus/libopusfile), plus Apple-native MP3/AAC/ALAC/WAV/AIFF/CAF.
- Fixtures pipeline for Creative Commons House / disco / hip-hop tracks (download only; library decodes natively).
