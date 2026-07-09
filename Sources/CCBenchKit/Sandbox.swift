// Per-run isolation against the target repo.
//
// Safety rules enforced here:
// - Each cell gets a detached `git worktree` off the task's `baseRef`. The agent
//   only ever touches its own worktree.
// - A worktree-scoped push guard sets a bogus `remote.origin.pushurl` via
//   per-worktree config (`extensions.worktreeConfig`), so a stray `git push`
//   from inside the worktree fails fast — WITHOUT mutating the shared repo config
//   or the user's real checkout.
// - The harness never commits/pushes to origin; worktrees are torn down per cell.
//
// A `.skill` variant links its workflow directory into the worktree. A control
// variant's worktree must contain none of the run's workflow mounts — the
// contamination guard.
import Foundation

struct Worktree {
    var path: URL
    var variantId: String
    var taskId: String
    var baseSha: String
    var mountSha: String?
    var starterCommit: String?
}

enum Sandbox {
    static let gitId = ["-c", "user.email=ccbench@local", "-c", "user.name=ccbench"]
    static let pushGuardURL = "DISABLED_NO_PUSH_ccbench"

    @discardableResult
    static func git(_ args: [String], cwd: URL, check: Bool = true) throws -> ProcessResult {
        try Shell.run(["git"] + args, cwd: cwd, check: check)
    }

    static func repoURL(_ task: BenchTask) -> URL {
        URL(fileURLWithPath: Manifests.expand(task.repo)).resolvingSymlinksInPath()
    }

    static func gitSha(_ repo: URL, ref: String = "HEAD") throws -> String {
        try git(["rev-parse", ref], cwd: repo).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func prepareWorktree(
        _ cfg: Config, runDir: URL, task: BenchTask, variant: Variant
    ) throws -> Worktree {
        let fm = FileManager.default
        let target = repoURL(task)
        let baseRef = task.baseRef
        if !fm.fileExists(atPath: target.appendingPathComponent(".git").path) {
            throw CCError("task repo is not a git repo: \(target.path)")
        }
        let baseSha = try gitSha(target, ref: baseRef)

        let wt = runDir.appendingPathComponent("worktree").standardizedFileURL
        if fm.fileExists(atPath: wt.path) {
            _ = try? git(["worktree", "remove", "--force", wt.path], cwd: target, check: false)
            if fm.fileExists(atPath: wt.path) { try? fm.removeItem(at: wt) }
        }
        _ = try? git(["worktree", "prune"], cwd: target, check: false)

        // Detached worktree — never on a branch that could be pushed.
        try git(["worktree", "add", "--detach", wt.path, baseRef], cwd: target)

        if cfg.pushGuard { installPushGuard(wt) }

        // Seed local, gitignored files the build needs (copied from the working tree).
        for rel in task.seedFiles {
            let src = target.appendingPathComponent(rel)
            if fm.fileExists(atPath: src.path) {
                let dst = wt.appendingPathComponent(rel)
                try? fm.createDirectory(at: dst.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                try? fm.removeItem(at: dst)
                try? fm.copyItem(at: src, to: dst)
            }
        }

        // Apply the task starter patch (the "to-implement" state).
        if let patchRel = task.starterPatch {
            let starter = Manifests.resolve(patchRel, base: task.dir)
            if let attrs = try? fm.attributesOfItem(atPath: starter.path),
               let size = attrs[.size] as? Int, size > 0 {
                try git(["apply", "--whitespace=nowarn", starter.path], cwd: wt)
            }
        }

        // Worktree-local "starter" commit so the agent's work is a measurable diff.
        try git(["add", "-A"], cwd: wt)
        try git(gitId + ["commit", "-m", "ccbench: starter state", "--allow-empty"], cwd: wt)
        let starterCommit = try gitSha(wt)

        // Mount the variant's workflow directory (skills/plugin/.claude project).
        var mountSha: String?
        if variant.kind == .skill, let mount = variant.mount {
            mountSha = try mountVariant(variant, mount: mount, into: wt)
        }

        return Worktree(path: wt, variantId: variant.id, taskId: task.id, baseSha: baseSha,
                        mountSha: mountSha, starterCommit: starterCommit)
    }

    /// Symlink a variant's workflow dir into the worktree; return its git sha if any.
    static func mountVariant(_ variant: Variant, mount: String, into wt: URL) throws -> String {
        let fm = FileManager.default
        let src = URL(fileURLWithPath: Manifests.expand(mount)).resolvingSymlinksInPath()
        if !fm.fileExists(atPath: src.path) {
            throw CCError("variant '\(variant.id)' mount not found: \(src.path)")
        }
        let name = variant.effectiveMountAs ?? src.lastPathComponent
        let link = wt.appendingPathComponent(name)
        if (try? link.checkResourceIsReachable()) == true
            || (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
            try? fm.removeItem(at: link)
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: src)
        return (try? gitSha(src)) ?? "unknown"
    }

    /// Disable pushes from THIS worktree only (non-destructive to shared config).
    static func installPushGuard(_ wt: URL) {
        _ = try? git(["config", "extensions.worktreeConfig", "true"], cwd: wt, check: false)
        _ = try? git(["config", "--worktree", "remote.origin.pushurl", pushGuardURL],
                     cwd: wt, check: false)
    }

    /// True if pushes from the worktree are guarded (or there is no origin).
    static func assertPushDisabled(_ wt: Worktree) -> Bool {
        guard let res = try? git(["remote", "get-url", "--push", "origin"],
                                 cwd: wt.path, check: false) else { return true }
        if res.exitCode != 0 { return true }  // no origin / no push url at all
        return res.stdout.contains(pushGuardURL)
    }

    static func teardown(_ task: BenchTask, _ wt: Worktree) {
        let target = repoURL(task)
        _ = try? git(["worktree", "remove", "--force", wt.path.path], cwd: target, check: false)
        if FileManager.default.fileExists(atPath: wt.path.path) {
            try? FileManager.default.removeItem(at: wt.path)
        }
        _ = try? git(["worktree", "prune"], cwd: target, check: false)
    }

    static func touchedFiles(_ wt: Worktree) -> [String] {
        let ref = wt.starterCommit ?? "HEAD"
        let out = (try? git(["diff", "--name-only", ref], cwd: wt.path).stdout) ?? ""
        return out.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    @discardableResult
    static func writeDiff(_ wt: Worktree, dest: URL) -> String {
        let ref = wt.starterCommit ?? "HEAD"
        let diff = (try? git(["diff", ref], cwd: wt.path).stdout) ?? ""
        try? FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? diff.write(to: dest, atomically: true, encoding: .utf8)
        return dest.path
    }

    /// git --numstat between the starter commit and the working tree.
    static func diffMetrics(_ wt: Worktree) -> DiffMetrics {
        let ref = wt.starterCommit ?? "HEAD"
        let out = (try? git(["diff", "--numstat", ref], cwd: wt.path).stdout) ?? ""
        var added = 0, removed = 0, files = 0
        for line in out.split(separator: "\n") {
            let cols = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard cols.count >= 3 else { continue }
            files += 1
            added += Int(cols[0]) ?? 0        // "-" for binary → 0
            removed += Int(cols[1]) ?? 0
        }
        return DiffMetrics(linesAdded: added, linesRemoved: removed, filesTouched: files)
    }

    /// Contamination guard: true if clean (none of `forbiddenMounts` present).
    static func assertNoMounts(_ wt: Worktree, forbidden: Set<String>) -> Bool {
        let fm = FileManager.default
        for name in forbidden where !name.isEmpty {
            if fm.fileExists(atPath: wt.path.appendingPathComponent(name).path) { return false }
        }
        return true
    }
}

/// Lightweight error carrying a message.
struct CCError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
