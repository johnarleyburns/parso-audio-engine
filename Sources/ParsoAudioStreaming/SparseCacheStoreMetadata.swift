import Foundation

extension SparseCacheStore {
        // MARK: - Metadata
    
        public struct Meta: Codable, Sendable, Equatable {
            public var totalBytes: Int64?
            public var cachedBytes: Int64
            public var complete: Bool
            public var lastAccessedAt: Date
            public var createdAt: Date
            public var rangeMap: ByteRangeMap
            /// Free-form entry tag. `nil` decodes as `"audio"` for legacy JSON.
            public var kind: String?
            /// `nil`/`false` decodes as an evictable (streaming) entry.
            public var durable: Bool?
            /// Byte size of each named derived artifact sitting beside the blob.
            public var derivedBytes: [String: Int64]?
    
            public var effectiveKind: String { kind ?? "audio" }
            public var isDurable: Bool { durable ?? false }
            public var derivedTotal: Int64 { (derivedBytes ?? [:]).values.reduce(0, +) }
    
            public init(totalBytes: Int64?, cachedBytes: Int64, complete: Bool,
                        lastAccessedAt: Date, createdAt: Date, rangeMap: ByteRangeMap,
                        kind: String? = nil, durable: Bool? = nil,
                        derivedBytes: [String: Int64]? = nil) {
                self.totalBytes = totalBytes
                self.cachedBytes = cachedBytes
                self.complete = complete
                self.lastAccessedAt = lastAccessedAt
                self.createdAt = createdAt
                self.rangeMap = rangeMap
                self.kind = kind
                self.durable = durable
                self.derivedBytes = derivedBytes
            }
    
            // Lenient decode: a partly-written or older-schema metadata file must not
            // throw (a silent decode failure would drop a user's cached entry).
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let now = Date()
                totalBytes = try c.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? nil
                cachedBytes = try c.decodeIfPresent(Int64.self, forKey: .cachedBytes) ?? 0
                complete = try c.decodeIfPresent(Bool.self, forKey: .complete) ?? false
                lastAccessedAt = try c.decodeIfPresent(Date.self, forKey: .lastAccessedAt) ?? now
                createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? now
                rangeMap = try c.decodeIfPresent(ByteRangeMap.self, forKey: .rangeMap) ?? ByteRangeMap()
                kind = try c.decodeIfPresent(String.self, forKey: .kind)
                durable = try c.decodeIfPresent(Bool.self, forKey: .durable)
                derivedBytes = try c.decodeIfPresent([String: Int64].self, forKey: .derivedBytes)
            }
        }
    
}

