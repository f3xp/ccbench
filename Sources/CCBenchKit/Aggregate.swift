// Aggregate cell.json files into per-(task,variant) matrices with stats + deltas.
//
// Pure offline: reads persisted cells (and the run's `variants.json` snapshot)
// only, so it can be re-run any time without touching agents. The aggregate is a
// loosely-typed `[String: Any]` tree so it serialises to stable JSON. Deltas are
// computed for every non-control variant against the control variant.
import Foundation

// MARK: - Typed aggregate model

/// Summary statistics for one metric within a (task, variant) cell. `mean`,
/// `median`, and `stdev` are `nil` when there are no runs (`n == 0`).
public struct MetricStats: Codable, Sendable, Equatable {
    public var n: Int
    public var mean: Double?
    public var median: Double?
    public var stdev: Double?

    public init(n: Int, mean: Double?, median: Double?, stdev: Double?) {
        self.n = n; self.mean = mean; self.median = median; self.stdev = stdev
    }
}

/// A non-control variant's median delta vs. the control for one metric. `better`
/// is the id of the winning variant, `"tie"`, or `nil` for neutral metrics.
public struct MetricDelta: Codable, Sendable, Equatable {
    public var variant: Double
    public var control: Double
    public var delta: Double
    public var better: String?

    public init(variant: Double, control: Double, delta: Double, better: String?) {
        self.variant = variant; self.control = control; self.delta = delta; self.better = better
    }
}

/// A metric key plus its optimisation direction (`true` higher-is-better,
/// `false` lower-is-better, `nil` neutral). Derived, not encoded on the wire.
public struct MetricInfo: Sendable, Equatable {
    public var key: String
    public var higherIsBetter: Bool?

    public init(key: String, higherIsBetter: Bool?) {
        self.key = key; self.higherIsBetter = higherIsBetter
    }
}

/// One (task, variant) cell: per-metric stats plus the raw per-run statuses,
/// judge-validity, and contamination flags. Encodes flat (metric keys inline
/// alongside `runs`/`statuses`/…) to match the on-disk aggregate shape.
public struct CellStats: Codable, Sendable, Equatable {
    public var metrics: [String: MetricStats]
    public var runs: Int
    public var statuses: [String?]
    public var judgesValid: [Bool?]
    public var contamination: [Bool?]

    public init(metrics: [String: MetricStats], runs: Int,
                statuses: [String?], judgesValid: [Bool?], contamination: [Bool?]) {
        self.metrics = metrics; self.runs = runs
        self.statuses = statuses; self.judgesValid = judgesValid; self.contamination = contamination
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
        static let runs = AnyKey(stringValue: "runs")
        static let statuses = AnyKey(stringValue: "statuses")
        static let judgesValid = AnyKey(stringValue: "judges_valid")
        static let contamination = AnyKey(stringValue: "contamination")
    }
    private static let reserved: Set<String> = ["runs", "statuses", "judges_valid", "contamination"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        runs = try c.decodeIfPresent(Int.self, forKey: .runs) ?? 0
        statuses = try c.decodeIfPresent([String?].self, forKey: .statuses) ?? []
        judgesValid = try c.decodeIfPresent([Bool?].self, forKey: .judgesValid) ?? []
        contamination = try c.decodeIfPresent([Bool?].self, forKey: .contamination) ?? []
        var m: [String: MetricStats] = [:]
        for key in c.allKeys where !Self.reserved.contains(key.stringValue) {
            m[key.stringValue] = try c.decode(MetricStats.self, forKey: key)
        }
        metrics = m
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (key, stats) in metrics { try c.encode(stats, forKey: AnyKey(stringValue: key)) }
        try c.encode(runs, forKey: .runs)
        try c.encode(statuses, forKey: .statuses)
        try c.encode(judgesValid, forKey: .judgesValid)
        try c.encode(contamination, forKey: .contamination)
    }
}

/// The aggregate matrices for a results directory: per-(task, variant) stats and
/// per-metric deltas vs. the control. This is the typed source of truth; the CLI's
/// pretty JSON is a projection of it (`asTree()` + `PyJSON`).
///
/// Uses literal snake_case coding keys (independent of any key-strategy), so it
/// round-trips losslessly with a plain `JSONEncoder`/`JSONDecoder` — including the
/// dynamic snake_case metric names, which a `.convertFromSnakeCase` decoder would
/// otherwise mangle.
public struct AggregateResult: Codable, Sendable, Equatable {
    public var resultsDir: String
    public var tasks: [String]
    public var variants: [String]
    public var control: String?
    /// Ordered metric keys (fixed base keys, then discovered `judge_<dim>` keys).
    public var metrics: [String]
    /// task → variant → cell stats.
    public var matrix: [String: [String: CellStats]]
    /// task → variant → metric → delta (present only when a control exists).
    public var deltas: [String: [String: [String: MetricDelta]]]
    public var nCells: Int

    /// Metric keys paired with their optimisation direction.
    public var metricInfos: [MetricInfo] {
        metrics.map { key in
            let dir: Bool?
            if Aggregate.higherBetter.contains(key) || key.hasPrefix("judge_") { dir = true }
            else if Aggregate.lowerBetter.contains(key) { dir = false }
            else { dir = nil }
            return MetricInfo(key: key, higherIsBetter: dir)
        }
    }

    enum CodingKeys: String, CodingKey {
        case resultsDir = "results_dir"
        case tasks, variants, control, metrics, matrix, deltas
        case nCells = "n_cells"
    }

    public init(resultsDir: String, tasks: [String], variants: [String], control: String?,
                metrics: [String], matrix: [String: [String: CellStats]],
                deltas: [String: [String: [String: MetricDelta]]], nCells: Int) {
        self.resultsDir = resultsDir; self.tasks = tasks; self.variants = variants
        self.control = control; self.metrics = metrics; self.matrix = matrix
        self.deltas = deltas; self.nCells = nCells
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resultsDir = try c.decodeIfPresent(String.self, forKey: .resultsDir) ?? ""
        tasks = try c.decodeIfPresent([String].self, forKey: .tasks) ?? []
        variants = try c.decodeIfPresent([String].self, forKey: .variants) ?? []
        control = try c.decodeIfPresent(String.self, forKey: .control)
        metrics = try c.decodeIfPresent([String].self, forKey: .metrics) ?? []
        matrix = try c.decodeIfPresent([String: [String: CellStats]].self, forKey: .matrix) ?? [:]
        deltas = try c.decodeIfPresent([String: [String: [String: MetricDelta]]].self, forKey: .deltas) ?? [:]
        nCells = try c.decodeIfPresent(Int.self, forKey: .nCells) ?? 0
    }

    /// Project back to the loosely-typed tree the report renderer and `PyJSON`
    /// consume — byte-for-byte the historical aggregate shape.
    public func asTree() -> [String: Any] {
        var matrixTree: [String: Any] = [:]
        for (task, vmap) in matrix {
            var vt: [String: Any] = [:]
            for (variant, cell) in vmap { vt[variant] = cell.asTree() }
            matrixTree[task] = vt
        }
        var deltasTree: [String: Any] = [:]
        for (task, vmap) in deltas {
            var vt: [String: Any] = [:]
            for (variant, dmap) in vmap {
                var dt: [String: Any] = [:]
                for (metric, delta) in dmap { dt[metric] = delta.asTree() }
                vt[variant] = dt
            }
            deltasTree[task] = vt
        }
        return [
            "results_dir": resultsDir,
            "tasks": tasks,
            "variants": variants,
            "control": control.map { $0 as Any } ?? NSNull(),
            "metrics": metrics,
            "matrix": matrixTree,
            "deltas": deltasTree,
            "n_cells": nCells,
        ]
    }
}

extension MetricStats {
    func asTree() -> [String: Any] {
        [
            "n": n,
            "mean": mean.map { $0 as Any } ?? NSNull(),
            "median": median.map { $0 as Any } ?? NSNull(),
            "stdev": stdev.map { $0 as Any } ?? NSNull(),
        ]
    }
}

extension MetricDelta {
    func asTree() -> [String: Any] {
        [
            "variant": variant,
            "control": control,
            "delta": delta,
            "better": better.map { $0 as Any } ?? NSNull(),
        ]
    }
}

extension CellStats {
    func asTree() -> [String: Any] {
        var node: [String: Any] = [:]
        for (metric, stats) in metrics { node[metric] = stats.asTree() }
        node["runs"] = runs
        node["statuses"] = statuses.map { $0.map { $0 as Any } ?? NSNull() }
        node["judges_valid"] = judgesValid.map { $0.map { $0 as Any } ?? NSNull() }
        node["contamination"] = contamination.map { $0.map { $0 as Any } ?? NSNull() }
        return node
    }
}

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

    static func stats(_ values: [Double?]) -> MetricStats {
        let vals = values.compactMap { $0 }
        if vals.isEmpty {
            return MetricStats(n: 0, mean: nil, median: nil, stdev: nil)
        }
        return MetricStats(
            n: vals.count,
            mean: Stats.round(Stats.fmean(vals) ?? 0, 4),
            median: Stats.round(Stats.median(vals) ?? 0, 4),
            stdev: vals.count > 1 ? Stats.round(Stats.pstdev(vals) ?? 0, 4) : 0.0
        )
    }

    static func cellJSONPaths(_ resultsDir: URL) -> [URL] {
        let fm = FileManager.default
        // Compare by path *components* against a symlink-resolved base: the
        // directory enumerator canonicalises paths (e.g. /var → /private/var on
        // macOS), so string-length prefix math against a caller-supplied
        // unresolved path can misalign. Expect `<task>/<variant>/run-<k>/cell.json`.
        let base = resultsDir.resolvingSymlinksInPath()
        let baseCount = base.pathComponents.count
        guard let en = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        var paths: [URL] = []
        for case let url as URL in en where url.lastPathComponent == "cell.json" {
            let rel = Array(url.resolvingSymlinksInPath().pathComponents.dropFirst(baseCount))
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

    /// The loosely-typed tree the report renderer + `PyJSON` consume. A thin
    /// projection of the typed `aggregateResult` — the single source of truth.
    static func aggregate(_ resultsDir: URL, label: String? = nil) -> [String: Any] {
        aggregateResult(resultsDir, label: label).asTree()
    }

    /// Build the typed aggregate model from a results directory.
    static func aggregateResult(_ resultsDir: URL, label: String? = nil) -> AggregateResult {
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

        var matrix: [String: [String: CellStats]] = [:]
        for key in order {
            let parts = key.split(separator: "\u{0}", maxSplits: 1).map(String.init)
            let task = parts[0], variant = parts[1]
            let ms = byCell[key] ?? []
            var metrics: [String: MetricStats] = [:]
            for m in metricKeys { metrics[m] = stats(ms.map { $0.numeric[m] ?? nil }) }
            let cell = CellStats(
                metrics: metrics,
                runs: ms.count,
                statuses: ms.map { $0.status as? String },
                judgesValid: ms.map { $0.judgesValid as? Bool },
                contamination: ms.map { $0.contamination as? Bool }
            )
            matrix[task, default: [:]][variant] = cell
        }

        let control = controlVariant(resultsDir, seen: variants.sorted())

        // Per-task deltas: each non-control variant vs the control (median-based).
        var deltas: [String: [String: [String: MetricDelta]]] = [:]
        if let control {
            for (task, vmap) in matrix {
                guard let ctrl = vmap[control] else { continue }
                var perVariant: [String: [String: MetricDelta]] = [:]
                for (variant, cell) in vmap where variant != control {
                    var d: [String: MetricDelta] = [:]
                    for m in metricKeys {
                        guard let vm = cell.metrics[m], let cm = ctrl.metrics[m],
                              let vv = vm.median, let cv = cm.median else { continue }
                        let diff = Stats.round(vv - cv, 4)
                        var better: String?
                        if higherBetter.contains(m) || m.hasPrefix("judge_") {
                            better = diff > 0 ? variant : (diff < 0 ? control : "tie")
                        } else if lowerBetter.contains(m) {
                            better = diff < 0 ? variant : (diff > 0 ? control : "tie")
                        }
                        d[m] = MetricDelta(variant: vv, control: cv, delta: diff, better: better)
                    }
                    perVariant[variant] = d
                }
                deltas[task] = perVariant
            }
        }

        return AggregateResult(
            resultsDir: label ?? resultsDir.path,
            tasks: tasks.sorted(),
            variants: variants.sorted(),
            control: control,
            metrics: metricKeys,
            matrix: matrix,
            deltas: deltas,
            nCells: cells.count
        )
    }
}
