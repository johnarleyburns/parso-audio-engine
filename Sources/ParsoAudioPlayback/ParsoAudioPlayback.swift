//
//  ParsoAudioPlayback.swift
//  Shared listening-path audio: graphic EQ, loudness normalization, crossfade,
//  silence detection and audio-session policy — the pieces Tonearm and Voxglass
//  each grew independently (docs/UNIFICATION_PLAN.md §3).
//

import Foundation

/// Marker for the playback layer's version, so consumers can assert they linked
/// the layer they expected during the migration.
public enum ParsoAudioPlaybackLayer {
    public static let layerVersion = 1
}
