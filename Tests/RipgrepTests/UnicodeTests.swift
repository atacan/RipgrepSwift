import Foundation
import Testing

@testable import Ripgrep

/// Verifies that `matchStart`/`matchEnd` remain correct zero-based UTF-8
/// byte offsets for non-ASCII content. These offsets are deliberately *not*
/// Swift character positions.
struct UnicodeTests {
    @Test
    func precomposedAccents() async throws {
        // "café " = 6 bytes (é is 2 bytes in UTF-8).
        let root = try TestFixture.make(["uni.txt": "café TODO rest\n"])
        defer { TestFixture.remove(root) }

        let results = try await collectAll(Ripgrep.search("TODO", in: root))

        #expect(results.count == 1)
        #expect(results[0].line == "café TODO rest")
        #expect(results[0].matchStart == 6)
        #expect(results[0].matchEnd == 10)
    }

    @Test
    func cjkCharacters() async throws {
        // 日本語 = 9 bytes, plus one space → TODO starts at byte 10.
        let root = try TestFixture.make(["cjk.txt": "日本語 TODO\n"])
        defer { TestFixture.remove(root) }

        let results = try await collectAll(Ripgrep.search("TODO", in: root))

        #expect(results.count == 1)
        #expect(results[0].line == "日本語 TODO")
        #expect(results[0].matchStart == 10)
        #expect(results[0].matchEnd == 14)
    }

    @Test
    func emoji() async throws {
        // 🚀 = 4 bytes, plus one space → TODO starts at byte 5.
        let root = try TestFixture.make(["emoji.txt": "🚀 TODO launch\n"])
        defer { TestFixture.remove(root) }

        let results = try await collectAll(Ripgrep.search("TODO", in: root))

        #expect(results.count == 1)
        #expect(results[0].line == "🚀 TODO launch")
        #expect(results[0].matchStart == 5)
        #expect(results[0].matchEnd == 9)
    }

    @Test
    func combiningCharacters() async throws {
        // "cafe" + U+0301 COMBINING ACUTE ACCENT = 6 bytes, plus one space
        // → TODO starts at byte 7. Note this is not the same as the
        // precomposed "café" case above.
        let lineWithCombiningAcute = "cafe\u{301} TODO"
        let root = try TestFixture.make(["combining.txt": "\(lineWithCombiningAcute)\n"])
        defer { TestFixture.remove(root) }

        let results = try await collectAll(Ripgrep.search("TODO", in: root))

        #expect(results.count == 1)
        #expect(results[0].line == lineWithCombiningAcute)
        #expect(lineWithCombiningAcute.utf8.count == 11)
        #expect(lineWithCombiningAcute.count == 9) // Swift Characters ≠ bytes
        #expect(results[0].matchStart == 7)
        #expect(results[0].matchEnd == 11)
    }

    @Test
    func unicodePatternMatchesUnicodeContent() async throws {
        let root = try TestFixture.make(["jp.txt": "これは日本語です\nplain text\n"])
        defer { TestFixture.remove(root) }

        let results = try await collectAll(Ripgrep.search("日本語", in: root))

        #expect(results.count == 1)
        #expect(results[0].lineNumber == 1)
        // これは = 3 characters × 3 UTF-8 bytes = 9 bytes.
        #expect(results[0].matchStart == 9)
        #expect(results[0].matchEnd == 18)
    }
}
