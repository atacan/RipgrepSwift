import Foundation
import Testing

@testable import Ripgrep

struct SearchTests {
    @Test
    func basicSearch() async throws {
        let root = try TestFixture.make([
            "one.txt": "hello\nTODO: first\n",
            "two.txt": "nothing\n",
        ])
        defer { TestFixture.remove(root) }

        let results = try await collectAll(Ripgrep.search("TODO", in: root))

        #expect(results.count == 1)
        #expect(results[0].lineNumber == 2)
        #expect(results[0].line == "TODO: first")
        #expect(results[0].matchStart == 0)
        #expect(results[0].matchEnd == 4)
        #expect(results[0].fileURL.lastPathComponent == "one.txt")
    }

    @Test
    func regexAlternationAcrossFiles() async throws {
        let root = try TestFixture.make([
            "a.txt": "FIXME now\n",
            "b.txt": "TODO later\nFIXME\n",
        ])
        defer { TestFixture.remove(root) }

        let results = try await collectAll(Ripgrep.search("TODO|FIXME", in: root))

        #expect(results.count == 3)
        let lines = results.map(\.line)
        #expect(lines == ["TODO later", "FIXME", "FIXME now"])
    }

    @Test
    func multipleMatchesOnOneLine() async throws {
        let root = try TestFixture.make(["multi.txt": "TODO fix TODO\n"])
        defer { TestFixture.remove(root) }

        let results = try await collectAll(Ripgrep.search("TODO", in: root))

        #expect(results.count == 2)
        #expect(results[0].matchStart == 0)
        #expect(results[0].matchEnd == 4)
        #expect(results[1].matchStart == 9)
        #expect(results[1].matchEnd == 13)
        // Both hits describe the same line.
        #expect(results[0].lineNumber == results[1].lineNumber)
        #expect(results[0].line == results[1].line)
    }

    @Test
    func caseInsensitiveOption() async throws {
        let root = try TestFixture.make(["case.txt": "todo lowercase\nTodo mixed\n"])
        defer { TestFixture.remove(root) }

        let sensitive = try await collectAll(Ripgrep.search("TODO", in: root))
        #expect(sensitive.isEmpty)

        var options = RipgrepOptions()
        options.caseInsensitive = true
        let insensitive = try await collectAll(
            Ripgrep.search("TODO", in: root, options: options)
        )
        #expect(insensitive.count == 2)
    }

    @Test
    func invalidPatternBecomesSwiftError() async throws {
        let root = try TestFixture.make(["a.txt": "content\n"])
        defer { TestFixture.remove(root) }

        do {
            _ = try await collectAll(Ripgrep.search("(unclosed", in: root))
            Issue.record("expected an invalidPattern error")
        } catch let error as RipgrepError {
            guard case .invalidPattern = error else {
                Issue.record("unexpected RipgrepError: \(error)")
                return
            }
        }
    }

    @Test
    func nonexistentRootBecomesIOError() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("RipgrepSwift-missing-\(UUID().uuidString)")

        do {
            _ = try await collectAll(Ripgrep.search("needle", in: missing))
            Issue.record("expected an io error")
        } catch let error as RipgrepError {
            guard case .io = error else {
                Issue.record("unexpected RipgrepError: \(error)")
                return
            }
        }
    }

    @Test
    func repeatedSearchesAreConsistent() async throws {
        let root = try TestFixture.make([
            "one.txt": "needle once\nneedle twice\n",
            "two.txt": "no match\n",
        ])
        defer { TestFixture.remove(root) }

        for _ in 0..<25 {
            let results = try await collectAll(Ripgrep.search("needle", in: root))
            #expect(results.count == 2)
        }
    }

    @Test
    func concurrentIndependentSearchesWork() async throws {
        let firstRoot = try TestFixture.make(["a.txt": String(repeating: "alpha needle\n", count: 100)])
        defer { TestFixture.remove(firstRoot) }
        let secondRoot = try TestFixture.make(["b.txt": String(repeating: "beta needle\n", count: 200)])
        defer { TestFixture.remove(secondRoot) }

        let optionsForBeta = RipgrepOptions()

        try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                try await collectAll(Ripgrep.search("alpha", in: firstRoot)).count
            }
            group.addTask {
                try await collectAll(Ripgrep.search("beta", in: secondRoot, options: optionsForBeta)).count
            }
            var counts: [Int] = []
            for try await count in group {
                counts.append(count)
            }
            counts.sort()
            #expect(counts == [100, 200])
        }
    }
}
