import Foundation

extension SparseCacheStore {
        // MARK: - Accounting
    
        public func currentLimit() -> Int64 { limitBytes }
    
        public func setLimit(_ bytes: Int64) async {
            limitBytes = bytes
            await evictToFit(protecting: nil)
        }
    
        /// Streaming-budget total: durable entries are excluded.
        public func totalCachedBytes() -> Int64 {
            metas.values
                .filter { !$0.isDurable }
                .reduce(0) { $0 + $1.cachedBytes + $1.derivedTotal }
        }
    
        public func totalStoredBytes() -> Int64 {
            metas.values.reduce(0) { $0 + $1.cachedBytes + $1.derivedTotal }
        }
    
        public func contains(_ key: String) -> Bool { metas[key] != nil }
    
        public func isComplete(_ key: String) -> Bool { completeFileURL(for: key) != nil }
    
        public func isDurable(_ key: String) -> Bool { metas[key]?.isDurable ?? false }
    
        public func meta(for key: String) -> Meta? { metas[key] }
    
        /// Count of complete entries, optionally filtered to one kind.
        public func completeEntryCount(kind: String? = nil) -> Int {
            metas.values.filter { $0.complete && (kind == nil || $0.effectiveKind == kind) }.count
        }
    
        public func durableEntryCount() -> Int {
            metas.values.filter { $0.isDurable }.count
        }
    
        public func rangeMap(for key: String) -> ByteRangeMap {
            metas[key]?.rangeMap ?? ByteRangeMap()
        }
    
        public func totalBytes(for key: String) -> Int64? { metas[key]?.totalBytes }
    
        public func fileURL(for key: String) -> URL { root(for: key).blobURL(key) }
    
        public func derivedURL(for key: String, name: String) -> URL {
            root(for: key).derivedURL(key, name)
        }
    
        public func hasDerived(for key: String, name: String) -> Bool {
            FileManager.default.fileExists(atPath: derivedURL(for: key, name: name).path)
        }
    
        /// A real on-disk URL only when metadata and blob agree on a complete file.
        /// Repairs metadata that trusted a response length rather than the finished
        /// file's actual size; clears metadata whose blob was purged/truncated.
        public func completeFileURL(for key: String) -> URL? {
            guard let meta = metas[key], meta.complete else { return nil }
            let url = fileURL(for: key)
            guard let size = Self.fileSize(url), size > 0 else {
                discardCachedBytes(for: key)
                return nil
            }
            if meta.totalBytes != size || meta.cachedBytes != size || !meta.rangeMap.covers(total: size) {
                var repaired = meta
                var map = ByteRangeMap()
                map.insert(0..<size)
                repaired.totalBytes = size
                repaired.cachedBytes = size
                repaired.rangeMap = map
                repaired.complete = true
                repaired.lastAccessedAt = Date()
                metas[key] = repaired
                persistMeta(key)
            }
            touch(key)
            return url
        }
    
        /// Contiguous cached bytes from `offset` that a readable file actually backs.
        public func cachedContiguousBytes(for key: String, from offset: Int64) -> Int64 {
            guard let meta = metas[key] else { return 0 }
            let contiguous = meta.rangeMap.contiguousBytes(from: offset)
            guard contiguous > 0 else { return 0 }
            guard let size = Self.fileSize(fileURL(for: key)), size >= offset + contiguous else {
                discardCachedBytes(for: key)
                return 0
            }
            touch(key)
            return contiguous
        }
    }

