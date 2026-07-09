// The deterministic correctness gate.
//
// Overlays the task's hidden acceptance files into the finished worktree (the
// agent never saw them), runs the optional setup command (deps install —
// failures classified as infra), then runs the task's `verify` command and reads
// its result. The contract is a single JSON object on stdout:
//
//   {"pass_rate": 0.94, "passed": 18, "total": 19,
//    "criteria": [{"id": "AC-01", "passed": true}, ...],
//    "infra_failure": false}
//
// Any field is optional. If stdout carries no JSON, the exit code is the verdict
// (0 → pass_rate 1.0, non-zero → 0.0). A truthy `infra_failure` (or a non-zero
// setup) is recorded separately so environment problems never read as quality
// regressions. This is the language-agnostic replacement for the old Xcode path;
// an iOS build+test that emits this JSON is just one implementation.
import Foundation

struct VerifyCommandScorer: Scorer {
    let id = "verify"

    func applies(to task: BenchTask) -> Bool { task.scoring.verify != nil }

    func score(_ ctx: ScoreContext, into q: inout Quality) {
        guard let spec = ctx.task.scoring.verify else { return }
        let wt = ctx.worktree.path
        let fm = FileManager.default

        // 1. Overlay the hidden acceptance files.
        if let hidden = ctx.task.hiddenDir {
            let src = Manifests.resolve(hidden, base: ctx.task.dir)
            if fm.fileExists(atPath: src.path) {
                overlay(src, into: wt, notes: &q.notes)
            } else {
                q.notes.append("verify: hidden dir not found: \(src.path)")
            }
        }

        // 2. Setup (deps install) — infra, not quality.
        if let setup = ctx.task.setup {
            let r = runCommand(setup, in: wt, timeout: ctx.cfg.budgets.setupTimeoutS)
            if r.exitCode != 0 || r.timedOut {
                let extra = r.timedOut ? ", timed out" : ""
                q.infraFailure = true
                q.notes.append("setup failed (exit \(r.exitCode)\(extra))")
                q.verifyRan = false
                return
            }
        }

        // 3. Verify.
        let r = runCommand(spec, in: wt, timeout: ctx.cfg.budgets.verifyTimeoutS)
        let logPath = ctx.runDir.appendingPathComponent("artifacts/verify.log")
        try? fm.createDirectory(at: logPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (r.stdout + "\n---STDERR---\n" + r.stderr).write(to: logPath, atomically: true, encoding: .utf8)

        if r.timedOut {
            q.infraFailure = true
            q.notes.append("verify timed out")
            return
        }

        q.verifyRan = true
        if let obj = extractJSON(r.stdout) {
            if truthy(obj["infra_failure"]) {
                q.infraFailure = true
                q.notes.append("verify reported infra_failure")
            }
            let criteria = (obj["criteria"] as? [[String: Any]]) ?? []
            q.criteria = criteria.compactMap { c in
                guard let id = c["id"] as? String else { return nil }
                return Criterion(id: id, passed: truthy(c["passed"]))
            }
            let passed = intVal(obj["passed"]) ?? q.criteria.filter { $0.passed }.count
            let total = intVal(obj["total"]) ?? q.criteria.count
            q.verifyPassed = passed
            q.verifyTotal = total
            if let rate = doubleVal(obj["pass_rate"]) {
                q.verifyPassRate = rate
            } else if total > 0 {
                q.verifyPassRate = Double(passed) / Double(total)
            } else {
                q.verifyPassRate = r.exitCode == 0 ? 1.0 : 0.0
            }
        } else {
            // Exit-code fallback.
            q.verifyPassRate = r.exitCode == 0 ? 1.0 : 0.0
            if r.exitCode != 0 {
                q.notes.append("verify exited \(r.exitCode) (no JSON contract)")
            }
        }
    }

    // MARK: helpers

    private func runCommand(_ spec: CommandSpec, in wt: URL, timeout: Int) -> ProcessResult {
        let cwd = spec.cwd.map { wt.appendingPathComponent($0) } ?? wt
        let t = Double(spec.timeoutS ?? timeout)
        return (try? Shell.run(spec.command, cwd: cwd, timeout: t))
            ?? ProcessResult(exitCode: 127, stdout: "", stderr: "failed to launch", timedOut: false)
    }

    /// Copy every file under `src` into `dst`, creating parent dirs (overwrite).
    private func overlay(_ src: URL, into dst: URL, notes: inout [String]) {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey]) else {
            notes.append("verify: could not enumerate hidden dir")
            return
        }
        for case let file as URL in en {
            let isDir = (try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDir { continue }
            let rel = String(file.path.dropFirst(src.path.count + 1))
            let target = dst.appendingPathComponent(rel)
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: target)
            try? fm.copyItem(at: file, to: target)
        }
    }

    private func extractJSON(_ text: String) -> [String: Any]? {
        guard let first = text.firstIndex(of: "{"),
              let last = text.lastIndex(of: "}"), first <= last else { return nil }
        let slice = String(text[first...last])
        guard let data = slice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private func truthy(_ any: Any?) -> Bool {
        switch any {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["true", "1", "yes"].contains(s.lowercased())
        default: return false
        }
    }
    private func intVal(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
    private func doubleVal(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }
}
