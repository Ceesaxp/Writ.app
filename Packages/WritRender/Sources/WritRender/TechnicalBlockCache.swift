import Foundation
import WritCore

/// In-memory LRU cache for rendered technical blocks (math SVG, Mermaid SVG, etc.).
///
/// Keys are derived from ``TechnicalBlock.contentHash`` plus a renderer
/// version string so a renderer upgrade invalidates stale entries.
public final class TechnicalBlockCache: @unchecked Sendable {
    public struct Entry: Sendable, Hashable {
        public let renderedHTML: String
        public let createdAt: Date
        public let renderDuration: Duration

        public init(renderedHTML: String, createdAt: Date, renderDuration: Duration) {
            self.renderedHTML = renderedHTML
            self.createdAt = createdAt
            self.renderDuration = renderDuration
        }
    }

    private struct Key: Hashable {
        let hash: ContentHash
        let rendererVersion: String
    }

    private let lock = NSLock()
    private var storage: [Key: (entry: Entry, sequence: UInt64)] = [:]
    private var sequence: UInt64 = 0
    private let capacity: Int

    public init(capacity: Int = 256) {
        self.capacity = capacity
    }

    public func get(_ block: TechnicalBlock, rendererVersion: String) -> Entry? {
        let key = Key(hash: block.contentHash, rendererVersion: rendererVersion)
        lock.lock()
        defer { lock.unlock() }
        guard var pair = storage[key] else { return nil }
        sequence &+= 1
        pair.sequence = sequence
        storage[key] = pair
        return pair.entry
    }

    public func set(_ block: TechnicalBlock, rendererVersion: String, entry: Entry) {
        let key = Key(hash: block.contentHash, rendererVersion: rendererVersion)
        lock.lock()
        defer { lock.unlock() }
        sequence &+= 1
        storage[key] = (entry, sequence)
        evictIfNeeded()
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll(keepingCapacity: true)
        sequence = 0
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return storage.count
    }

    private func evictIfNeeded() {
        while storage.count > capacity {
            if let evict = storage.min(by: { $0.value.sequence < $1.value.sequence }) {
                storage.removeValue(forKey: evict.key)
            } else {
                break
            }
        }
    }
}
