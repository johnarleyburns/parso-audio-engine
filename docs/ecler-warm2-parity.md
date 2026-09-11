# Ecler WARM2 isolator parity

The Ecler WARM2 is a two-channel analogue rotary DJ mixer with three large
master isolator controls. Ecler specifies the isolator as 4th-order, 24 dB/oct,
with crossover points at 300 Hz and 4 kHz and ranges of BASS `+12/-70 dB`, MID
`+12/-40 dB`, and TREBLE `+12/-70 dB`. The official product page also describes
the main-channel EQ as separate from this isolator.

Sources: [official WARM2 product page](https://www.eclerdj.com/products/warm-2/),
[official WARM2 user manual](https://www.ecler.com/images/downloads/user-manuals/Ecler_WARM2_User_Manual_EN.pdf).

## Current engine match

The engine supports the control concept and the important interaction model:

- `CParsoEngine` already has a global, post-fader/pre-limiter three-band
  isolator (`master_eq_low`, `master_eq_mid`, `master_eq_high`).
- `CParsoDSP` smooths each band over 10 ms and accepts full cuts plus boost.
- Swift `MasterOut` already publishes these controls.
- The public C ABI and Python facade now expose the same master isolator fields,
  together with channel EQ, Beat FX, reverb, and deck tempo/key-lock controls.

This is functional isolator support, but not yet a circuit-level WARM2 match.
The portable kernel currently instantiates its RBJ three-band network at 200 Hz
and 2 kHz, and its current low/high sections are single biquads rather than an
explicit 4th-order 24 dB/oct WARM2 crossover implementation. The existing API
also does not yet expose the isolator crossover profile as an engine option.

## Recommended next slice

Add an `isolator_profile`/crossover configuration to engine creation, with a
`generic` default preserving the current 200 Hz/2 kHz behavior and a `warm2`
profile selecting 300 Hz/4 kHz. Implement the WARM2 profile as fixed, resident
fourth-order crossover sections (or cascaded biquads) with the same 5–20 ms
parameter smoothing and RT-safe state. Keep the three-band dB controls in the
existing control snapshot, and add a focused frequency-response/gain-sweep test
plus a real-MP3 human artifact that turns each large knob through cut, centre,
and boost.

That shape is more natural than making callers reconstruct filter coefficients:
the application selects a mixer profile at engine creation, while the audio
thread receives only smoothed band targets.
