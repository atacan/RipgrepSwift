import Foundation
import Testing

@testable import Ripgrep

struct IgnoreTests {
    @Test
    func gitignoreRespectedByDefault() async throws {
        let root = try TestFixture.make([
            ".gitignore": "ignored.txt\nvendor/\n",
            "visible.txt": "needle visible\n",
            "ignored.txt": "needle ignored\n",
            "vendor/dependency.swift": "needle vendored\n",
        ])
        defer { TestFixture.remove(root) }

        let results = try await collectAll(Ripgrep.search("needle", in: root))

        #expect(results.count == 1)
        #expect(results[0].fileURL.lastPathComponent == "visible.txt")
    }

    @Test
    func gitignoreDisabledWhenRespectGitIgnoreIsFalse() async throws {
        let root = try TestFixture.make([
            ".gitignore": "ignored.txt\n",
            "visible.txt": "needle visible\n",
            "ignored.txt": "needle ignored\n",
        ])
        defer { TestFixture.remove(root) }

        var options = RipgrepOptions()
        options.respectGitIgnore = false
        let results = try await collectAll(Ripgrep.search("needle", in: root, options: options))

        #expect(results.count == 2)
    }

    @Test
    func hiddenFilesExcludedByDefault() async throws {
        let root = try TestFixture.make([
            ".hidden.txt": "needle hidden\n",
            ".hidden/inside.txt": "needle inside\n",
            "visible.txt": "needle visible\n",
        ])
        defer { TestFixture.remove(root) }

        let results = try await collectAll(Ripgrep.search("needle", in: root))

        #expect(results.count == 1)
        #expect(results[0].fileURL.lastPathComponent == "visible.txt")
    }

    @Test
    func hiddenFilesIncludedWhenRequested() async throws {
        let root = try TestFixture.make([
            ".hidden.txt": "needle hidden\n",
            "visible.txt": "needle visible\n",
        ])
        defer { TestFixture.remove(root) }

        var options = RipgrepOptions()
        options.includeHidden = true
        let results = try await collectAll(Ripgrep.search("needle", in: root, options: options))

        let names = Set(results.map(\.fileURL.lastPathComponent))
        #expect(names == [".hidden.txt", "visible.txt"])
    }

    @Test
    func nestedIgnoreFileAppliesToSubtree() async throws {
        let root = try TestFixture.make([
            "src/.gitignore": "generated.swift\n",
            "src/included.swift": "needle included\n",
            "src/generated.swift": "needle generated\n",
        ])
        defer { TestFixture.remove(root) }

        let results = try await collectAll(Ripgrep.search("needle", in: root))

        #expect(results.count == 1)
        #expect(results[0].fileURL.lastPathComponent == "included.swift")
    }

    @Test
    func negatedIgnorePatternKeepsFile() async throws {
        let root = try TestFixture.make([
            ".gitignore": "*.log\n!important.log\n",
            "noise.log": "needle noise\n",
            "important.log": "needle important\n",
        ])
        defer { TestFixture.remove(root) }

        let results = try await collectAll(Ripgrep.search("needle", in: root))

        #expect(results.count == 1)
        #expect(results[0].fileURL.lastPathComponent == "important.log")
    }
}
