import Foundation

/// Best-effort decoder for plain-text Markdown files.
///
/// Strategy:
/// 1. Strip a leading UTF-8 BOM if present and decode as UTF-8.
/// 2. Fall back to Windows-1252 (covers Latin-1 plus extra punctuation common
///    in Markdown written in Windows-era editors).
/// 3. Last resort: decode as UTF-8 with replacement substitution so we never
///    fail outright on an arbitrary byte sequence.
///
/// Returns the decoded string and the encoding used so callers can preserve
/// fidelity on save if desired.
public enum TextDecoder {
    public struct Decoded: Sendable {
        public let text: String
        public let encoding: String.Encoding
        public let hadBOM: Bool
    }

    public static func decode(_ data: Data) -> Decoded {
        var hadBOM = false
        var payload = data
        if payload.count >= 3,
           payload[0] == 0xEF, payload[1] == 0xBB, payload[2] == 0xBF {
            hadBOM = true
            payload = payload.subdata(in: 3..<payload.count)
        }
        if let s = String(data: payload, encoding: .utf8) {
            return Decoded(text: s, encoding: .utf8, hadBOM: hadBOM)
        }
        if let s = String(data: payload, encoding: .windowsCP1252) {
            return Decoded(text: s, encoding: .windowsCP1252, hadBOM: false)
        }
        if let s = String(data: payload, encoding: .isoLatin1) {
            return Decoded(text: s, encoding: .isoLatin1, hadBOM: false)
        }
        // Last resort — lossy UTF-8 decode.
        let s = String(decoding: payload, as: UTF8.self)
        return Decoded(text: s, encoding: .utf8, hadBOM: false)
    }

    public static func encode(_ text: String, encoding: String.Encoding = .utf8, addBOM: Bool = false) -> Data {
        if encoding == .utf8 {
            var data = Data()
            if addBOM { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
            data.append(contentsOf: text.utf8)
            return data
        }
        return text.data(using: encoding, allowLossyConversion: true) ?? Data(text.utf8)
    }
}
