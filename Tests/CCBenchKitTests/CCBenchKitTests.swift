import Foundation
import Testing
@testable import CCBenchKit

// MARK: - Fixtures

private enum Fixture {
    /// A fresh, unique temp directory (cleaned up by the OS).
    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbenchkit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func writeCell(runDir: URL, task: String, variant: String, run: Int, json: String) throws {
        let d = runDir.appendingPathComponent("\(task)/\(variant)/run-\(run)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try json.write(to: d.appendingPathComponent("cell.json"), atomically: true, encoding: .utf8)
    }

    static func writeVariantsSnapshot(_ runDir: URL, _ json: String) throws {
        try json.write(to: runDir.appendingPathComponent("variants.json"), atomically: true, encoding: .utf8)
    }

    /// A run directory with one control (baseline, 2 runs) + one skill variant.
    static func standardRun(at runDir: URL, startedAt: String = "2026-07-01T10:00:00Z") throws {
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try writeVariantsSnapshot(runDir, #"[{"id":"baseline","control":true},{"id":"skillx","control":false}]"#)
        try writeCell(runDir: runDir, task: "TASK-A", variant: "baseline", run: 0, json: """
        {"task_id":"TASK-A","variant_id":"baseline","run_index":0,"started_at":"\(startedAt)","status":"ok",
         "quality":{"verify_pass_rate":1.0,"judges":{"quality":3.0},"judges_valid":true,
                    "diff":{"lines_added":10,"lines_removed":2,"files_touched":3},"golden":{"match_rate":0.5}},
         "efficiency":{"total_cost_usd":1.5,"wall_clock_s":100,"output_tokens":2000,"num_turns":5},
         "contamination_detected":false}
        """)
        try writeCell(runDir: runDir, task: "TASK-A", variant: "baseline", run: 1, json: """
        {"task_id":"TASK-A","variant_id":"baseline","run_index":1,"started_at":"2026-07-01T10:05:00Z","status":"ok",
         "quality":{"verify_pass_rate":0.5,"judges":{"quality":4.0},"judges_valid":true,
                    "diff":{"lines_added":20,"lines_removed":4,"files_touched":6},"golden":{"match_rate":0.7}},
         "efficiency":{"total_cost_usd":2.5,"wall_clock_s":120,"output_tokens":3000,"num_turns":7},
         "contamination_detected":false}
        """)
        try writeCell(runDir: runDir, task: "TASK-A", variant: "skillx", run: 0, json: """
        {"task_id":"TASK-A","variant_id":"skillx","run_index":0,"started_at":"2026-07-01T10:10:00Z","status":"ok",
         "quality":{"verify_pass_rate":1.0,"judges":{"quality":5.0},"judges_valid":true,
                    "diff":{"lines_added":5,"lines_removed":1,"files_touched":2},"golden":{"match_rate":1.0}},
         "efficiency":{"total_cost_usd":1.0,"wall_clock_s":80,"output_tokens":1500,"num_turns":4},
         "contamination_detected":false}
        """)
    }

    static func workspace(root: URL) -> CCWorkspace {
        CCWorkspace(
            tasksDir: root.appendingPathComponent("tasks"),
            variantsDir: root.appendingPathComponent("variants"),
            resultsDir: root.appendingPathComponent("results"),
            scratchDir: root.appendingPathComponent(".scratch")
        )
    }
}

// MARK: - CR-3: coder + manifest load/save/validate

@Test func variantSaveLoadRoundTrip() throws {
    let root = try Fixture.tempDir()
    let variantsDir = root.appendingPathComponent("variants")

    var v = Variant(id: "skillx", kind: .skill, control: false)
    v.mount = "/some/mount"
    v.promptFile = "spec.md"
    v.allowedTools = ["Read", "Edit"]

    let url = variantsDir.appendingPathComponent("skillx.json")
    try Manifests.save(v, to: url)

    // On-disk conventions: snake_case keys, sorted.
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("\"prompt_file\""))
    let controlIdx = try #require(text.range(of: "\"control\""))
    let idIdx = try #require(text.range(of: "\"id\""))
    #expect(controlIdx.lowerBound < idIdx.lowerBound, "keys should be sorted alphabetically")

    // Reload via the public loader and confirm a faithful round-trip.
    let loaded = try Manifests.loadVariants(from: variantsDir, ids: ["skillx"])
    #expect(loaded.count == 1)
    #expect(try CCJSON.encodeString(loaded[0]) == CCJSON.encodeString(v))
}

@Test func taskSaveLoadRoundTrip() throws {
    let root = try Fixture.tempDir()
    let tasksDir = root.appendingPathComponent("tasks")

    var t = BenchTask(id: "TASK-A", repo: "/repo", baseRef: "main")
    t.prompt = "do the thing"
    t.seedFiles = ["Package.resolved"]

    try Manifests.save(t, to: tasksDir.appendingPathComponent("TASK-A/task.json"))
    let loaded = try Manifests.loadTasks(from: tasksDir, ids: ["TASK-A"])
    #expect(loaded.count == 1)
    #expect(loaded[0].id == "TASK-A")
    #expect(loaded[0].repo == "/repo")
    #expect(loaded[0].prompt == "do the thing")
    // The loader sets `dir` (not part of the schema) to the task directory.
    #expect(loaded[0].dir.lastPathComponent == "TASK-A")
}

@Test func validateTaskReportsMissingPathsAndNoVerify() throws {
    let root = try Fixture.tempDir()
    var t = BenchTask(id: "T", repo: "/repo", baseRef: "main")
    t.dir = root                       // exists, but the referenced file does not
    t.promptFile = "missing-prompt.md"

    let issues = Manifests.validate(task: t)
    #expect(issues.contains { $0.field == "prompt_file" && $0.isError })
    // No verify command configured → a (non-blocking) warning.
    #expect(issues.contains { $0.field == "scoring.verify" && !$0.isError })
}

@Test func validateVariantControlCount() throws {
    let root = try Fixture.tempDir()
    let variantsDir = root.appendingPathComponent("variants")

    // Two controls → error.
    var a = Variant(id: "a", kind: .vanilla, control: true)
    var b = Variant(id: "b", kind: .vanilla, control: true)
    try Manifests.save(a, to: variantsDir.appendingPathComponent("a.json"))
    try Manifests.save(b, to: variantsDir.appendingPathComponent("b.json"))
    #expect(Manifests.validate(variant: a, in: variantsDir).contains { $0.field == "control" && $0.isError })

    // Exactly one control → no control error.
    b.control = false
    try Manifests.save(b, to: variantsDir.appendingPathComponent("b.json"))
    #expect(!Manifests.validate(variant: a, in: variantsDir).contains { $0.field == "control" })

    // Skill variant with an unresolvable mount → error.
    var s = Variant(id: "s", kind: .skill, control: false)
    s.mount = "/definitely/not/here-\(UUID().uuidString)"
    try Manifests.save(s, to: variantsDir.appendingPathComponent("s.json"))
    _ = a; _ = b
    #expect(Manifests.validate(variant: s, in: variantsDir).contains { $0.field == "mount" && $0.isError })
}

// MARK: - CR-1: typed aggregate

@Test func aggregateByteMatchAndRoundTrip() throws {
    let root = try Fixture.tempDir()
    let runDir = root.appendingPathComponent("results").appendingPathComponent("run1")
    try Fixture.standardRun(at: runDir)

    let bench = CCBench(workspace: Fixture.workspace(root: root))
    let jsonString = bench.aggregateJSON(resultsDir: runDir)
    let typed = bench.aggregate(resultsDir: runDir)

    // The CLI string is exactly the typed model projected + serialized.
    #expect(PyJSON.dumps(typed.asTree()) == jsonString)

    // A plain decoder reconstructs the typed model losslessly from that string.
    let decoded = try JSONDecoder().decode(AggregateResult.self, from: Data(jsonString.utf8))
    #expect(decoded == typed)

    // Spot-check the computed values.
    #expect(typed.control == "baseline")
    #expect(typed.nCells == 3)
    #expect(typed.tasks == ["TASK-A"])
    #expect(typed.variants == ["baseline", "skillx"])
    #expect(typed.matrix["TASK-A"]?["baseline"]?.runs == 2)
    #expect(typed.matrix["TASK-A"]?["baseline"]?.metrics["verify_pass_rate"]?.median == 0.75)
    #expect(typed.matrix["TASK-A"]?["skillx"]?.metrics["verify_pass_rate"]?.stdev == 0.0)
    let delta = try #require(typed.deltas["TASK-A"]?["skillx"]?["verify_pass_rate"])
    #expect(delta.better == "skillx")
    #expect(delta.delta == 0.25)
    // judge_ and higher-is-better metrics are marked accordingly.
    #expect(typed.metricInfos.first { $0.key == "judge_quality" }?.higherIsBetter == true)
    #expect(typed.metricInfos.first { $0.key == "total_cost_usd" }?.higherIsBetter == false)
}

@Test func aggregateEmptyDirIsWellFormed() throws {
    let root = try Fixture.tempDir()
    let runDir = root.appendingPathComponent("results").appendingPathComponent("empty")
    try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)

    let bench = CCBench(workspace: Fixture.workspace(root: root))
    let typed = bench.aggregate(resultsDir: runDir)
    #expect(typed.nCells == 0)
    #expect(typed.control == nil)
    #expect(typed.matrix.isEmpty)
    #expect(typed.deltas.isEmpty)
    // Still round-trips through the tree + a plain decoder.
    let jsonString = bench.aggregateJSON(resultsDir: runDir)
    #expect(PyJSON.dumps(typed.asTree()) == jsonString)
}

// MARK: - CR-2: run enumeration

@Test func runsAreListedNewestFirst() throws {
    let root = try Fixture.tempDir()
    let resultsRoot = root.appendingPathComponent("results")
    try Fixture.standardRun(at: resultsRoot.appendingPathComponent("run-old"),
                            startedAt: "2026-07-01T09:00:00Z")
    try Fixture.standardRun(at: resultsRoot.appendingPathComponent("run-new"),
                            startedAt: "2026-07-02T09:00:00Z")

    let bench = CCBench(workspace: Fixture.workspace(root: root))
    let runs = bench.runs()
    #expect(runs.count == 2)
    #expect(runs.first?.name == "run-new")           // newest-first by startedAt
    #expect(runs.last?.name == "run-old")
    #expect(runs.first?.nCells == 3)
    #expect(runs.first?.tasks == ["TASK-A"])
    #expect(runs.first?.variants == ["baseline", "skillx"])
    // startedAt is the earliest cell in each run; run-new's is later than run-old's.
    let newStart = try #require(runs.first?.startedAt)
    let oldStart = try #require(runs.last?.startedAt)
    #expect(newStart > oldStart)
    #expect(runs.first?.headlineVerifyPassRate != nil)
    #expect(runs.first?.headlineCostUsd == 5.0)       // 1.5 + 2.5 + 1.0
}

// MARK: - CR-4: Codable config

@Test func configCodableRoundTripAndSnakeCase() throws {
    var cfg = CCConfig.default
    cfg.budgets.maxCostUsdPerRun = 12.5
    cfg.claude.allowedTools = ["Read"]

    let data = try CCJSON.encoder.encode(cfg)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(text.contains("max_cost_usd_per_run"))    // snake_case on disk

    let back = try CCJSON.decoder.decode(CCConfig.self, from: data)
    #expect(back.budgets.maxCostUsdPerRun == 12.5)
    #expect(back.claude.allowedTools == ["Read"])
    #expect(back.models.agent == cfg.models.agent)
    #expect(back.pushGuard == cfg.pushGuard)
}

@Test func configPartialDecodeUsesDefaults() throws {
    let partial = Data(#"{"runs_per_cell": 7}"#.utf8)
    let cfg = try CCJSON.decoder.decode(CCConfig.self, from: partial)
    #expect(cfg.runsPerCell == 7)
    #expect(cfg.budgets.maxCostUsdPerRun == 40.0)      // default preserved
    #expect(cfg.models.agent == "opus")                // default preserved
    #expect(cfg.pushGuard == true)                     // default preserved
}

// MARK: - CR-5: plan validation

@Test func validatePlanResolvesIDsAndControl() async throws {
    let root = try Fixture.tempDir()
    let ws = Fixture.workspace(root: root)

    // One control + one skill variant (mount points at an existing dir).
    let mountDir = root.appendingPathComponent("skill-mount")
    try FileManager.default.createDirectory(at: mountDir, withIntermediateDirectories: true)
    let baseline = Variant(id: "baseline", kind: .vanilla, control: true)
    var skillx = Variant(id: "skillx", kind: .skill, control: false)
    skillx.mount = mountDir.path
    try Manifests.save(baseline, to: ws.variantsDir.appendingPathComponent("baseline.json"))
    try Manifests.save(skillx, to: ws.variantsDir.appendingPathComponent("skillx.json"))

    var task = BenchTask(id: "TASK-A", repo: "/repo", baseRef: "main")
    task.prompt = "x"
    try Manifests.save(task, to: ws.tasksDir.appendingPathComponent("TASK-A/task.json"))

    let bench = CCBench(workspace: ws)

    // Valid plan: no errors.
    let ok = try await bench.validate(RunPlan(taskIDs: ["TASK-A"], variantIDs: ["baseline", "skillx"]))
    #expect(!ok.contains { $0.isError })

    // Unknown variant id → error.
    let bad = try await bench.validate(RunPlan(taskIDs: ["TASK-A"], variantIDs: ["nope"]))
    #expect(bad.contains { $0.isError })
}
