import Foundation
import Testing

@testable import Ripgrep

struct GlobTests {
    private func paths(in root: URL, options: RipgrepOptions) async throws -> Set<String> {
        let matches = try await collectAll(Ripgrep.search("needle", in: root, options: options))
        return Set(matches.map { String($0.fileURL.path.dropFirst(root.path.count + 1)) })
    }

    @Test
    func includesSelectRootAndNestedFilesWithSpacesAndUnicode() async throws {
        let root = try TestFixture.make([
            "main.swift": "needle", "src/日本 語.swift": "needle",
            "src/lib.rs": "needle", "notes.txt": "needle",
        ])
        defer { TestFixture.remove(root) }
        var options = RipgrepOptions(includeGlobs: ["**/*.swift"])
        #expect(try await paths(in: root, options: options) == ["main.swift", "src/日本 語.swift"])
        options.includeGlobs.append("**/*.rs")
        #expect(try await paths(in: root, options: options) == ["main.swift", "src/日本 語.swift", "src/lib.rs"])
        options.includeGlobs = ["**/日本 語.swift"]
        #expect(try await paths(in: root, options: options) == ["src/日本 語.swift"])
    }

    @Test
    func excludesAreOredAndWinRegardlessOfOrder() async throws {
        let root = try TestFixture.make([
            "a.swift": "needle", "b.rs": "needle", "notes.txt": "needle",
            "Generated/a.swift": "needle",
        ])
        defer { TestFixture.remove(root) }
        #expect(try await paths(in: root, options: .init(excludeGlobs: ["*.rs"])) == ["a.swift", "notes.txt", "Generated/a.swift"])
        #expect(try await paths(in: root, options: .init(excludeGlobs: ["*.rs", "Generated/"])) == ["a.swift", "notes.txt"])
        for includes in [["*.swift", "Generated/**"], ["Generated/**", "*.swift"]] {
            for excludes in [["a.swift", "Generated/"], ["Generated/", "a.swift"]] {
                #expect(try await paths(in: root, options: .init(includeGlobs: includes, excludeGlobs: excludes)).isEmpty)
            }
        }
    }

    @Test
    func anchoredAndDirectoryPatternsHaveRootRelativeSemantics() async throws {
        let root = try TestFixture.make([
            "a.swift": "needle", "src/a.swift": "needle", "src/deep/a.swift": "needle",
            "other/src/a.swift": "needle",
        ])
        defer { TestFixture.remove(root) }
        #expect(try await paths(in: root, options: .init(includeGlobs: ["/a.swift"])) == ["a.swift"])
        #expect(try await paths(in: root, options: .init(includeGlobs: ["src/*.swift"])) == ["src/a.swift"])
        #expect(try await paths(in: root, options: .init(includeGlobs: ["src/**"])) == ["src/a.swift", "src/deep/a.swift"])
        #expect(try await paths(in: root, options: .init(includeGlobs: ["src/"])).isEmpty)
        #expect(try await paths(in: root, options: .init(excludeGlobs: ["src/"])) == ["a.swift"])
        #expect(try await paths(in: root, options: .init(excludeGlobs: ["src/**"])) == ["a.swift", "other/src/a.swift"])
    }

    @Test
    func ignoreAndHiddenRulesStillApplyAndGlobsSurviveDisablingIgnore() async throws {
        let root = try TestFixture.make([
            ".gitignore": "ignored.swift\n", ".ignore": "other.swift\n",
            "src/.ignore": "generated.swift\n", "src/generated.swift": "needle",
            "ignored.swift": "needle", "other.swift": "needle", "visible.swift": "needle",
            ".hidden.swift": "needle", ".hidden/a.swift": "needle", "excluded.swift": "needle",
            "notes.txt": "needle",
        ])
        defer { TestFixture.remove(root) }
        var options = RipgrepOptions(includeGlobs: ["**/*.swift"], excludeGlobs: ["excluded.swift"])
        #expect(try await paths(in: root, options: options) == ["visible.swift"])
        options.includeHidden = true
        #expect(try await paths(in: root, options: options) == ["visible.swift", ".hidden.swift", ".hidden/a.swift"])
        options.respectGitIgnore = false
        #expect(try await paths(in: root, options: options) == ["visible.swift", ".hidden.swift", ".hidden/a.swift", "ignored.swift", "other.swift", "src/generated.swift"])
        options.includeHidden = false
        #expect(try await paths(in: root, options: options) == ["visible.swift", "ignored.swift", "other.swift", "src/generated.swift"])
    }

    @Test
    func excludedDirectoriesAreNeverSearchedOrRead() async throws {
        let root = try TestFixture.make([
            "kept.swift": "needle\n", "Generated/deep/a.swift": "needle\n",
            "Generated/b.txt": String(repeating: "no match\n", count: 100_000),
        ])
        defer { TestFixture.remove(root) }
        let (results, statistics) = Ripgrep.searchWithStatistics(
            "needle", in: root, options: .init(excludeGlobs: ["Generated/"])
        )
        #expect(try await collectAll(results).count == 1)
        #expect(try await waitUntil { statistics.isFinished })
        #expect(statistics.filesVisited == 1)
        #expect(statistics.bytesSearched == 7)
    }

    @Test(arguments: ["[", "{a,b", "", "   ", "!a.swift", "#comment", "a\nb", "a\rb", "a\0b"])
    func invalidGlobSurfacesDeterministicallyBeforeNativeReads(pattern: String) async throws {
        let root = try TestFixture.make(["a.swift": "needle"])
        defer { TestFixture.remove(root) }
        for options in [RipgrepOptions(includeGlobs: [pattern]), RipgrepOptions(excludeGlobs: [pattern])] {
            var messages: [String] = []
            for _ in 0..<2 {
                let (results, statistics) = Ripgrep.searchWithStatistics("needle", in: root, options: options)
                do {
                    _ = try await collectAll(results)
                    Issue.record("invalid glob succeeded: \(pattern.debugDescription)")
                } catch RipgrepError.invalidGlob(let message) {
                    #expect(message.contains(pattern.debugDescription))
                    messages.append(message)
                }
                #expect(try await waitUntil { statistics.isFinished })
                #expect(statistics.filesVisited == 0)
                #expect(statistics.bytesSearched == 0)
                #expect(statistics.deliveredMatchCount == 0)
            }
            #expect(messages.count == 2)
            #expect(Set(messages).count == 1)
        }
    }

    @Test
    func emptyArraysPreserveExistingResultsExactly() async throws {
        let root = try TestFixture.make([
            "a.swift": "needle", "nested/b.txt": "needle", ".hidden": "needle",
            ".gitignore": "ignored.rs", "ignored.rs": "needle",
        ])
        defer { TestFixture.remove(root) }
        let original = try await collectAll(Ripgrep.search("needle", in: root))
        let explicit = try await collectAll(Ripgrep.search("needle", in: root, options: .init(includeGlobs: [], excludeGlobs: [])))
        #expect(original == explicit)
    }

    @Test
    func singleFileRootIsFilteredRelativeToItsParent() async throws {
        let root = try TestFixture.make(["a.swift": "needle"])
        defer { TestFixture.remove(root) }
        let file = root.appendingPathComponent("a.swift")
        #expect(try await collectAll(Ripgrep.search("needle", in: file, options: .init(includeGlobs: ["/a.swift"]))).count == 1)
        #expect(try await collectAll(Ripgrep.search("needle", in: file, options: .init(includeGlobs: ["*.rs"]))).isEmpty)
        #expect(try await collectAll(Ripgrep.search("needle", in: file, options: .init(excludeGlobs: ["a.swift"]))).isEmpty)
    }

    @Test
    func symlinksUseTraversalPathsAndRespectFollowingAndExclusion() async throws {
        let root = try TestFixture.make(["visible.swift": "needle"])
        let target = try TestFixture.make(["a.swift": "needle", "a.txt": "needle"])
        defer { TestFixture.remove(root); TestFixture.remove(target) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: target)
        var options = RipgrepOptions(includeGlobs: ["linked/**/*.swift"])
        #expect(try await paths(in: root, options: options).isEmpty)
        options.followSymbolicLinks = true
        #expect(try await paths(in: root, options: options) == ["linked/a.swift"])
        options.excludeGlobs = ["linked/"]
        #expect(try await paths(in: root, options: options).isEmpty)
    }

    @Test
    func filteredSearchParksOnBackpressureAndCancelsCleanly() async throws {
        let root = try TestFixture.make([
            "kept.swift": String(repeating: "needle\n", count: 10_000), "skip.txt": "needle",
        ])
        defer { TestFixture.remove(root) }
        let (results, statistics) = Ripgrep.searchWithStatistics("needle", in: root, options: .init(includeGlobs: ["*.swift"]))
        let iterator = results.makeAsyncIterator()
        // With no demand the producer can enter only one match callback.
        #expect(try await waitUntil { statistics.deliveredMatchCount == 1 })
        for _ in 0..<10 { #expect(try await iterator.next() != nil) }
        #expect(try await waitUntil { statistics.deliveredMatchCount == 11 })
        #expect(statistics.filesVisited == 1)
        results.cancel()
        #expect(try await waitUntil { statistics.isFinished })
        #expect(statistics.deliveredMatchCount == 11)
        #expect(try await iterator.next() == nil)
    }

    @Test
    func literalPrefixesAndCaseSensitiveGlobsUseNativeSyntax() async throws {
        let root = try TestFixture.make([
            "!a.swift": "needle", "#b.swift": "needle", "C.SWIFT": "NEEDLE",
        ])
        defer { TestFixture.remove(root) }
        #expect(try await paths(in: root, options: .init(includeGlobs: ["\\!a.swift", "\\#b.swift"])) == ["!a.swift", "#b.swift"])
        #expect(try await paths(in: root, options: .init(excludeGlobs: ["\\!a.swift", "\\#b.swift"])).isEmpty)
        #expect(try await paths(in: root, options: .init(caseInsensitive: true, includeGlobs: ["*.swift"])) == ["!a.swift", "#b.swift"])
    }

    @Test
    func concurrentSearchesKeepDifferentGlobSetsIsolated() async throws {
        let root = try TestFixture.make(["a.swift": "needle", "b.rs": "needle", "c.txt": "needle"])
        defer { TestFixture.remove(root) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    let pattern = index.isMultiple(of: 2) ? "*.swift" : "*.rs"
                    let expected = index.isMultiple(of: 2) ? "a.swift" : "b.rs"
                    let matches = try await collectAll(Ripgrep.search("needle", in: root, options: .init(includeGlobs: [pattern], excludeGlobs: ["*.txt"])))
                    #expect(matches.map(\.fileURL.lastPathComponent) == [expected])
                }
            }
            try await group.waitForAll()
        }
    }
}
