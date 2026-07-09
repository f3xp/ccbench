// Result models for ccbench: the per-cell record and its sub-parts.
//
// The cell record (`ccbench.cell.v1`) is the atomic unit of the benchmark — one
// (task × variant × run) outcome — persisted to disk so the report and offline
// rescore read from it rather than re-running agents.
//
// These types are the SDK's public result surface: they are streamed to the host
// app via `BenchEvent.cellFinished(Cell)` and decoded back from the persisted
// `cell.json`. All fields are value types, so `Sendable` is free. JSON keys are
// snake_case; see `CCJSON` for the shared coder.
import Foundation

/// Shared JSON coder: snake_case keys, pretty-printed with indent 2.
///
/// Exposed so a host app can write and read manifests with the exact on-disk
/// conventions the SDK uses (snake_case, sorted keys) rather than replicating them.
public enum CCJSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    public static func encodeString<T: Encodable>(_ value: T) throws -> String {
        String(data: try encoder.encode(value), encoding: .utf8) ?? ""
    }
}

/// Telemetry for one unit of agent work (a session, or a judge call).
public struct StepTelemetry: Codable, Sendable {
    public var step: String
    public var costUsd: Double = 0.0
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var cacheCreationTokens: Int = 0
    public var numTurns: Int = 0
    public var durationS: Double = 0.0
    public var sessionId: String?
    public var isError: Bool = false

    init(step: String) { self.step = step }

    enum CodingKeys: String, CodingKey {
        case step, costUsd, inputTokens, outputTokens, cacheReadTokens
        case cacheCreationTokens, numTurns, durationS, sessionId, isError
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        step = try c.decode(String.self, forKey: .step)
        costUsd = try c.decodeIfPresent(Double.self, forKey: .costUsd) ?? 0.0
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        cacheCreationTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0
        numTurns = try c.decodeIfPresent(Int.self, forKey: .numTurns) ?? 0
        durationS = try c.decodeIfPresent(Double.self, forKey: .durationS) ?? 0.0
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
    }
}

public struct Efficiency: Codable, Sendable {
    public var totalCostUsd: Double = 0.0
    public var wallClockS: Double = 0.0
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var cacheCreationTokens: Int = 0
    public var numTurns: Int = 0
    public var perStep: [StepTelemetry] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case totalCostUsd, wallClockS, inputTokens, outputTokens
        case cacheReadTokens, cacheCreationTokens, numTurns, perStep
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        totalCostUsd = try c.decodeIfPresent(Double.self, forKey: .totalCostUsd) ?? 0.0
        wallClockS = try c.decodeIfPresent(Double.self, forKey: .wallClockS) ?? 0.0
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        cacheCreationTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0
        numTurns = try c.decodeIfPresent(Int.self, forKey: .numTurns) ?? 0
        perStep = try c.decodeIfPresent([StepTelemetry].self, forKey: .perStep) ?? []
    }
}

/// One acceptance criterion result from a verify command.
public struct Criterion: Codable, Sendable {
    public var id: String
    public var passed: Bool
    public init(id: String, passed: Bool) { self.id = id; self.passed = passed }
}

/// Size of the produced git diff — ponytail's over-build signal.
public struct DiffMetrics: Codable, Sendable {
    public var linesAdded: Int = 0
    public var linesRemoved: Int = 0
    public var filesTouched: Int = 0
    public init() {}
    public init(linesAdded: Int, linesRemoved: Int, filesTouched: Int) {
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.filesTouched = filesTouched
    }
}

/// Comparison of produced artifacts against a reference/expected set.
public struct GoldenResult: Codable, Sendable {
    public var matched: Bool = false
    public var matchRate: Double = 0.0
    public var mismatched: [String] = []
    public init() {}
}

/// The quality axis — all signals from the configured scorers, kept side by side.
/// Deterministic verify/diff/golden results are recorded independently from LLM
/// judges so a judge failure never discards a deterministic result.
public struct Quality: Codable, Sendable {
    public var verifyRan: Bool = false
    public var verifyPassRate: Double?
    public var verifyPassed: Int?
    public var verifyTotal: Int?
    public var criteria: [Criterion] = []
    /// LLM-judge scores by dimension (e.g. "completeness" → 2.5). Empty if judges
    /// did not run or were excluded by the self-test.
    public var judges: [String: Double] = [:]
    /// Per-dimension rubric scale maxima, for rendering (e.g. "completeness" → 3).
    public var judgeScaleMax: [String: Double] = [:]
    /// False if any configured judge failed to separate its good/bad references.
    public var judgesValid: Bool?
    public var diff: DiffMetrics?
    public var golden: GoldenResult?
    /// Infra failures (setup/deps/env) recorded separately from quality regressions.
    public var infraFailure: Bool = false
    public var notes: [String] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case verifyRan, verifyPassRate, verifyPassed, verifyTotal, criteria
        case judges, judgeScaleMax, judgesValid, diff, golden, infraFailure, notes
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        verifyRan = try c.decodeIfPresent(Bool.self, forKey: .verifyRan) ?? false
        verifyPassRate = try c.decodeIfPresent(Double.self, forKey: .verifyPassRate)
        verifyPassed = try c.decodeIfPresent(Int.self, forKey: .verifyPassed)
        verifyTotal = try c.decodeIfPresent(Int.self, forKey: .verifyTotal)
        criteria = try c.decodeIfPresent([Criterion].self, forKey: .criteria) ?? []
        judges = try c.decodeIfPresent([String: Double].self, forKey: .judges) ?? [:]
        judgeScaleMax = try c.decodeIfPresent([String: Double].self, forKey: .judgeScaleMax) ?? [:]
        judgesValid = try c.decodeIfPresent(Bool.self, forKey: .judgesValid)
        diff = try c.decodeIfPresent(DiffMetrics.self, forKey: .diff)
        golden = try c.decodeIfPresent(GoldenResult.self, forKey: .golden)
        infraFailure = try c.decodeIfPresent(Bool.self, forKey: .infraFailure) ?? false
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
    }
}

public struct Artifacts: Codable, Sendable {
    public var worktree: String?
    public var transcripts: [String] = []
    public var diff: String?
    public var verifyLog: String?

    init(worktree: String? = nil) { self.worktree = worktree }

    enum CodingKeys: String, CodingKey {
        case worktree, transcripts, diff, verifyLog
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        worktree = try c.decodeIfPresent(String.self, forKey: .worktree)
        transcripts = try c.decodeIfPresent([String].self, forKey: .transcripts) ?? []
        diff = try c.decodeIfPresent(String.self, forKey: .diff)
        verifyLog = try c.decodeIfPresent(String.self, forKey: .verifyLog)
    }
}

public struct Cell: Codable, Sendable {
    public var schemaVersion: String = "ccbench.cell.v1"
    public var taskId: String
    public var variantId: String
    public var runIndex: Int
    public var startedAt: String
    public var endedAt: String?
    public var status: String = "ok"
    public var error: String?

    // Provenance for reproducibility / audit.
    public var agentModel: String?
    public var variantKind: String?
    public var variantMountSha: String?
    public var sandboxSeedSha: String?

    public var quality: Quality = Quality()
    public var efficiency: Efficiency = Efficiency()
    public var artifacts: Artifacts = Artifacts()

    // Contamination guard: a control variant's worktree must not contain any
    // workflow mount used by the other variants.
    public var contaminationDetected: Bool?

    init(taskId: String, variantId: String, runIndex: Int, startedAt: String) {
        self.taskId = taskId
        self.variantId = variantId
        self.runIndex = runIndex
        self.startedAt = startedAt
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, taskId, variantId, runIndex, startedAt, endedAt, status, error
        case agentModel, variantKind, variantMountSha, sandboxSeedSha
        case quality, efficiency, artifacts, contaminationDetected
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(String.self, forKey: .schemaVersion) ?? "ccbench.cell.v1"
        taskId = try c.decode(String.self, forKey: .taskId)
        variantId = try c.decode(String.self, forKey: .variantId)
        runIndex = try c.decode(Int.self, forKey: .runIndex)
        startedAt = try c.decode(String.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(String.self, forKey: .endedAt)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "ok"
        error = try c.decodeIfPresent(String.self, forKey: .error)
        agentModel = try c.decodeIfPresent(String.self, forKey: .agentModel)
        variantKind = try c.decodeIfPresent(String.self, forKey: .variantKind)
        variantMountSha = try c.decodeIfPresent(String.self, forKey: .variantMountSha)
        sandboxSeedSha = try c.decodeIfPresent(String.self, forKey: .sandboxSeedSha)
        quality = try c.decodeIfPresent(Quality.self, forKey: .quality) ?? Quality()
        efficiency = try c.decodeIfPresent(Efficiency.self, forKey: .efficiency) ?? Efficiency()
        artifacts = try c.decodeIfPresent(Artifacts.self, forKey: .artifacts) ?? Artifacts()
        contaminationDetected = try c.decodeIfPresent(Bool.self, forKey: .contaminationDetected)
    }
}
