// Aggregate cell.json files into per-(task,variant) matrices with stats + deltas.
//
// Pure offline: reads persisted cells (and the run's `variants.json` snapshot)
// only, so it can be re-run any time without touching agents. The aggregate is a
// loosely-typed `[String: Any]` tree so it serialises to stable JSON. Deltas are
// computed for every non-control variant against the control variant.
import Foundation

enum Aggregate {
    static let higherBetter: Set<String> = ["verify_pass_rate", "golden_match_rate"]
    static let lowerBetter: Set<String> = [
        "total_cost_usd", "wall_clock_s", "output_tokens", "num_turns",
        "lines_added", "lines_removed", "files_touched",
    ]

    /// Fixed metric keys (judge_<dim> keys are discovered per run and appended).
    static let baseMetricKeys = [
        "verify_pass_rate", "golden_match_rate",
        "total_cost_usd", "wall_clock_s", "output_tokens", "num_turns",
        "lines_added", "lines_removed", "files_touched",
    ]

    struct CellMetrics {
        var numeric: [String: Double?]
        var status: Any
        var judgesValid: Any
        var contamination: Any
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
    static func boolOrNull(_ any: Any?) -> Any {
        if let n = any as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        if let b = any as? Bool { return b }
        return NSNull()
    }

    static func cellMetrics(_ cell: [String: Any]) -> CellMetrics {
        let q = (cell["quality"] as? [String: Any]) ?? [:]
        let e = (cell["efficiency"] as? [String: Any]) ?? [:]
        let d = (q["diff"] as? [String: Any]) ?? [:]
        let golden = (q["golden"] as? [String: Any]) ?? [:]
        var numeric: [String: Double?] = [
            "verify_pass_rate": f(q["verify_pass_rate"]),
            "golden_match_rate": f(golden["match_rate"]),
            "total_cost_usd": f(e["total_cost_usd"]),
            "wall_clock_s": f(e["wall_clock_s"]),
            "output_tokens": f(e["output_tokens"]),
            "num_turns": f(e["num_turns"]),
            "lines_added": f(d["lines_added"]),
            "lines_removed": f(d["lines_removed"]),
            "files_touched": f(d["files_touched"]),
        ]
        // Dynamic judge dimensions: judge_<dim>.
        if let judges = q["judges"] as? [String: Any] {
            for (dim, val) in judges { numeric["judge_\(dim)"] = f(val) }
        }
        return CellMetrics(
            numeric: numeric,
            status: (cell["status"] as? String).map { $0 as Any } ?? NSNull(),
            judgesValid: boolOrNull(q["judges_valid"]),
            contamination: boolOrNull(cell["contamination_detected"])
        )
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

    static func cellJSONPaths(_ resultsDir: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: resultsDir, includingPropertiesForKeys: nil) else { return [] }
        var paths: [URL] = []
        for case let url as URL in en where url.lastPathComponent == "cell.json" {
            let rel = url.path.dropFirst(resultsDir.path.count).split(separator: "/").map(String.init)
            if rel.count == 4, rel[2].hasPrefix("run-") { paths.append(url) }
        }
        paths.sort { $0.path < $1.path }
        return paths
    }

    static func loadCells(_ resultsDir: URL) -> [[String: Any]] {
        cellJSONPaths(resultsDir).compactMap { p in
            guard let data = try? Data(contentsOf: p),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return obj
        }
    }

    /// Which variant is the control, from the run's `variants.json` snapshot;
    /// falls back to a variant named "vanilla", else the first seen.
    static func controlVariant(_ resultsDir: URL, seen: [String]) -> String? {
        let meta = resultsDir.appendingPathComponent("variants.json")
        if let data = try? Data(contentsOf: meta),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            if let ctrl = arr.first(where: { truthy($0["control"]) })?["id"] as? String { return ctrl }
        }
        if seen.contains("vanilla") { return "vanilla" }
        return seen.first
    }

    static func aggregate(_ resultsDir: URL, label: String? = nil) -> [String: Any] {
        let cells = loadCells(resultsDir)
        var byCell: [String: [CellMetrics]] = [:]     // key "task\u{0}variant"
        var order: [String] = []
        var tasks = Set<String>(), variants = Set<String>()
        var judgeDims = Set<String>()

        for c in cells {
            guard let task = c["task_id"] as? String, let variant = c["variant_id"] as? String else { continue }
            let key = task + "\u{0}" + variant
            if byCell[key] == nil { order.append(key) }
            let m = cellMetrics(c)
            byCell[key, default: []].append(m)
            tasks.insert(task); variants.insert(variant)
            for k in m.numeric.keys where k.hasPrefix("judge_") { judgeDims.insert(k) }
        }

        let metricKeys = baseMetricKeys + judgeDims.sorted()

        var matrix: [String: [String: Any]] = [:]
        for key in order {
            let parts = key.split(separator: "\u{0}", maxSplits: 1).map(String.init)
            let task = parts[0], variant = parts[1]
            let ms = byCell[key] ?? []
            var cellstats: [String: Any] = [:]
            for m in metricKeys { cellstats[m] = stats(ms.map { $0.numeric[m] ?? nil }) }
            cellstats["runs"] = ms.count
            cellstats["statuses"] = ms.map { $0.status }
            cellstats["judges_valid"] = ms.map { $0.judgesValid }
            cellstats["contamination"] = ms.map { $0.contamination }
            matrix[task, default: [:]][variant] = cellstats
        }

        let control = controlVariant(resultsDir, seen: variants.sorted())

        // Per-task deltas: each non-control variant vs the control (median-based).
        var deltas: [String: Any] = [:]
        if let control {
            for (task, vmap) in matrix {
                guard let ctrl = vmap[control] as? [String: Any] else { continue }
                var perVariant: [String: Any] = [:]
                for (variant, stats) in vmap where variant != control {
                    guard let vstats = stats as? [String: Any] else { continue }
                    var d: [String: Any] = [:]
                    for m in metricKeys {
                        guard let vm = vstats[m] as? [String: Any], let cm = ctrl[m] as? [String: Any],
                              let vv = vm["median"] as? Double, let cv = cm["median"] as? Double else { continue }
                        let diff = Stats.round(vv - cv, 4)
                        var better: Any = NSNull()
                        if higherBetter.contains(m) || m.hasPrefix("judge_") {
                            better = diff > 0 ? variant : (diff < 0 ? control : "tie")
                        } else if lowerBetter.contains(m) {
                            better = diff < 0 ? variant : (diff > 0 ? control : "tie")
                        }
                        d[m] = ["variant": vv, "control": cv, "delta": diff, "better": better]
                    }
                    perVariant[variant] = d
                }
                deltas[task] = perVariant
            }
        }

        return [
            "results_dir": label ?? resultsDir.path,
            "tasks": tasks.sorted(),
            "variants": variants.sorted(),
            "control": control ?? NSNull(),
            "metrics": metricKeys,
            "matrix": matrix,
            "deltas": deltas,
            "n_cells": cells.count,
        ]
    }
}
