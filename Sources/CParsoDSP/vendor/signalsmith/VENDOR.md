# Vendoring Signalsmith Stretch (MIT)

The headers in this directory are unmodified upstream single-header sources.
`signalsmith-stretch.h` depends on the vendored Signalsmith Linear headers in
`signalsmith-linear/`; the root Linear headers are kept alongside them because
the upstream forwarding headers include those files relatively.

Enable Accelerate FFT via the `SIGNALSMITH_USE_ACCELERATE` define (already set in Package.swift).
Keep the upstream licenses. Upstream sources:

- Stretch: https://github.com/Signalsmith-Audio/signalsmith-stretch
  commit `57b93f4e9206a089a45387eaa39bdc9f310d3308`
- Linear: https://github.com/Signalsmith-Audio/linear
  commit `ec38d3332c7e9ce88a2fd969003d170baa2316b6`
