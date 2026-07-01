// The two concrete judges (completeness, MVI/over-engineering) and their
// mandatory self-test against each ticket's good/bad references.
//
// Port of scorers/judges.py. A judge is only trusted for a ticket if, on that
// ticket's references, it scores good >= good_floor and bad <= bad_ceiling.
// Otherwise its scores are excluded and the cell is flagged judge_invalid (the
// ponytail auditability discipline).
import Foundation

struct JudgeOutcome {
    var completeness: Double?
    var mvi: Double?
    var valid: Bool = false
    var notes: [String] = []
}

enum Judges {
    // (kind, rubric filename) for each dimension — ordered, like the Python dict.
    static let dimensions: [(kind: String, file: String)] = [
        ("completeness", "rubric.completeness.md"),
        ("mvi", "rubric.mvi.md"),
    ]

    static func readText(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func readRefs(_ ticketDir: URL, _ which: String) -> String? {
        let fm = FileManager.default
        let d = ticketDir.appendingPathComponent("references").appendingPathComponent(which)
        if !fm.fileExists(atPath: d.path) { return nil }
        var swiftURLs: [URL] = []
        if let en = fm.enumerator(at: d, includingPropertiesForKeys: nil) {
            for case let url as URL in en where url.pathExtension == "swift" {
                swiftURLs.append(url)
            }
        }
        swiftURLs.sort { $0.path < $1.path }
        var parts: [String] = []
        for f in swiftURLs {
            let rel = relativePath(of: f, from: d)
            parts.append("// FILE: \(rel)\n\(readText(f))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    static func relativePath(of file: URL, from base: URL) -> String {
        let b = base.standardizedFileURL.path
        let f = file.standardizedFileURL.path
        if f.hasPrefix(b + "/") { return String(f.dropFirst(b.count + 1)) }
        return file.lastPathComponent
    }

    /// Return (passed, message). Judge must separate good from bad.
    static func selftestDimension(
        _ cfg: Config, ticketDir: URL, kind: String, rubric: Rubric, workdir: URL
    ) -> (Bool, String) {
        let ticketMd = ticketDir.appendingPathComponent("ticket.md")
        let ticketText = FileManager.default.fileExists(atPath: ticketMd.path) ? readText(ticketMd) : ""
        guard let good = readRefs(ticketDir, "good"), let bad = readRefs(ticketDir, "bad") else {
            return (false, "\(kind): missing good/bad references")
        }
        let g = JudgeRunner.judge(cfg, rubric: rubric, ticketText: ticketText,
                                  codeText: good, kind: kind, workdir: workdir)
        let b = JudgeRunner.judge(cfg, rubric: rubric, ticketText: ticketText,
                                  codeText: bad, kind: kind, workdir: workdir)
        if !g.ok || !b.ok {
            return (false, "\(kind): judge call failed (good_ok=\(g.ok), bad_ok=\(b.ok))")
        }
        let gs = g.score ?? 0, bs = b.score ?? 0
        if gs >= rubric.goodFloor && bs <= rubric.badCeiling {
            return (true, "\(kind): good=\(pyNum(gs)) bad=\(pyNum(bs)) (separated)")
        }
        return (false, "\(kind): FAILED separation good=\(pyNum(gs)) (floor \(pyNum(rubric.goodFloor))) "
                + "bad=\(pyNum(bs)) (ceil \(pyNum(rubric.badCeiling)))")
    }

    /// Self-test both judges on the ticket references, then score the code.
    static func scoreCell(
        _ cfg: Config, ticketDir: URL, codeText: String, workdir: URL,
        transcriptsDir: URL? = nil
    ) -> JudgeOutcome {
        var out = JudgeOutcome()
        let ticketMd = ticketDir.appendingPathComponent("ticket.md")
        let ticketText = FileManager.default.fileExists(atPath: ticketMd.path) ? readText(ticketMd) : ""

        var rubrics: [(kind: String, rubric: Rubric)] = []
        var allValid = true
        for (kind, fname) in dimensions {
            let rpath = ticketDir.appendingPathComponent("acceptance").appendingPathComponent(fname)
            if !FileManager.default.fileExists(atPath: rpath.path) {
                out.notes.append("\(kind): no rubric, skipped")
                allValid = false
                continue
            }
            guard let rubric = try? JudgeRunner.loadRubric(rpath) else {
                out.notes.append("\(kind): no rubric, skipped")
                allValid = false
                continue
            }
            rubrics.append((kind, rubric))
            let (passed, msg) = selftestDimension(cfg, ticketDir: ticketDir, kind: kind,
                                                   rubric: rubric, workdir: workdir)
            out.notes.append(msg)
            if !passed { allValid = false }
        }

        out.valid = allValid
        if !allValid {
            out.notes.append("judges excluded (self-test failed)")
            return out
        }

        for (kind, rubric) in rubrics {
            let tp = transcriptsDir?.appendingPathComponent("judge-\(kind).json")
            let s = JudgeRunner.judge(cfg, rubric: rubric, ticketText: ticketText,
                                      codeText: codeText, kind: kind, workdir: workdir,
                                      transcriptPath: tp)
            if s.ok {
                if kind == "completeness" { out.completeness = s.score }
                else if kind == "mvi" { out.mvi = s.score }
            } else {
                out.notes.append("\(kind): scoring failed (\(s.error ?? "unknown"))")
            }
        }
        return out
    }
}

/// Render a Double the way Python's `str(float)` would (3.0 → "3.0", 2.5 → "2.5").
func pyNum(_ x: Double) -> String {
    if x == x.rounded() && abs(x) < 1e16 {
        return String(format: "%.1f", x)
    }
    return String(x)
}
