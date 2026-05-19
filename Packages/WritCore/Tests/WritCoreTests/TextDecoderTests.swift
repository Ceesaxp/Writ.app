import Testing
import Foundation
@testable import WritCore

@Suite("TextDecoder")
struct TextDecoderTests {
    @Test("Plain UTF-8 round-trips")
    func plainUTF8() {
        let src = "# Hello\nWorld é日本"
        let decoded = TextDecoder.decode(Data(src.utf8))
        #expect(decoded.text == src)
        #expect(decoded.encoding == .utf8)
        #expect(!decoded.hadBOM)
    }

    @Test("UTF-8 BOM is detected and stripped")
    func utf8BOM() {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: "# Hello".utf8)
        let decoded = TextDecoder.decode(data)
        #expect(decoded.text == "# Hello")
        #expect(decoded.hadBOM)
    }

    @Test("Windows-1252 bytes that fail UTF-8 fall back gracefully")
    func windows1252Fallback() {
        // 0x91 is left-single-quote in CP1252 but invalid as a UTF-8 lead byte.
        let data = Data([0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x91, 0x73])
        let decoded = TextDecoder.decode(data)
        #expect(decoded.encoding == .windowsCP1252)
        #expect(decoded.text.contains("hello"))
        #expect(decoded.text.contains("s"))
    }

    @Test("Encode without BOM produces clean UTF-8")
    func encodeNoBom() {
        let data = TextDecoder.encode("hi", encoding: .utf8, addBOM: false)
        #expect(data == Data("hi".utf8))
    }

    @Test("Encode with BOM prepends marker")
    func encodeWithBom() {
        let data = TextDecoder.encode("hi", encoding: .utf8, addBOM: true)
        #expect(data.prefix(3) == Data([0xEF, 0xBB, 0xBF]))
        #expect(data.suffix(2) == Data("hi".utf8))
    }
}
