// Data-driven LLM judges.
//
// Each task names its own judge dimensions (`scoring.judges[]`), each with a
// rubric (markdown + YAML frontmatter carrying good_floor/bad_ceiling/scale_max)
// and, optionally, good/bad reference solutions. Before a judge's score is
// trusted it must separate its references (good ≥ good_floor, bad ≤ bad_ceiling)
// — the ponytail auditability discipline. A judge that can't is excluded and the
// cell is flagged `judges_valid = false`. Judges run on the produced diff with a
// pinned model at low effort for determinism.
import Foundation

struct JudgeScorer: Scorer {
    let id = "judges"

    func applies(to task: BenchTask) -> Bool { !(task.scoring.judges ?? []).isEmpty }

    func score(_ ctx: ScoreContext, into q: inout Quality) {
        guard let specs = ctx.task.scoring.judges, !specs.isEmpty else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: ctx.scratch, withIntermediateDirectories: true)

        let ticketText = ctx.task.resolvedPrompt()
        let diffURL = ctx.runDir.appendingPathComponent("artifacts/agent.diff")
        let codeText = (try? String(contentsOf: diffURL, encoding: .utf8)) ?? ""
        let transcripts = ctx.runDir.appendingPathComponent("transcripts")

        var allValid = true
        for spec in specs {
            let rubricURL = Manifests.resolve(spec.rubric, base: ctx.task.dir)
            guard let rubric = try? JudgeRunner.loadRubric(rubricURL) else {
                q.notes.append("judge[\(spec.dimension)]: rubric missing/invalid, skipped")
                allValid = false
                continue
            }
            q.judgeScaleMax[spec.dimension] = rubric.scaleMax

            // Self-test on references, when provided.
            if let goodRel = spec.goodRef, let badRel = spec.badRef {
                let (passed, msg) = selftest(ctx, spec: spec, rubric: rubric,
                                             goodRel: goodRel, badRel: badRel, ticketText: ticketText)
                q.notes.append(msg)
                if !passed { allValid = false; continue }
            } else {
                q.notes.append("judge[\(spec.dimension)]: not self-tested (no references)")
            }

            // Score the produced diff.
            let tp = transcripts.appendingPathComponent("judge-\(spec.dimension).json")
            let s = JudgeRunner.judge(ctx.cfg, rubric: rubric, ticketText: ticketText,
                                      codeText: codeText, kind: spec.dimension,
                                      workdir: ctx.scratch, transcriptPath: tp)
            if s.ok, let score = s.score {
                q.judges[spec.dimension] = score
            } else {
                q.notes.append("judge[\(spec.dimension)]: scoring failed (\(s.error ?? "unknown"))")
            }
        }
        q.judgesValid = allValid
        // Discipline: if any judge failed its self-test, its dimension's score is
        // not trustworthy — drop all judge scores rather than mix trusted/untrusted.
        if !allValid { q.judges.removeAll() }
    }

    private func selftest(_ ctx: ScoreContext, spec: JudgeSpec, rubric: Rubric,
                          goodRel: String, badRel: String, ticketText: String) -> (Bool, String) {
        let kind = spec.dimension
        guard let good = readRefs(Manifests.resolve(goodRel, base: ctx.task.dir)),
              let bad = readRefs(Manifests.resolve(badRel, base: ctx.task.dir)) else {
            return (false, "judge[\(kind)]: missing good/bad references")
        }
        let g = JudgeRunner.judge(ctx.cfg, rubric: rubric, ticketText: ticketText,
                                  codeText: good, kind: kind, workdir: ctx.scratch)
        let b = JudgeRunner.judge(ctx.cfg, rubric: rubric, ticketText: ticketText,
                                  codeText: bad, kind: kind, workdir: ctx.scratch)
        if !g.ok || !b.ok {
            return (false, "judge[\(kind)]: call failed (good_ok=\(g.ok), bad_ok=\(b.ok))")
        }
        let gs = g.score ?? 0, bs = b.score ?? 0
        if gs >= rubric.goodFloor && bs <= rubric.badCeiling {
            return (true, "judge[\(kind)]: good=\(pyNum(gs)) bad=\(pyNum(bs)) (separated)")
        }
        return (false, "judge[\(kind)]: FAILED separation good=\(pyNum(gs)) "
                + "(floor \(pyNum(rubric.goodFloor))) bad=\(pyNum(bs)) (ceil \(pyNum(rubric.badCeiling)))")
    }

    /// Concatenate the text files under a reference dir into one labelled blob.
    private func readRefs(_ dir: URL) -> String? {
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
            let rel = String(f.path.dropFirst(dir.path.count + 1))
            parts.append("// FILE: \(rel)\n\(text)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}

/// Render a Double the way Python's `str(float)` would (3.0 → "3.0", 2.5 → "2.5").
func pyNum(_ x: Double) -> String {
    if x == x.rounded() && abs(x) < 1e16 { return String(format: "%.1f", x) }
    return String(x)
}
