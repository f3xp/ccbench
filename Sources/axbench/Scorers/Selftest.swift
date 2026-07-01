// Pre-flight: validate instruments before spending API budget.
//
// Port of scorers/selftest.py. Mirrors ponytail's `run.py --selftest`: prove the
// toolchain and that the judges can separate good from bad references. Nothing
// else should run until this is green.
import Foundation

struct SelftestReport {
    var checks: [(name: String, ok: Bool, msg: String)] = []

    mutating func add(_ name: String, _ ok: Bool, _ msg: String = "") {
        checks.append((name, ok, msg))
    }

    // Warnings (names prefixed "warn:") don't fail the suite.
    var ok: Bool {
        checks.allSatisfy { $0.ok || $0.name.hasPrefix("warn:") }
    }

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

    static func destinationOk(_ cfg: Config) -> (Bool, String) {
        let name = cfg.ios.simulatorName
        guard let proc = try? Shell.run(["xcrun", "simctl", "list", "devices", "available"]) else {
            return (false, "simctl failed")
        }
        if proc.exitCode != 0 { return (false, "simctl failed") }
        let present = proc.stdout.contains(name)
        return (present, present ? "\(name) available" : "\(name) not found")
    }

    static func refOk(_ repo: String, _ ref: String) -> (Bool, String) {
        guard let proc = try? Shell.run(["git", "-C", repo, "rev-parse", ref]) else {
            return (false, "git failed")
        }
        if proc.exitCode == 0 {
            return (true, String(proc.stdout.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12)))
        }
        return (false, String(proc.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)))
    }

    static func xcodeprojGemOk(_ cfg: Config) -> (Bool, String) {
        let ruby = cfg.ios.rubyBin
        if !Shell.which(ruby) && !FileManager.default.fileExists(atPath: ruby) {
            return (false, "ruby not found: \(ruby)")
        }
        var env = ProcessInfo.processInfo.environment
        env["GEM_HOME"] = cfg.ios.xcodeprojGemHome
        guard let proc = try? Shell.run(
            [ruby, "-e", "require 'xcodeproj'; print Xcodeproj::VERSION"], env: env
        ) else {
            return (false, "ruby launch failed")
        }
        if proc.exitCode == 0 {
            let outStr = proc.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return (true, outStr.isEmpty
                ? String(proc.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
                : outStr)
        }
        return (false, String(proc.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)))
    }

    static func runSelftest(
        _ cfg: Config, scratch: URL, ticketsDir: URL,
        skipJudges: Bool = false, checkBuild: Bool = false
    ) -> SelftestReport {
        var rep = SelftestReport()
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        rep.add("claude on PATH", tool("claude"))
        rep.add("xcodebuild on PATH", tool("xcodebuild"))

        let usesPods = cfg.ios.podinstall
        if usesPods {
            rep.add("pod (CocoaPods) on PATH", tool("pod"))
        }
        if cfg.ios.testInjection == "xcodeproj" {
            let (gemOk, gemMsg) = xcodeprojGemOk(cfg)
            rep.add("xcodeproj gem loadable", gemOk, gemMsg)
        } else {
            rep.add("warn: xcodeproj gem", true, "skipped (filesystem test injection)")
        }
        rep.add("warn: swiftlint on PATH", tool("swiftlint"),
                tool("swiftlint") ? "" : "lint gate will be skipped (brew install swiftlint)")

        // Target repo + base ref + axkit-flow presence.
        let target = cfg.sources.targetRepo
        let baseRef = cfg.sources.baseRef
        let (refValid, refMsg) = refOk(target, baseRef)
        rep.add("target repo \(baseRef) resolves", refValid, refMsg)
        let axf = URL(fileURLWithPath: cfg.sources.axkitFlowRepo).appendingPathComponent("native/skills")
        let axfExists = FileManager.default.fileExists(atPath: axf.path)
        rep.add("axkit-flow skills present", axfExists, axfExists ? "" : axf.path)

        if tool("xcodebuild") {
            let (ok, msg) = destinationOk(cfg)
            rep.add("simulator destination", ok, msg)
            if !usesPods {
                let (sok, smsg) = projectSchemeOk(cfg)
                rep.add("project lists scheme \(cfg.ios.appScheme)", sok, smsg)
            }
        }

        if tool("claude") {
            let (ok, msg) = ClaudeCLI.preflightAuth(cfg, workdir: scratch)
            rep.add("claude auth/preflight", ok, msg)
        }

        if checkBuild {
            let (ok, msg) = podInstallSmoke(cfg, scratch: scratch)
            rep.add("dependency resolution smoke (heavy)", ok, msg)
        }

        if skipJudges {
            rep.add("warn: judge self-test", true, "skipped (--skip-judges)")
            return rep
        }

        // Validate judges separate good/bad on the first ticket that has references.
        guard let ticket = firstTicketWithRefs(ticketsDir) else {
            rep.add("warn: judge self-test", true, "no ticket with good/bad references yet")
            return rep
        }

        for (kind, fname) in Judges.dimensions {
            let rpath = ticket.appendingPathComponent("acceptance").appendingPathComponent(fname)
            if !FileManager.default.fileExists(atPath: rpath.path) {
                rep.add("warn: judge[\(kind)]", true, "no rubric in \(ticket.lastPathComponent)")
                continue
            }
            guard let rubric = try? JudgeRunner.loadRubric(rpath) else {
                rep.add("warn: judge[\(kind)]", true, "no rubric in \(ticket.lastPathComponent)")
                continue
            }
            let (passed, msg) = Judges.selftestDimension(cfg, ticketDir: ticket, kind: kind,
                                                         rubric: rubric, workdir: scratch)
            rep.add("judge[\(kind)] separates good/bad (\(ticket.lastPathComponent))", passed, msg)
        }
        return rep
    }

    /// Cheap check that the target project loads and lists the app scheme.
    /// For SPM projects this also forces initial package resolution to surface
    /// auth/network problems before spending agent budget.
    static func projectSchemeOk(_ cfg: Config) -> (Bool, String) {
        let ios = cfg.ios
        let project = URL(fileURLWithPath: cfg.sources.targetRepo).appendingPathComponent(ios.projectRel)
        if !FileManager.default.fileExists(atPath: project.path) {
            return (false, "project not found: \(project.path)")
        }
        guard let proc = try? Shell.run(["xcodebuild", "-list", "-project", project.path]) else {
            return (false, "xcodebuild -list failed")
        }
        if proc.exitCode != 0 {
            let err = proc.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let outp = proc.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return (false, String((err.isEmpty ? outp : err).prefix(120)))
        }
        let scheme = ios.appScheme
        let present = proc.stdout.contains(scheme)
        return (present, present ? "\(scheme) listed" : "\(scheme) not in scheme list")
    }

    /// Create a throwaway worktree off base_ref and verify dependency resolution
    /// works (CocoaPods `pod install`, or SPM package resolution).
    /// Heavy (minutes) but proves auth/network before spending agent budget.
    static func podInstallSmoke(_ cfg: Config, scratch: URL) -> (Bool, String) {
        let fm = FileManager.default
        let rd = scratch.appendingPathComponent("depsmoke")
        if fm.fileExists(atPath: rd.path) { try? fm.removeItem(at: rd) }
        try? fm.createDirectory(at: rd, withIntermediateDirectories: true)
        var wt: Worktree?
        defer { if let wt { Sandbox.teardown(cfg, wt) } }
        do {
            let prepared = try Sandbox.prepareWorktree(
                cfg, runDir: rd, arm: "baseline", ticketId: "SMOKE",
                ticketDir: rd.appendingPathComponent("__none__")
            )
            wt = prepared
            let res = IOSBuild.resolveDependencies(cfg, worktree: prepared.path, runDir: rd)
            return (res.ok, res.message)
        } catch {
            return (false, String(String(describing: error).prefix(120)))
        }
    }

    static func firstTicketWithRefs(_ ticketsDir: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: ticketsDir.path),
              let entries = try? fm.contentsOfDirectory(at: ticketsDir, includingPropertiesForKeys: nil)
        else { return nil }
        let dirs = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }.sorted { $0.path < $1.path }
        for t in dirs {
            let good = t.appendingPathComponent("references/good")
            let bad = t.appendingPathComponent("references/bad")
            if fm.fileExists(atPath: good.path) && fm.fileExists(atPath: bad.path) {
                return t
            }
        }
        return nil
    }
}
