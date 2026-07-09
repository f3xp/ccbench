// Render a Markdown report (+ self-contained HTML) from the aggregate tree.
//
// Generic over variants: one table per headline metric with a column per variant
// (median across runs), the control marked, and a per-task delta-vs-control
// section. Follows ponytail in reporting medians and surfacing the over-build
// (lines-of-code) signal alongside cost.
import Foundation

enum Report {
    /// Known metric → (label, format-spec). Judge dimensions (judge_<dim>) are
    /// discovered at runtime and formatted as {:.2f}.
    static let labels: [String: (String, String)] = [
        "verify_pass_rate": ("Verify pass-rate", "{:.0%}"),
        "golden_match_rate": ("Golden match-rate", "{:.0%}"),
        "total_cost_usd": ("Cost (USD)", "${:.3f}"),
        "wall_clock_s": ("Wall-clock (s)", "{:.0f}"),
        "output_tokens": ("Output tokens", "{:.0f}"),
        "num_turns": ("Turns", "{:.0f}"),
        "lines_added": ("Lines added (over-build)", "{:.0f}"),
        "lines_removed": ("Lines removed", "{:.0f}"),
        "files_touched": ("Files touched", "{:.0f}"),
    ]

    /// Order metrics are presented in the report.
    static func orderedMetrics(_ metrics: [String]) -> [String] {
        let preferred = ["verify_pass_rate", "golden_match_rate"]
            + metrics.filter { $0.hasPrefix("judge_") }.sorted()
            + ["total_cost_usd", "wall_clock_s", "output_tokens", "num_turns",
               "lines_added", "lines_removed", "files_touched"]
        return preferred.filter { metrics.contains($0) }
    }

    static func label(_ metric: String) -> String {
        if let (l, _) = labels[metric] { return l }
        if metric.hasPrefix("judge_") { return "Judge: \(metric.dropFirst(6))" }
        return metric
    }
    static func spec(_ metric: String) -> String {
        if let (_, s) = labels[metric] { return s }
        if metric.hasPrefix("judge_") { return "{:.2f}" }
        return "{:.2f}"
    }

    static func fmt(_ val: Double?, _ spec: String) -> String {
        guard let val else { return "—" }
        let dollar = spec.contains("$")
        var inner = ""
        if let open = spec.range(of: "{:"),
           let close = spec.range(of: "}", range: open.upperBound..<spec.endIndex) {
            inner = String(spec[open.upperBound..<close.lowerBound])
        } else {
            inner = spec.replacingOccurrences(of: "$", with: "")
        }
        var result: String
        if inner.hasSuffix("%") {
            result = String(format: "%.\(precision(inner.dropLast()))f", val * 100) + "%"
        } else if inner.hasSuffix("f") {
            result = String(format: "%.\(precision(inner.dropLast()))f", val)
        } else {
            result = String(format: "%g", val)
        }
        return dollar ? "$" + result : result
    }
    static func precision(_ s: Substring) -> Int { Int(s.drop { $0 == "." }) ?? 6 }

    static func medianOf(_ matrix: [String: [String: Any]], _ task: String, _ variant: String,
                         _ metric: String) -> Double? {
        ((matrix[task]?[variant] as? [String: Any])?[metric] as? [String: Any])?["median"] as? Double
    }

    static func tables(_ agg: [String: Any]) -> [String] {
        let matrix = (agg["matrix"] as? [String: [String: Any]]) ?? [:]
        let tasks = (agg["tasks"] as? [String]) ?? []
        let variants = (agg["variants"] as? [String]) ?? []
        let control = agg["control"] as? String
        let metrics = orderedMetrics((agg["metrics"] as? [String]) ?? [])

        var lines: [String] = []
        for metric in metrics {
            lines.append("\n### \(label(metric)) — median across runs\n")
            let cols = variants.map { $0 == control ? "\($0) *(control)*" : $0 }
            lines.append("| Task | " + cols.joined(separator: " | ") + " |")
            lines.append("|" + String(repeating: "---|", count: variants.count + 1))
            for t in tasks {
                let cells = variants.map { fmt(medianOf(matrix, t, $0, metric), spec(metric)) }
                lines.append("| \(t) | " + cells.joined(separator: " | ") + " |")
            }
        }
        return lines
    }

    static func deltaSection(_ agg: [String: Any]) -> [String] {
        guard let control = agg["control"] as? String else { return [] }
        let deltas = (agg["deltas"] as? [String: Any]) ?? [:]
        let tasks = (agg["tasks"] as? [String]) ?? []
        let metrics = orderedMetrics((agg["metrics"] as? [String]) ?? [])
        var lines = ["\n## Deltas vs control (`\(control)`, median)\n"]
        var any = false
        for t in tasks {
            guard let perVariant = deltas[t] as? [String: Any], !perVariant.isEmpty else { continue }
            for (variant, d) in perVariant.sorted(by: { $0.key < $1.key }) {
                guard let dd = d as? [String: Any] else { continue }
                any = true
                lines.append("\n**\(t) — \(variant) vs \(control)**\n")
                lines.append("| Metric | \(variant) | \(control) | Δ | Better |")
                lines.append("|---|---|---|---|---|")
                for m in metrics {
                    guard let md = dd[m] as? [String: Any] else { continue }
                    let v = md["variant"] as? Double, c = md["control"] as? Double
                    let delta = md["delta"] as? Double
                    let better = (md["better"] as? String) ?? "—"
                    let ds = spec(m).replacingOccurrences(of: "$", with: "").replacingOccurrences(of: "%", with: "")
                    lines.append("| \(label(m)) | \(fmt(v, spec(m))) | \(fmt(c, spec(m))) "
                                 + "| \(fmt(delta, ds)) | \(better) |")
                }
            }
        }
        if !any { lines.append("_no non-control variants to compare_") }
        return lines
    }

    static func integrity(_ agg: [String: Any]) -> [String] {
        let matrix = (agg["matrix"] as? [String: [String: Any]]) ?? [:]
        let tasks = (agg["tasks"] as? [String]) ?? []
        let variants = (agg["variants"] as? [String]) ?? []
        var lines = ["\n## Integrity checks\n"]
        var invalid: [String] = [], contaminated: [String] = []
        for t in tasks {
            guard let vmap = matrix[t] else { continue }
            for v in variants {
                guard let st = vmap[v] as? [String: Any] else { continue }
                if let jv = st["judges_valid"] as? [Any], jv.contains(where: { ($0 as? Bool) == false }) {
                    invalid.append("\(t)/\(v)")
                }
                if let cont = st["contamination"] as? [Any], cont.contains(where: { ($0 as? Bool) == true }) {
                    contaminated.append("\(t)/\(v)")
                }
            }
        }
        lines.append("- Judge self-test failures: \(invalid.isEmpty ? "none" : invalid.joined(separator: ", "))")
        lines.append("- Control contamination detected: "
                     + "\(contaminated.isEmpty ? "none" : contaminated.joined(separator: ", "))")
        return lines
    }

    static func buildMarkdown(_ agg: [String: Any]) -> String {
        let tasks = (agg["tasks"] as? [String]) ?? []
        let variants = (agg["variants"] as? [String]) ?? []
        let control = agg["control"] as? String
        let nCells = (agg["n_cells"] as? Int) ?? 0
        let resultsDir = (agg["results_dir"] as? String) ?? ""
        var out = ["# ccbench report",
                   "",
                   "- Results: `\(resultsDir)`",
                   "- Cells: \(nCells)",
                   "- Tasks: \(tasks.isEmpty ? "—" : tasks.joined(separator: ", "))",
                   "- Variants: \(variants.isEmpty ? "—" : variants.joined(separator: ", "))",
                   "- Control: \(control ?? "—")",
                   "",
                   "## Headline metrics"]
        out += tables(agg)
        out += deltaSection(agg)
        out += integrity(agg)
        out += ["", "---", "_Generated by ccbench. Per-cell raw artifacts (transcripts, "
                + "diffs, verify logs) live under the results dir._"]
        return out.joined(separator: "\n")
    }

    static func htmlEscape(_ s: String) -> String {
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

        let htmlPath = resultsDir.appendingPathComponent("report.html")
        let html = ReportHTML.build(agg)
        try? html.write(to: htmlPath, atomically: true, encoding: .utf8)
        return mdPath
    }
}
