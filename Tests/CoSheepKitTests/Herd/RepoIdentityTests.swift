import Foundation
import Testing
@testable import CoSheepKit

@Suite("herd repo identity")
struct RepoIdentityTests {
    private func resolve(_ cwd: String, gitAt: Set<String>) -> (key: String, name: String) {
        RepoIdentity.resolve(cwd: cwd, fileExists: { gitAt.contains($0) })
    }

    @Test func theRepoRootIsTheKeyAndItsFolderTheName() {
        let r = resolve("/Users/x/dev/co-sheep", gitAt: ["/Users/x/dev/co-sheep/.git"])
        #expect(r.key == "/Users/x/dev/co-sheep")
        #expect(r.name == "co-sheep")
    }

    @Test func aSubdirectoryResolvesToTheRepoAbove() {
        let r = resolve("/Users/x/dev/co-sheep/Sources/CoSheepKit/Herd", gitAt: ["/Users/x/dev/co-sheep/.git"])
        #expect(r.key == "/Users/x/dev/co-sheep")
        #expect(r.name == "co-sheep")
    }

    @Test func theNearestGitWins() {
        let r = resolve("/a/b/c/d", gitAt: ["/a/.git", "/a/b/.git"])
        #expect(r.key == "/a/b")
        #expect(r.name == "b")
    }

    @Test func outsideARepoTheCwdItselfIsTheKey() {
        let r = resolve("/Users/x/Downloads/stuff", gitAt: [])
        #expect(r.key == "/Users/x/Downloads/stuff")
        #expect(r.name == "stuff")
    }

    @Test func trailingSlashesDoNotMakeANewRepo() {
        let a = resolve("/work/app/", gitAt: [])
        let b = resolve("/work/app", gitAt: [])
        #expect(a == b)
        #expect(resolve("/work/app//", gitAt: ["/work/app/.git"]).key == "/work/app")
    }

    @Test func theRootDirectoryTerminatesTheWalk() {
        var asked: [String] = []
        let r = RepoIdentity.resolve(cwd: "/x", fileExists: { asked.append($0); return false })
        #expect(asked == ["/x/.git", "/.git"])
        #expect(r.key == "/x")

        let root = RepoIdentity.resolve(cwd: "/", fileExists: { _ in false })
        #expect(root.key == "/")
        #expect(root.name == "/")
        #expect(RepoIdentity.resolve(cwd: "/", fileExists: { $0 == "/.git" }).key == "/")
    }

    @Test func theWalkGivesUpAfterFortyLevels() {
        let deep = "/" + (0..<60).map { "d\($0)" }.joined(separator: "/")
        var asked = 0
        let r = RepoIdentity.resolve(cwd: deep, fileExists: { _ in asked += 1; return false })
        #expect(asked == 40)
        #expect(r.key == deep)
        #expect(r.name == "d59")

        // a repo 39 levels up is still found, one 40 levels up is not
        let components = (0..<60).map { "d\($0)" }
        let at39 = "/" + components.prefix(60 - 39).joined(separator: "/")
        #expect(resolve(deep, gitAt: [at39 + "/.git"]).key == at39)
        let at40 = "/" + components.prefix(60 - 40).joined(separator: "/")
        #expect(resolve(deep, gitAt: [at40 + "/.git"]).key == deep)
    }

    @Test func aGitFileMarksAWorktreeAsItsOwnRepo() {
        // The check is existence only, so `.git` files (worktrees) count like directories.
        let r = resolve("/work/app-feature/src", gitAt: ["/work/app-feature/.git"])
        #expect(r.key == "/work/app-feature")
        #expect(r.name == "app-feature")
    }

    @Test func worksAgainstTheRealFilesystem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("herd-repo-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("pkg/src", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let r = RepoIdentity.resolve(cwd: nested.path)
        #expect(r.key == root.path)
        #expect(r.name == root.lastPathComponent)

        // a worktree-style `.git` file in a deeper folder takes over
        let worktree = root.appendingPathComponent("pkg", isDirectory: true)
        try Data("gitdir: /elsewhere\n".utf8).write(to: worktree.appendingPathComponent(".git"))
        #expect(RepoIdentity.resolve(cwd: nested.path).key == worktree.path)
    }

    @Test func sameRepoSameWoolColour() {
        let a = resolve("/work/app/src", gitAt: ["/work/app/.git"])
        let b = resolve("/work/app/docs", gitAt: ["/work/app/.git"])
        #expect(HerdPalette.hue(forRepoKey: a.key) == HerdPalette.hue(forRepoKey: b.key))
    }
}
