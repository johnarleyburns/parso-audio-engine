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
- The public C ABI and Python facade expose the same master isolator fields,
  together with channel EQ, Beat FX, reverb, and deck tempo/key-lock controls.
- `PE_ISOLATOR_PROFILE_WARM2` / `IsolatorProfile.WARM2` now selects 300 Hz and
  4 kHz fourth-order band splits for the master isolator.

The generic profile remains the existing 200 Hz/2 kHz RBJ three-band network.
The WARM2 profile uses cascaded second-order Butterworth sections for explicit
fourth-order (24 dB/octave) low/mid/high band splits and the WARM2 gain ranges.
It is a digital behavioral match, not a component-level analogue circuit model.

## Future refinement

The remaining refinement is hardware calibration: compare frequency-response
measurements from a physical WARM2 and tune the digital section Q, summing, and
headroom if the goal is waveform-level rather than control-level equivalence.

That shape is more natural than making callers reconstruct filter coefficients:
the application selects a mixer profile at engine creation, while the audio
thread receives only smoothed band targets.
