// Score a finished worktree: build + test + lint + judges → Quality.
//
// Port of scorers/pipeline.py.
import Foundation

enum Pipeline {
    /// Returns (Quality, touchedFiles, diffPath).
    static func scoreWorktree(
        _ cfg: Config, _ wt: Worktree, ticketDir: URL, runDir: URL, scratch: URL,
        runJudges: Bool = true
    ) -> (Quality, [String], String) {
        var q = Quality()

        let touched = Sandbox.touchedFiles(wt)
        let diffPath = Sandbox.writeDiff(wt, dest: runDir.appendingPathComponent("artifacts/agent.diff"))

        // --- Lint (cheap, no sim) ---
        let lr = Lint.lint(cfg, worktree: wt.path, touched: touched)
        if lr.available {
            q.lintViolations = lr.violations
            q.lintErrors = lr.errors
        } else {
            q.notes.append(lr.message)
        }

        // --- Build + test (inject hidden tests → pod install → build → test) ---
        let hasUitests = FileManager.default.fileExists(
            atPath: ticketDir.appendingPathComponent("acceptance/UITests").path
        )

        let inj = IOSBuild.injectTests(cfg, worktree: wt.path, ticketDir: ticketDir, runDir: runDir)
        if !inj.ok { q.notes.append("inject: \(inj.message)") }

        let pod = IOSBuild.resolveDependencies(cfg, worktree: wt.path, runDir: runDir)
        if !pod.ok {
            q.infraFailure = q.infraFailure || pod.infraFailure
            q.notes.append("dependencies: \(pod.message)")
        }

        if pod.ok {
            let br = IOSBuild.build(cfg, worktree: wt.path, runDir: runDir)
            q.buildOk = br.ok
            if !br.ok {
                q.infraFailure = q.infraFailure || br.infraFailure
                q.notes.append(br.message)
            } else {
                let tr = IOSBuild.runTests(cfg, worktree: wt.path, runDir: runDir, withUitests: hasUitests)
                if tr.infraFailure {
                    q.infraFailure = true
                    q.notes.append("test infra failure")
                }
                if tr.unit.parsed {
                    q.unitPassed = tr.unit.passed
                    q.unitTotal = tr.unit.total
                    q.unitPassRate = tr.unit.passRate
                }
                if hasUitests && tr.uitest.parsed {
                    q.uitestPassed = tr.uitest.passed
                    q.uitestTotal = tr.uitest.total
                    q.uitestPassRate = tr.uitest.passRate
                }
                q.acceptancePassRate = tr.acceptancePassRate
            }
        }

        // --- Judges (self-tested per ticket) ---
        // A judge failure must never discard the deterministic build/test results.
        if runJudges {
            do {
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                let codeText = (try? String(contentsOf: URL(fileURLWithPath: diffPath), encoding: .utf8)) ?? ""
                let jo = Judges.scoreCell(cfg, ticketDir: ticketDir, codeText: codeText,
                                          workdir: scratch,
                                          transcriptsDir: runDir.appendingPathComponent("transcripts"))
                q.judgeCompleteness = jo.completeness
                q.judgeMvi = jo.mvi
                q.judgeValid = jo.valid
                q.notes.append(contentsOf: jo.notes)
            } catch {
                q.notes.append("judges errored: \(error)")
            }
        }

        return (q, touched, diffPath)
    }
}
