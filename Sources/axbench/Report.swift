// Render a ponytail-style Markdown report (+ minimal HTML) from aggregate data.
//
// Port of report.py.
import Foundation

enum Report {
    // (metric key, label, python-format-spec)
    static let headline: [(key: String, label: String, spec: String)] = [
        ("acceptance_pass_rate", "Acceptance pass-rate", "{:.0%}"),
        ("build_ok", "Build OK", "{:.0%}"),
        ("judge_completeness", "Completeness (judge)", "{:.2f}"),
        ("judge_mvi", "MVI/over-eng (judge)", "{:.2f}"),
        ("total_cost_usd", "Cost (USD)", "${:.3f}"),
        ("wall_clock_s", "Wall-clock (s)", "{:.0f}"),
        ("output_tokens", "Output tokens", "{:.0f}"),
    ]

    /// Format a value against a Python-style format spec (the subset used here:
    /// `{:.Nf}`, `{:.N%}`, `${:.Nf}`, and the `$`/`%`-stripped delta variants).
    static func fmt(_ val: Double?, _ spec: String) -> String {
        guard let val else { return "—" }
        let dollar = spec.contains("$")
        // Extract the inside of {: ... }
        var inner = ""
        if let open = spec.range(of: "{:"), let close = spec.range(of: "}", range: open.upperBound..<spec.endIndex) {
            inner = String(spec[open.upperBound..<close.lowerBound])
        } else {
            // Already a bare spec like ".3f" after replacement.
            inner = spec.replacingOccurrences(of: "$", with: "")
        }
        var result: String
        if inner.hasSuffix("%") {
            let p = precision(inner.dropLast())
            result = String(format: "%.\(p)f", val * 100) + "%"
        } else if inner.hasSuffix("f") {
            let p = precision(inner.dropLast())
            result = String(format: "%.\(p)f", val)
        } else {
            // No type char (e.g. ".0" from a stripped percent): general format.
            result = String(format: "%g", val)
        }
        return dollar ? "$" + result : result
    }

    /// Parse the precision digits out of a `.N` fragment (default 6, Python-like).
    static func precision(_ s: Substring) -> Int {
        let digits = s.drop { $0 == "." }
        return Int(digits) ?? 6
    }

    static func meanOf(_ matrix: [String: [String: Any]], _ ticket: String, _ arm: String,
                       _ metric: String) -> Double? {
        guard let armMap = matrix[ticket],
              let cell = armMap[arm] as? [String: Any],
              let stat = cell[metric] as? [String: Any] else { return nil }
        return stat["mean"] as? Double
    }

    static func table(_ agg: [String: Any]) -> [String] {
        let matrix = (agg["matrix"] as? [String: [String: Any]]) ?? [:]
        let tickets = (agg["tickets"] as? [String]) ?? []
        let arms = (agg["arms"] as? [String]) ?? []
        let deltas = (agg["deltas"] as? [String: Any]) ?? [:]
        var lines: [String] = []
        for (key, label, spec) in headline {
            lines.append("\n### \(label)\n")
            let header = "| Ticket | " + arms.joined(separator: " | ") + " | Δ (axkit-flow − baseline) | Winner |"
            let sep = "|" + String(repeating: "---|", count: arms.count + 3)
            lines.append(header)
            lines.append(sep)
            for t in tickets {
                let cells = arms.map { fmt(meanOf(matrix, t, $0, key), spec) }
                var row = "| \(t) | " + cells.joined(separator: " | ") + " |"
                if let td = deltas[t] as? [String: Any], let d = td[key] as? [String: Any] {
                    let deltaSpec = spec.replacingOccurrences(of: "$", with: "")
                        .replacingOccurrences(of: "%", with: "")
                    let delta = d["delta"] as? Double
                    let better = (d["better"] as? String) ?? "None"
                    row += " \(fmt(delta, deltaSpec)) | \(better) |"
                } else {
                    row += " — | — |"
                }
                lines.append(row)
            }
        }
        return lines
    }

    static func handoffPanel(_ agg: [String: Any]) -> [String] {
        let matrix = (agg["matrix"] as? [String: [String: Any]]) ?? [:]
        let tickets = (agg["tickets"] as? [String]) ?? []
        var lines = ["\n## Handoff-fidelity panel (Arm A)\n",
                     "| Ticket | Fidelity | Reached terminal | Drift events | Stages completed |",
                     "|---|---|---|---|---|"]
        var anyRow = false
        for t in tickets {
            guard let a = matrix[t]?["axkit-flow"] as? [String: Any] else { continue }
            anyRow = true
            func m(_ metric: String) -> Double? { (a[metric] as? [String: Any])?["mean"] as? Double }
            lines.append(
                "| \(t) | \(fmt(m("fidelity_score"), "{:.2f}")) "
                + "| \(fmt(m("reached_terminal"), "{:.0%}")) "
                + "| \(fmt(m("drift_count"), "{:.1f}")) "
                + "| \(fmt(m("stages_completed"), "{:.1f}")) |"
            )
        }
        if !anyRow {
            lines.append("| _no axkit-flow cells_ | — | — | — | — |")
        }
        return lines
    }

    static func integrity(_ agg: [String: Any]) -> [String] {
        let matrix = (agg["matrix"] as? [String: [String: Any]]) ?? [:]
        let tickets = (agg["tickets"] as? [String]) ?? []
        let arms = (agg["arms"] as? [String]) ?? []
        var lines = ["\n## Integrity checks\n"]
        var invalid: [String] = []
        var contaminated: [String] = []
        // Iterate deterministically (sorted tickets × sorted arms).
        for t in tickets {
            guard let armMap = matrix[t] else { continue }
            for arm in arms {
                guard let st = armMap[arm] as? [String: Any] else { continue }
                if let jv = st["judge_valid"] as? [Any], jv.contains(where: { ($0 as? Bool) == false }) {
                    invalid.append("\(t)/\(arm)")
                }
                if let cont = st["contamination"] as? [Any], cont.contains(where: { ($0 as? Bool) == true }) {
                    contaminated.append("\(t)/\(arm)")
                }
            }
        }
        lines.append("- Judge self-test failures: \(invalid.isEmpty ? "none" : invalid.joined(separator: ", "))")
        lines.append("- Arm-B contamination detected: "
                     + "\(contaminated.isEmpty ? "none" : contaminated.joined(separator: ", "))")
        return lines
    }

    static func buildMarkdown(_ agg: [String: Any]) -> String {
        let tickets = (agg["tickets"] as? [String]) ?? []
        let arms = (agg["arms"] as? [String]) ?? []
        let nCells = (agg["n_cells"] as? Int) ?? 0
        let resultsDir = (agg["results_dir"] as? String) ?? ""
        var out = ["# axbench report",
                   "",
                   "- Results: `\(resultsDir)`",
                   "- Cells: \(nCells)",
                   "- Tickets: \(tickets.isEmpty ? "—" : tickets.joined(separator: ", "))",
                   "- Arms: \(arms.isEmpty ? "—" : arms.joined(separator: ", "))",
                   "",
                   "Arms: **axkit-flow** = multi-session handoff pipeline; "
                   + "**baseline** = vanilla single Claude Code session.",
                   "",
                   "## Headline metrics (mean across runs)"]
        out += table(agg)
        out += handoffPanel(agg)
        out += integrity(agg)
        out += ["", "---", "_Generated by axbench. Per-cell raw artifacts live under the "
                + "results dir (transcripts, xcresult, diffs, handoff snapshots)._"]
        return out.joined(separator: "\n")
    }

    static func htmlEscape(_ s: String) -> String {
        // Mirrors Python html.escape(s, quote=True).
        var r = s.replacingOccurrences(of: "&", with: "&amp;")
        r = r.replacingOccurrences(of: "<", with: "&lt;")
        r = r.replacingOccurrences(of: ">", with: "&gt;")
        r = r.replacingOccurrences(of: "\"", with: "&quot;")
        r = r.replacingOccurrences(of: "'", with: "&#x27;")
        return r
    }

    @discardableResult
    static func writeReport(_ resultsDir: URL, _ agg: [String: Any]) -> URL {
        let md = buildMarkdown(agg)
        let mdPath = resultsDir.appendingPathComponent("report.md")
        try? md.write(to: mdPath, atomically: true, encoding: .utf8)

        try? PyJSON.dumps(agg).write(
            to: resultsDir.appendingPathComponent("aggregate.json"), atomically: true, encoding: .utf8
        )

        // Minimal HTML wrapper (renders the markdown as a <pre> for offline viewing).
        let htmlPath = resultsDir.appendingPathComponent("report.html")
        let html = "<!doctype html><meta charset='utf-8'><title>axbench report</title>"
            + "<body style='font-family:ui-monospace,monospace;max-width:60rem;margin:2rem auto'>"
            + "<pre>\(htmlEscape(md))</pre></body>"
        try? html.write(to: htmlPath, atomically: true, encoding: .utf8)
        return mdPath
    }
}
