import Foundation
import CryptoKit

/// Stable 128-bit content hash used as a cache key for expensive renders.
///
/// Built from SHA-256 truncated to 16 bytes — collision resistance is more
/// than sufficient for in-process caches, and the smaller payload keeps cache
/// keys cheap to hash and compare.
public struct ContentHash: Hashable, Sendable, CustomStringConvertible {
    public let bytes: SIMD16<UInt8>

    public init(_ bytes: SIMD16<UInt8>) { self.bytes = bytes }

    public static func of(_ string: String) -> ContentHash {
        of(Data(string.utf8))
    }

    public static func of(_ data: Data) -> ContentHash {
        let digest = SHA256.hash(data: data)
        var simd = SIMD16<UInt8>()
        var i = 0
        for byte in digest.prefix(16) {
            simd[i] = byte
            i += 1
        }
        return ContentHash(simd)
    }

    public static func combining(_ parts: [String]) -> ContentHash {
        var hasher = SHA256()
        for part in parts {
            var len = UInt64(part.utf8.count).littleEndian
            withUnsafeBytes(of: &len) { hasher.update(bufferPointer: $0) }
            hasher.update(data: Data(part.utf8))
        }
        let digest = hasher.finalize()
        var simd = SIMD16<UInt8>()
        var i = 0
        for byte in digest.prefix(16) {
            simd[i] = byte
            i += 1
        }
        return ContentHash(simd)
    }

    public var description: String {
        (0..<16).map { String(format: "%02x", bytes[$0]) }.joined()
    }
}
