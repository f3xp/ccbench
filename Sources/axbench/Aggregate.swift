// Aggregate cell.json files into per-(ticket,arm) matrices with stats + deltas.
//
// Port of aggregate.py. Pure offline: reads persisted cells only, so it can be
// re-run any time without touching agents. The aggregate is a loosely-typed
// `[String: Any]` tree so it serialises to JSON the same shape as the Python.
import Foundation

enum Aggregate {
    // Metrics where higher is better (for win/loss direction).
    static let higherBetter: Set<String> = [
        "acceptance_pass_rate", "unit_pass_rate", "uitest_pass_rate",
        "judge_completeness", "judge_mvi", "build_ok",
    ]
    static let lowerBetter: Set<String> = [
        "total_cost_usd", "wall_clock_s", "lint_violations", "output_tokens",
    ]

    static let metricKeys = [
        "build_ok", "acceptance_pass_rate", "unit_pass_rate", "uitest_pass_rate",
        "lint_violations", "judge_completeness", "judge_mvi",
        "total_cost_usd", "wall_clock_s", "output_tokens", "num_turns",
        "fidelity_score", "reached_terminal", "drift_count", "stages_completed",
    ]

    // Per-cell derived values.
    struct CellMetrics {
        var numeric: [String: Double?]
        var status: Any            // String or NSNull
        var judgeValid: Any        // Bool or NSNull
        var contamination: Any     // Bool or NSNull
    }

    static func f(_ any: Any?) -> Double? {
        guard let n = any as? NSNumber else { return nil }
        return n.doubleValue
    }

    static func truthy(_ any: Any?) -> Bool {
        switch any {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        default: return false
        }
    }

    static func cellMetrics(_ cell: [String: Any]) -> CellMetrics {
        let q = (cell["quality"] as? [String: Any]) ?? [:]
        let e = (cell["efficiency"] as? [String: Any]) ?? [:]
        let h = (cell["handoff"] as? [String: Any]) ?? [:]
        let numeric: [String: Double?] = [
            "build_ok": truthy(q["build_ok"]) ? 1.0 : 0.0,
            "acceptance_pass_rate": f(q["acceptance_pass_rate"]),
            "unit_pass_rate": f(q["unit_pass_rate"]),
            "uitest_pass_rate": f(q["uitest_pass_rate"]),
            "lint_violations": f(q["lint_violations"]),
            "judge_completeness": f(q["judge_completeness"]),
            "judge_mvi": f(q["judge_mvi"]),
            "total_cost_usd": f(e["total_cost_usd"]),
            "wall_clock_s": f(e["wall_clock_s"]),
            "input_tokens": f(e["input_tokens"]),
            "output_tokens": f(e["output_tokens"]),
            "num_turns": f(e["num_turns"]),
            "fidelity_score": f(h["fidelity_score"]),
            "reached_terminal": truthy(h["reached_terminal"]) ? 1.0 : 0.0,
            "drift_count": f(h["drift_count"]),
            "stages_completed": f(h["stages_completed"]),
        ]
        return CellMetrics(
            numeric: numeric,
            status: (cell["status"] as? String).map { $0 as Any } ?? NSNull(),
            judgeValid: boolOrNull(q["judge_valid"]),
            contamination: boolOrNull(cell["contamination_detected"])
        )
    }

    static func boolOrNull(_ any: Any?) -> Any {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        return NSNull()
    }

    static func stats(_ values: [Double?]) -> [String: Any] {
        let vals = values.compactMap { $0 }
        if vals.isEmpty {
            return ["n": 0, "mean": NSNull(), "median": NSNull(), "stdev": NSNull()]
        }
        return [
            "n": vals.count,
            "mean": Stats.round(Stats.fmean(vals) ?? 0, 4),
            "median": Stats.round(Stats.median(vals) ?? 0, 4),
            "stdev": vals.count > 1 ? Stats.round(Stats.pstdev(vals) ?? 0, 4) : 0.0,
        ]
    }

    /// All `*/*/run-*/cell.json` paths under `resultsDir`, sorted (Python glob).
    static func cellJSONPaths(_ resultsDir: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: resultsDir, includingPropertiesForKeys: nil) else { return [] }
        var paths: [URL] = []
        for case let url as URL in en where url.lastPathComponent == "cell.json" {
            // Match glob "*/*/run-*/cell.json": run-* parent, exactly 3 dirs under resultsDir.
            let rel = url.path.dropFirst(resultsDir.path.count).split(separator: "/").map(String.init)
            if rel.count == 4, rel[2].hasPrefix("run-") {
                paths.append(url)
            }
        }
        paths.sort { $0.path < $1.path }
        return paths
    }

    static func loadCells(_ resultsDir: URL) -> [[String: Any]] {
        let paths = cellJSONPaths(resultsDir)
        var cells: [[String: Any]] = []
        for p in paths {
            if let data = try? Data(contentsOf: p),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                cells.append(obj)
            }
        }
        return cells
    }

    static func aggregate(_ resultsDir: URL, label: String? = nil) -> [String: Any] {
        let cells = loadCells(resultsDir)
        var byCell: [String: [CellMetrics]] = [:]   // key "ticket\u{0}arm"
        var order: [String] = []
        var tickets = Set<String>()
        var arms = Set<String>()
        for c in cells {
            guard let ticket = c["ticket_id"] as? String, let arm = c["arm"] as? String else { continue }
            let key = ticket + "\u{0}" + arm
            if byCell[key] == nil { order.append(key) }
            byCell[key, default: []].append(cellMetrics(c))
            tickets.insert(ticket)
            arms.insert(arm)
        }

        var matrix: [String: [String: Any]] = [:]
        for key in order {
            let parts = key.split(separator: "\u{0}", maxSplits: 1).map(String.init)
            let ticket = parts[0], arm = parts[1]
            let ms = byCell[key] ?? []
            var cellstats: [String: Any] = [:]
            for m in metricKeys {
                cellstats[m] = stats(ms.map { $0.numeric[m] ?? nil })
            }
            cellstats["runs"] = ms.count
            cellstats["statuses"] = ms.map { $0.status }
            cellstats["judge_valid"] = ms.map { $0.judgeValid }
            cellstats["contamination"] = ms.map { $0.contamination }
            matrix[ticket, default: [:]][arm] = cellstats
        }

        // Per-ticket A-vs-B deltas (axkit-flow vs baseline) on shared metrics.
        var deltas: [String: Any] = [:]
        for (ticket, armMap) in matrix {
            guard let a = armMap["axkit-flow"] as? [String: Any],
                  let b = armMap["baseline"] as? [String: Any] else { continue }
            var d: [String: Any] = [:]
            for m in metricKeys {
                guard let am = a[m] as? [String: Any], let bm = b[m] as? [String: Any],
                      let av = am["mean"] as? Double, let bv = bm["mean"] as? Double else { continue }
                let diff = Stats.round(av - bv, 4)
                var better: Any = NSNull()
                if higherBetter.contains(m) {
                    better = diff > 0 ? "axkit-flow" : (diff < 0 ? "baseline" : "tie")
                } else if lowerBetter.contains(m) {
                    better = diff < 0 ? "axkit-flow" : (diff > 0 ? "baseline" : "tie")
                }
                d[m] = ["axkit_flow": av, "baseline": bv, "delta": diff, "better": better]
            }
            deltas[ticket] = d
        }

        return [
            "results_dir": label ?? resultsDir.path,
            "tickets": tickets.sorted(),
            "arms": arms.sorted(),
            "matrix": matrix,
            "deltas": deltas,
            "n_cells": cells.count,
        ]
    }
}
