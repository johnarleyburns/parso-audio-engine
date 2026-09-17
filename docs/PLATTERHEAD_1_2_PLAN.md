# Platterhead 1.2.0 implementation plan

This release keeps the existing layered package intact while adding the
Transition Lab workflow:

1. `ParsoAudioAnalysis` owns the versioned scalar analysis cache, staged
   cancellation, and phrase-local descriptors.
2. `ParsoDJEngine` owns transition proposals, explainable clash metrics,
   sample-clock SmartFader recipes, offline previews, host graph ownership,
   the two-deck `transitionLab` profile, and preparation snapshots.
3. `ParsoAudioNeural` exposes only reusable similarity math over the existing
   caller-owned `SemanticModel` seam. No checkpoint or new model protocol is
   introduced.
4. CParsoEngine consumes scheduled scalar transition recipes from its native
   master-frame clock, so live rendering and headless tests share the timing
   source.

The release acceptance path is: analyze → persist/restore → rank → preview →
arm → render without display-link ticking → snapshot/restore. Generated real-
audio previews belong outside the repository. The existing optional
`scripts/generate-linux-tts-review.sh` can prepend spoken review cues without
modifying authoritative WAV artifacts.
