//
//  SeparationBackendRegistry.swift
//  Runtime-swappable selection of the active stem-separation backend
//  (Phase 7c, current_status.md "Phase 7"). New in this session — not a port.
//
//  Why this exists: source-separation model licensing is an active, moving
//  legal question (see current_status.md's "Phase 7" citation trail). The
//  app must be able to change which model it uses — including swapping to a
//  future model — without a code change or a new App Store review cycle for
//  the separation *logic* itself (only the weights and the registration
//  change). `StemModelProviding` (Separation.swift) was already
//  model-agnostic; this registry is the piece that makes the *choice* of
//  conformance a runtime value instead of a call-site literal.
//
//  Default: `.spleeter` (Deezer's Spleeter, MIT-licensed code and weights —
//  see SpleeterStemModel.swift's header and current_status.md "Phase 7" for
//  the author's licensing determination and its limitations). The eventual
//  target, once a cleanly-licensed release exists, is a BS-RoFormer-class
//  model — materially better separation quality for DJ-grade stem isolation
//  than Spleeter's 2018-era U-Net. Registering one is exactly this file's
//  job: implement `StemModelProviding`, register it under a new
//  `SeparationBackendID`, and (optionally) call `setActive` — no other code
//  in the separation pipeline changes.
//
#if !os(watchOS)
import Foundation

/// Identifies one registered separation backend. `spleeter` is the shipping
/// default; a host app can register and activate any number of others.
public struct SeparationBackendID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Deezer's Spleeter (MIT code + weights). See SpleeterStemModel.swift.
    public static let spleeter = SeparationBackendID(rawValue: "spleeter")
}

public enum SeparationBackendError: Error, LocalizedError, Equatable {
    case unregistered(SeparationBackendID)

    public var errorDescription: String? {
        switch self {
        case .unregistered(let id):
            return "No separation backend is registered for '\(id.rawValue)'"
        }
    }
}

/// Owns the set of available `StemModelProviding` factories and which one is
/// currently active. A factory, not an instance, is registered — the actor
/// builds a fresh model only when a backend actually becomes active, so
/// registering a backend costs nothing until it is used.
///
/// This is the whole swap mechanism: changing which model runs is
/// `setActive(_:)` with a different registered id — no other type in the
/// separation pipeline (`StemSeparator`, `StemChunking`, a caller's cache)
/// knows or cares which backend is behind the protocol.
public actor SeparationBackendRegistry {
    private var factories: [SeparationBackendID: @Sendable () -> any StemModelProviding] = [:]
    private var active: SeparationBackendID

    public init(default defaultID: SeparationBackendID = .spleeter) {
        self.active = defaultID
    }

    /// Register (or replace) a backend's factory. Registering the currently
    /// active id's factory takes effect on the next `activeModel()` call.
    public func register(_ id: SeparationBackendID,
                         factory: @escaping @Sendable () -> any StemModelProviding) {
        factories[id] = factory
    }

    public func unregister(_ id: SeparationBackendID) {
        factories[id] = nil
    }

    public var registeredIDs: [SeparationBackendID] { Array(factories.keys) }

    public var activeID: SeparationBackendID { active }

    /// Switch the active backend. Throws if `id` has no registered factory —
    /// callers should register every backend they intend to offer before
    /// letting a setting reach here.
    public func setActive(_ id: SeparationBackendID) throws {
        guard factories[id] != nil else { throw SeparationBackendError.unregistered(id) }
        active = id
    }

    /// Build a fresh instance of the currently active backend.
    public func activeModel() throws -> any StemModelProviding {
        guard let factory = factories[active] else {
            throw SeparationBackendError.unregistered(active)
        }
        return factory()
    }

    /// Build a fresh instance of a specific backend, regardless of which is active.
    public func model(for id: SeparationBackendID) throws -> any StemModelProviding {
        guard let factory = factories[id] else {
            throw SeparationBackendError.unregistered(id)
        }
        return factory()
    }
}
#endif
