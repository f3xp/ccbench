// Pre-flight: validate instruments before spending API budget.
//
// Prove the toolchain (claude + git), that every task's repo and base ref
// resolve, that verify commands are launchable, and that judges can separate
// their good/bad references. Nothing paid should run until this is green.
import Foundation

struct SelftestReport {
    var checks: [(name: String, ok: Bool, msg: String)] = []

    mutating func add(_ name: String, _ ok: Bool, _ msg: String = "") {
        checks.append((name, ok, msg))
    }

    // Warnings (names prefixed "warn:") don't fail the suite.
    var ok: Bool { checks.allSatisfy { $0.ok || $0.name.hasPrefix("warn:") } }

    func render() -> String {
        var lines: [String] = []
        for (name, ok, msg) in checks {
            let mark = ok ? "✓" : (name.hasPrefix("warn:") ? "!" : "✗")
            lines.append("  \(mark) \(name)" + (msg.isEmpty ? "" : " — \(msg)"))
        }
        lines.append("")
        lines.append("SELFTEST: " + (ok ? "PASS" : "FAIL"))
        return lines.joined(separator: "\n")
    }
}

enum Selftest {
    static func tool(_ name: String) -> Bool { Shell.which(name) }

    static func refOk(_ repo: String, _ ref: String) -> (Bool, String) {
        guard let proc = try? Shell.run(["git", "-C", repo, "rev-parse", ref]) else {
            return (false, "git failed")
        }
        if proc.exitCode == 0 {
            return (true, String(proc.stdout.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12)))
        }
        return (false, String(proc.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)))
    }

    static func runSelftest(
        _ cfg: Config, scratch: URL, tasks: [BenchTask], skipJudges: Bool = false
    ) -> SelftestReport {
        var rep = SelftestReport()
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        rep.add("claude on PATH", tool(cfg.claude.bin))
        rep.add("git on PATH", tool("git"))

        // Per-task: repo is a git repo, base ref resolves, verify command launchable.
        for task in tasks {
            let repo = Manifests.expand(task.repo)
            let isGit = FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: repo).appendingPathComponent(".git").path)
            rep.add("task[\(task.id)] repo is git", isGit, isGit ? repo : "not a git repo: \(repo)")
            if isGit {
                let (ok, msg) = refOk(repo, task.baseRef)
                rep.add("task[\(task.id)] baseRef \(task.baseRef) resolves", ok, msg)
            }
            if let verify = task.scoring.verify, let bin = verify.command.first {
                let launchable = bin.hasPrefix("/")
                    ? FileManager.default.isExecutableFile(atPath: bin)
                    : tool(bin)
                rep.add("task[\(task.id)] verify command '\(bin)' launchable", launchable)
            } else {
                rep.add("warn: task[\(task.id)] verify", true, "no verify command configured")
            }
        }

        if tool(cfg.claude.bin) {
            let (ok, msg) = ClaudeCLI.preflightAuth(cfg, workdir: scratch)
            rep.add("claude auth/preflight", ok, msg)
        }

        if skipJudges {
            rep.add("warn: judge self-test", true, "skipped (--skip-judges)")
            return rep
        }

        // Validate judges separate good/bad on the first task/dimension with references.
        var checkedAny = false
        for task in tasks {
            for spec in task.scoring.judges ?? [] {
                guard let goodRel = spec.goodRef, let badRel = spec.badRef else { continue }
                let rubricURL = Manifests.resolve(spec.rubric, base: task.dir)
                guard let rubric = try? JudgeRunner.loadRubric(rubricURL) else {
                    rep.add("warn: judge[\(spec.dimension)]", true, "rubric missing in \(task.id)")
                    continue
                }
                let ticketText = task.resolvedPrompt()
                let good = readRefs(Manifests.resolve(goodRel, base: task.dir))
                let bad = readRefs(Manifests.resolve(badRel, base: task.dir))
                guard let good, let bad else {
                    rep.add("warn: judge[\(spec.dimension)]", true, "refs missing in \(task.id)")
                    continue
                }
                let g = JudgeRunner.judge(cfg, rubric: rubric, ticketText: ticketText,
                                          codeText: good, kind: spec.dimension, workdir: scratch)
                let b = JudgeRunner.judge(cfg, rubric: rubric, ticketText: ticketText,
                                          codeText: bad, kind: spec.dimension, workdir: scratch)
                let gs = g.score ?? 0, bs = b.score ?? 0
                let passed = g.ok && b.ok && gs >= rubric.goodFloor && bs <= rubric.badCeiling
                rep.add("judge[\(spec.dimension)] separates good/bad (\(task.id))", passed,
                        "good=\(pyNum(gs)) bad=\(pyNum(bs))")
                checkedAny = true
            }
        }
        if !checkedAny {
            rep.add("warn: judge self-test", true, "no task with judge references yet")
        }
        return rep
    }

    private static func readRefs(_ dir: URL) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return nil }
        var files: [URL] = []
        if let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in en {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if !isDir && !url.lastPathComponent.hasPrefix(".") { files.append(url) }
            }
        }
        files.sort { $0.path < $1.path }
        var parts: [String] = []
        for f in files {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            parts.append("// FILE: \(String(f.path.dropFirst(dir.path.count + 1)))\n\(text)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}
