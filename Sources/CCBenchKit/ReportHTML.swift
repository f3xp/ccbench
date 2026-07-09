// Self-contained HTML dashboard for a ccbench run.
//
// Renders the aggregate tree into a single HTML file (inline CSS, no network
// access): one median-per-variant table per headline metric, the control marked,
// and a delta-vs-control panel. Generic over variants and metrics.
import Foundation

enum ReportHTML {
    static func esc(_ s: String) -> String { Report.htmlEscape(s) }

    static func build(_ agg: [String: Any]) -> String {
        let matrix = (agg["matrix"] as? [String: [String: Any]]) ?? [:]
        let tasks = (agg["tasks"] as? [String]) ?? []
        let variants = (agg["variants"] as? [String]) ?? []
        let control = agg["control"] as? String
        let metrics = Report.orderedMetrics((agg["metrics"] as? [String]) ?? [])
        let nCells = (agg["n_cells"] as? Int) ?? 0
        let resultsDir = (agg["results_dir"] as? String) ?? ""

        var body = ""
        body += "<h1>ccbench report</h1>"
        body += "<p class='meta'>Results <code>\(esc(resultsDir))</code> · \(nCells) cells · "
        body += "variants: \(variants.map { esc($0) }.joined(separator: ", ")) · "
        body += "control: <b>\(esc(control ?? "—"))</b></p>"

        for metric in metrics {
            body += "<h2>\(esc(Report.label(metric)))</h2>"
            body += "<table><thead><tr><th>Task</th>"
            for v in variants {
                body += "<th>\(esc(v))\(v == control ? " <span class='tag'>control</span>" : "")</th>"
            }
            body += "</tr></thead><tbody>"
            for t in tasks {
                body += "<tr><td class='task'>\(esc(t))</td>"
                let vals = variants.map { Report.medianOf(matrix, t, $0, metric) }
                let best = bestIndex(vals, metric: metric)
                for (i, v) in vals.enumerated() {
                    let cls = (i == best && vals.count > 1) ? " class='best'" : ""
                    body += "<td\(cls)>\(esc(Report.fmt(v, Report.spec(metric))))</td>"
                }
                body += "</tr>"
            }
            body += "</tbody></table>"
        }

        // Delta panel.
        if let control, let deltas = agg["deltas"] as? [String: Any] {
            body += "<h2>Deltas vs control (<code>\(esc(control))</code>)</h2>"
            for t in tasks {
                guard let perVariant = deltas[t] as? [String: Any], !perVariant.isEmpty else { continue }
                for (variant, d) in perVariant.sorted(by: { $0.key < $1.key }) {
                    guard let dd = d as? [String: Any] else { continue }
                    body += "<h3>\(esc(t)) — \(esc(variant)) vs \(esc(control))</h3>"
                    body += "<table><thead><tr><th>Metric</th><th>Δ</th><th>Better</th></tr></thead><tbody>"
                    for m in metrics {
                        guard let md = dd[m] as? [String: Any] else { continue }
                        let delta = md["delta"] as? Double
                        let better = (md["better"] as? String) ?? "—"
                        let ds = Report.spec(m).replacingOccurrences(of: "$", with: "")
                            .replacingOccurrences(of: "%", with: "")
                        let cls = better == variant ? "win" : (better == control ? "lose" : "")
                        body += "<tr><td>\(esc(Report.label(m)))</td>"
                        body += "<td>\(esc(Report.fmt(delta, ds)))</td>"
                        body += "<td class='\(cls)'>\(esc(better))</td></tr>"
                    }
                    body += "</tbody></table>"
                }
            }
        }

        return page(body)
    }

    /// Index of the best variant for a metric (nil-safe).
    static func bestIndex(_ vals: [Double?], metric: String) -> Int? {
        let higher = Aggregate.higherBetter.contains(metric) || metric.hasPrefix("judge_")
        let lower = Aggregate.lowerBetter.contains(metric)
        guard higher || lower else { return nil }
        var best: Int? = nil
        for (i, v) in vals.enumerated() {
            guard let v else { continue }
            guard let b = best, let bv = vals[b] else { best = i; continue }
            if (higher && v > bv) || (lower && v < bv) { best = i }
        }
        return best
    }

    static func page(_ body: String) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>ccbench report</title>
        <style>
          :root { color-scheme: light dark; }
          body { font: 14px/1.5 -apple-system, system-ui, sans-serif; margin: 2rem auto; max-width: 60rem; padding: 0 1rem; }
          h1 { font-size: 1.6rem; } h2 { font-size: 1.2rem; margin-top: 2rem; border-bottom: 1px solid #8883; padding-bottom: .3rem; }
          h3 { font-size: 1rem; margin-top: 1.2rem; color: #888; }
          .meta { color: #888; }
          table { border-collapse: collapse; width: 100%; margin: .6rem 0 1.2rem; }
          th, td { text-align: left; padding: .35rem .6rem; border-bottom: 1px solid #8882; }
          th { font-weight: 600; }
          td.task { font-weight: 600; }
          td.best { font-weight: 700; color: #16a34a; }
          .tag { font-size: .7rem; background: #6366f1; color: #fff; padding: .05rem .35rem; border-radius: .3rem; vertical-align: middle; }
          .win { color: #16a34a; font-weight: 600; } .lose { color: #dc2626; }
          code { background: #8881; padding: .05rem .3rem; border-radius: .25rem; }
        </style></head><body>
        \(body)
        <hr><p class="meta">Generated by ccbench.</p>
        </body></html>
        """
    }
}
