// Per-run isolation against the real ZohoDeskiOS app.
//
// Port of harness/sandbox.py. master = PRODUCTION. Safety rules enforced here:
// - Each run gets a detached `git worktree` off `base_ref` (master). The agent
//   only ever touches its own worktree.
// - A worktree-scoped push guard sets a bogus `remote.origin.pushurl` via
//   per-worktree config (`extensions.worktreeConfig`), so a stray `git push`
//   from inside the worktree fails fast — WITHOUT mutating the shared repo
//   config or the user's real checkout.
// - The harness never commits/pushes to origin; worktrees are torn down per run.
//
// For Arm A the axkit-flow repo is linked into the worktree by path. Arm B
// worktrees never contain axkit-flow — the contamination guard.
import Foundation

struct Worktree {
    var path: URL
    var arm: String
    var ticketId: String
    var baseSha: String
    var axkitFlowSha: String?
    var starterCommit: String?
}

enum Sandbox {
    static let gitId = ["-c", "user.email=axbench@local", "-c", "user.name=axbench"]
    static let pushGuardURL = "DISABLED_NO_PUSH_axbench"

    @discardableResult
    static func git(_ args: [String], cwd: URL, check: Bool = true) throws -> ProcessResult {
        try Shell.run(["git"] + args, cwd: cwd, check: check)
    }

    static func target(_ cfg: Config) -> URL {
        URL(fileURLWithPath: cfg.sources.targetRepo).resolvingSymlinksInPath()
    }

    static func gitSha(_ repo: URL, ref: String = "HEAD") throws -> String {
        try git(["rev-parse", ref], cwd: repo).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func targetBaseSha(_ cfg: Config) throws -> String {
        try gitSha(target(cfg), ref: cfg.sources.baseRef)
    }

    static func prepareWorktree(
        _ cfg: Config, runDir: URL, arm: String, ticketId: String, ticketDir: URL
    ) throws -> Worktree {
        let fm = FileManager.default
        let target = target(cfg)
        let baseRef = cfg.sources.baseRef
        let ticketDir = ticketDir.resolvingSymlinksInPath()
        if !fm.fileExists(atPath: target.appendingPathComponent(".git").path) {
            throw AxError("target repo is not a git repo: \(target.path)")
        }
        let baseSha = try gitSha(target, ref: baseRef)

        let wt = runDir.appendingPathComponent("worktree").standardizedFileURL
        if fm.fileExists(atPath: wt.path) {
            _ = try? git(["worktree", "remove", "--force", wt.path], cwd: target, check: false)
            if fm.fileExists(atPath: wt.path) {
                try? fm.removeItem(at: wt)
            }
        }
        _ = try? git(["worktree", "prune"], cwd: target, check: false)

        // Detached worktree off master — never on a branch that could be pushed.
        try git(["worktree", "add", "--detach", wt.path, baseRef], cwd: target)

        if cfg.sources.pushGuard {
            installPushGuard(wt)
        }

        // Seed local, gitignored files the build needs (not part of the commit that
        // the worktree was created from). Copied from the target repo working tree.
        for rel in cfg.sources.seedLocalFiles {
            let src = target.appendingPathComponent(rel)
            if fm.fileExists(atPath: src.path) {
                let dst = wt.appendingPathComponent(rel)
                try? fm.createDirectory(at: dst.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                try? fm.removeItem(at: dst)
                try? fm.copyItem(at: src, to: dst)
            }
        }

        // Apply ticket starter (the "to-implement" state). Patch paths are
        // worktree-root-relative.
        let starter = ticketDir.appendingPathComponent("starter.patch")
        if let attrs = try? fm.attributesOfItem(atPath: starter.path),
           let size = attrs[.size] as? Int, size > 0 {
            try git(["apply", "--whitespace=nowarn", starter.path], cwd: wt)
        }

        // Drop the PRD where the agent looks for it.
        let ticketMd = ticketDir.appendingPathComponent("ticket.md")
        if fm.fileExists(atPath: ticketMd.path) {
            let dest = wt.appendingPathComponent("docs/features")
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            let destFile = dest.appendingPathComponent("\(ticketId)_PRD.md")
            try? fm.removeItem(at: destFile)
            try fm.copyItem(at: ticketMd, to: destFile)
        }

        // Worktree-local "starter" commit so the agent's work is a measurable diff.
        // (Detached HEAD; objects are orphan + gc-able; never pushed.)
        try git(["add", "-A"], cwd: wt)
        try git(gitId + ["commit", "-m", "axbench: starter state", "--allow-empty"], cwd: wt)
        let starterCommit = try gitSha(wt)

        var axkitFlowSha: String?
        if arm == "axkit-flow" {
            axkitFlowSha = try linkAxkitFlow(cfg, wt)
            try? fm.createDirectory(
                at: wt.appendingPathComponent(".axkit/features"),
                withIntermediateDirectories: true
            )
        }

        return Worktree(path: wt, arm: arm, ticketId: ticketId, baseSha: baseSha,
                        axkitFlowSha: axkitFlowSha, starterCommit: starterCommit)
    }

    /// Disable pushes from THIS worktree only (non-destructive to shared config).
    static func installPushGuard(_ wt: URL) {
        // Per-worktree config requires the extension; enabling it is benign + shared.
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

    static func teardown(_ cfg: Config, _ wt: Worktree) {
        let target = target(cfg)
        _ = try? git(["worktree", "remove", "--force", wt.path.path], cwd: target, check: false)
        if FileManager.default.fileExists(atPath: wt.path.path) {
            try? FileManager.default.removeItem(at: wt.path)
        }
        _ = try? git(["worktree", "prune"], cwd: target, check: false)
    }

    static func linkAxkitFlow(_ cfg: Config, _ wt: URL) throws -> String {
        let fm = FileManager.default
        let src = URL(fileURLWithPath: cfg.sources.axkitFlowRepo).resolvingSymlinksInPath()
        if !fm.fileExists(atPath: src.appendingPathComponent("native/skills").path) {
            throw AxError("axkit-flow skills not found at \(src.path)")
        }
        let link = wt.appendingPathComponent("axkit-flow")
        // Remove any existing entry (file, dir, or symlink) before relinking.
        if (try? link.checkResourceIsReachable()) == true
            || (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
            try? fm.removeItem(at: link)
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: src)
        return (try? gitSha(src)) ?? "unknown"
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

    /// Contamination guard for Arm B: True if clean (no axkit-flow present).
    static func assertNoAxkitFlow(_ wt: Worktree) -> Bool {
        let fm = FileManager.default
        return !fm.fileExists(atPath: wt.path.appendingPathComponent("axkit-flow").path)
            && !fm.fileExists(atPath: wt.path.appendingPathComponent(".axkit").path)
    }
}

/// Lightweight error carrying a message (Python `RuntimeError`).
struct AxError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
