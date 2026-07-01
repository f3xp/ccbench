// Result models for axbench: the per-cell record and its sub-parts.
//
// Port of harness/schemas.py. The cell record (`axbench.cell.v1`) is the atomic
// unit of the benchmark — one (ticket × arm × run) outcome — persisted to disk
// so the report and offline rescore read from it rather than re-running agents.
//
// pydantic `BaseModel` → `Codable` struct. JSON keys are snake_case (matching the
// Python `model_dump_json`); see `AxJSON` for the shared coder that applies the
// snake_case ↔ camelCase conversion and pretty-prints with indent 2.
import Foundation

/// Shared JSON coder matching Python's `json.dumps(indent=2)` / pydantic output.
enum AxJSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted]
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static func encodeString<T: Encodable>(_ value: T) throws -> String {
        String(data: try encoder.encode(value), encoding: .utf8) ?? ""
    }
}

struct StageTelemetry: Codable {
    var stage: String
    var costUsd: Double = 0.0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var numTurns: Int = 0
    var durationS: Double = 0.0
    var sessionId: String?
    var isError: Bool = false

    init(stage: String) { self.stage = stage }

    enum CodingKeys: String, CodingKey {
        case stage, costUsd, inputTokens, outputTokens, cacheReadTokens
        case cacheCreationTokens, numTurns, durationS, sessionId, isError
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        stage = try c.decode(String.self, forKey: .stage)
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

struct Efficiency: Codable {
    var totalCostUsd: Double = 0.0
    var wallClockS: Double = 0.0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var numTurns: Int = 0
    var perStage: [StageTelemetry] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case totalCostUsd, wallClockS, inputTokens, outputTokens
        case cacheReadTokens, cacheCreationTokens, numTurns, perStage
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        totalCostUsd = try c.decodeIfPresent(Double.self, forKey: .totalCostUsd) ?? 0.0
        wallClockS = try c.decodeIfPresent(Double.self, forKey: .wallClockS) ?? 0.0
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        cacheCreationTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0
        numTurns = try c.decodeIfPresent(Int.self, forKey: .numTurns) ?? 0
        perStage = try c.decodeIfPresent([StageTelemetry].self, forKey: .perStage) ?? []
    }
}

struct Quality: Codable {
    var buildOk: Bool = false
    var unitPassRate: Double?
    var uitestPassRate: Double?
    var acceptancePassRate: Double?
    var unitPassed: Int = 0
    var unitTotal: Int = 0
    var uitestPassed: Int = 0
    var uitestTotal: Int = 0
    var lintViolations: Int?
    var lintErrors: Int?
    var judgeCompleteness: Double?
    var judgeMvi: Double?
    var judgeValid: Bool?
    // Infra failures recorded separately so they don't masquerade as quality regressions.
    var infraFailure: Bool = false
    var notes: [String] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case buildOk, unitPassRate, uitestPassRate, acceptancePassRate
        case unitPassed, unitTotal, uitestPassed, uitestTotal
        case lintViolations, lintErrors, judgeCompleteness, judgeMvi, judgeValid
        case infraFailure, notes
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        buildOk = try c.decodeIfPresent(Bool.self, forKey: .buildOk) ?? false
        unitPassRate = try c.decodeIfPresent(Double.self, forKey: .unitPassRate)
        uitestPassRate = try c.decodeIfPresent(Double.self, forKey: .uitestPassRate)
        acceptancePassRate = try c.decodeIfPresent(Double.self, forKey: .acceptancePassRate)
        unitPassed = try c.decodeIfPresent(Int.self, forKey: .unitPassed) ?? 0
        unitTotal = try c.decodeIfPresent(Int.self, forKey: .unitTotal) ?? 0
        uitestPassed = try c.decodeIfPresent(Int.self, forKey: .uitestPassed) ?? 0
        uitestTotal = try c.decodeIfPresent(Int.self, forKey: .uitestTotal) ?? 0
        lintViolations = try c.decodeIfPresent(Int.self, forKey: .lintViolations)
        lintErrors = try c.decodeIfPresent(Int.self, forKey: .lintErrors)
        judgeCompleteness = try c.decodeIfPresent(Double.self, forKey: .judgeCompleteness)
        judgeMvi = try c.decodeIfPresent(Double.self, forKey: .judgeMvi)
        judgeValid = try c.decodeIfPresent(Bool.self, forKey: .judgeValid)
        infraFailure = try c.decodeIfPresent(Bool.self, forKey: .infraFailure) ?? false
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
    }
}

struct HandoffStageRecord: Codable {
    var stage: String
    var status: String?
    var contractValid: Bool = false
    var inputsResolved: Bool = false
    var drift: Bool = false
    var artifact: String?
    var issues: [String] = []

    init(stage: String, contractValid: Bool = false, issues: [String] = []) {
        self.stage = stage
        self.contractValid = contractValid
        self.issues = issues
    }

    enum CodingKeys: String, CodingKey {
        case stage, status, contractValid, inputsResolved, drift, artifact, issues
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        stage = try c.decode(String.self, forKey: .stage)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        contractValid = try c.decodeIfPresent(Bool.self, forKey: .contractValid) ?? false
        inputsResolved = try c.decodeIfPresent(Bool.self, forKey: .inputsResolved) ?? false
        drift = try c.decodeIfPresent(Bool.self, forKey: .drift) ?? false
        artifact = try c.decodeIfPresent(String.self, forKey: .artifact)
        issues = try c.decodeIfPresent([String].self, forKey: .issues) ?? []
    }
}

struct Handoff: Codable {
    var applicable: Bool = false
    var stagesCompleted: Int = 0
    var stagesTotal: Int = 0
    var reachedTerminal: Bool = false
    var contractValidRate: Double?
    var driftCount: Int = 0
    var advanceCorrect: Bool = true
    var resumeWorked: Bool = true
    var haltedStage: String?
    var haltStatus: String?
    var fidelityScore: Double?
    var perStage: [HandoffStageRecord] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case applicable, stagesCompleted, stagesTotal, reachedTerminal
        case contractValidRate, driftCount, advanceCorrect, resumeWorked
        case haltedStage, haltStatus, fidelityScore, perStage
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        applicable = try c.decodeIfPresent(Bool.self, forKey: .applicable) ?? false
        stagesCompleted = try c.decodeIfPresent(Int.self, forKey: .stagesCompleted) ?? 0
        stagesTotal = try c.decodeIfPresent(Int.self, forKey: .stagesTotal) ?? 0
        reachedTerminal = try c.decodeIfPresent(Bool.self, forKey: .reachedTerminal) ?? false
        contractValidRate = try c.decodeIfPresent(Double.self, forKey: .contractValidRate)
        driftCount = try c.decodeIfPresent(Int.self, forKey: .driftCount) ?? 0
        advanceCorrect = try c.decodeIfPresent(Bool.self, forKey: .advanceCorrect) ?? true
        resumeWorked = try c.decodeIfPresent(Bool.self, forKey: .resumeWorked) ?? true
        haltedStage = try c.decodeIfPresent(String.self, forKey: .haltedStage)
        haltStatus = try c.decodeIfPresent(String.self, forKey: .haltStatus)
        fidelityScore = try c.decodeIfPresent(Double.self, forKey: .fidelityScore)
        perStage = try c.decodeIfPresent([HandoffStageRecord].self, forKey: .perStage) ?? []
    }
}

struct Artifacts: Codable {
    var worktree: String?
    var transcripts: [String] = []
    var xcresult: String?
    var diff: String?
    var handoffSnapshots: [String] = []

    init(worktree: String? = nil) { self.worktree = worktree }

    enum CodingKeys: String, CodingKey {
        case worktree, transcripts, xcresult, diff, handoffSnapshots
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        worktree = try c.decodeIfPresent(String.self, forKey: .worktree)
        transcripts = try c.decodeIfPresent([String].self, forKey: .transcripts) ?? []
        xcresult = try c.decodeIfPresent(String.self, forKey: .xcresult)
        diff = try c.decodeIfPresent(String.self, forKey: .diff)
        handoffSnapshots = try c.decodeIfPresent([String].self, forKey: .handoffSnapshots) ?? []
    }
}

struct Cell: Codable {
    var schemaVersion: String = "axbench.cell.v1"
    var ticketId: String
    var arm: String
    var runIndex: Int
    var startedAt: String
    var endedAt: String?
    var status: String = "ok"
    var error: String?

    // Provenance for reproducibility / audit.
    var agentModel: String?
    var axkitFlowSha: String?
    var sandboxSeedSha: String?

    var quality: Quality = Quality()
    var efficiency: Efficiency = Efficiency()
    var handoff: Handoff = Handoff()
    var artifacts: Artifacts = Artifacts()

    // Contamination guard result (Arm B should never touch axkit-flow).
    var contaminationDetected: Bool?

    init(ticketId: String, arm: String, runIndex: Int, startedAt: String) {
        self.ticketId = ticketId
        self.arm = arm
        self.runIndex = runIndex
        self.startedAt = startedAt
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, ticketId, arm, runIndex, startedAt, endedAt, status, error
        case agentModel, axkitFlowSha, sandboxSeedSha
        case quality, efficiency, handoff, artifacts, contaminationDetected
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(String.self, forKey: .schemaVersion) ?? "axbench.cell.v1"
        ticketId = try c.decode(String.self, forKey: .ticketId)
        arm = try c.decode(String.self, forKey: .arm)
        runIndex = try c.decode(Int.self, forKey: .runIndex)
        startedAt = try c.decode(String.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(String.self, forKey: .endedAt)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "ok"
        error = try c.decodeIfPresent(String.self, forKey: .error)
        agentModel = try c.decodeIfPresent(String.self, forKey: .agentModel)
        axkitFlowSha = try c.decodeIfPresent(String.self, forKey: .axkitFlowSha)
        sandboxSeedSha = try c.decodeIfPresent(String.self, forKey: .sandboxSeedSha)
        quality = try c.decodeIfPresent(Quality.self, forKey: .quality) ?? Quality()
        efficiency = try c.decodeIfPresent(Efficiency.self, forKey: .efficiency) ?? Efficiency()
        handoff = try c.decodeIfPresent(Handoff.self, forKey: .handoff) ?? Handoff()
        artifacts = try c.decodeIfPresent(Artifacts.self, forKey: .artifacts) ?? Artifacts()
        contaminationDetected = try c.decodeIfPresent(Bool.self, forKey: .contaminationDetected)
    }
}
