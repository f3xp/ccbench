// Load and access the central bench.yaml config.
//
// Port of harness/config.py. Where the Python read a dict with `.get(key,
// default)`, the Swift model decodes the same keys into typed sub-structs and
// applies the identical fallback defaults. The result is cached (replacing the
// Python `@functools.lru_cache`).
import Foundation
import Yams

struct Config: Decodable {
    struct Models: Decodable {
        var agent: String
        var agentEffort: String?
        var judge: String
        var judgeEffort: String

        enum CodingKeys: String, CodingKey {
            case agent
            case agentEffort = "agent_effort"
            case judge
            case judgeEffort = "judge_effort"
        }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            agent = try c.decode(String.self, forKey: .agent)
            agentEffort = try c.decodeIfPresent(String.self, forKey: .agentEffort)
            judge = try c.decode(String.self, forKey: .judge)
            judgeEffort = try c.decodeIfPresent(String.self, forKey: .judgeEffort) ?? "low"
        }
    }

    struct Budgets: Decodable {
        var maxCostUsdPerStage: Double
        var maxCostUsdPerRun: Double
        var maxStages: Int
        var stageTimeoutS: Int
        var baselineTimeoutS: Int
        var podInstallTimeoutS: Int
        var buildTimeoutS: Int

        enum CodingKeys: String, CodingKey {
            case maxCostUsdPerStage = "max_cost_usd_per_stage"
            case maxCostUsdPerRun = "max_cost_usd_per_run"
            case maxStages = "max_stages"
            case stageTimeoutS = "stage_timeout_s"
            case baselineTimeoutS = "baseline_timeout_s"
            case podInstallTimeoutS = "pod_install_timeout_s"
            case buildTimeoutS = "build_timeout_s"
        }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            maxCostUsdPerStage = try c.decodeIfPresent(Double.self, forKey: .maxCostUsdPerStage) ?? 8.0
            maxCostUsdPerRun = try c.decode(Double.self, forKey: .maxCostUsdPerRun)
            maxStages = try c.decode(Int.self, forKey: .maxStages)
            stageTimeoutS = try c.decode(Int.self, forKey: .stageTimeoutS)
            baselineTimeoutS = try c.decode(Int.self, forKey: .baselineTimeoutS)
            podInstallTimeoutS = try c.decodeIfPresent(Int.self, forKey: .podInstallTimeoutS) ?? 1800
            buildTimeoutS = try c.decodeIfPresent(Int.self, forKey: .buildTimeoutS) ?? 3600
        }
    }

    struct IOS: Decodable {
        var buildRootRel: String
        var workspaceRel: String
        var projectRel: String
        var appScheme: String
        var unitTarget: String
        var uitestTarget: String
        var swiftlintConfigRel: String?
        var podinstall: Bool
        var spmCacheRel: String
        var testInjection: String
        var unitTestFilter: String?
        var setupScriptRel: String?
        var destination: String
        var simulatorName: String
        var xcodeprojGemHome: String
        var rubyBin: String

        enum CodingKeys: String, CodingKey {
            case buildRootRel = "build_root_rel"
            case workspaceRel = "workspace_rel"
            case projectRel = "project_rel"
            case appScheme = "app_scheme"
            case unitTarget = "unit_target"
            case uitestTarget = "uitest_target"
            case swiftlintConfigRel = "swiftlint_config_rel"
            case podinstall
            case spmCacheRel = "spm_cache_rel"
            case testInjection = "test_injection"
            case unitTestFilter = "unit_test_filter"
            case setupScriptRel = "setup_script_rel"
            case destination
            case simulatorName = "simulator_name"
            case xcodeprojGemHome = "xcodeproj_gem_home"
            case rubyBin = "ruby_bin"
        }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            buildRootRel = try c.decode(String.self, forKey: .buildRootRel)
            workspaceRel = try c.decodeIfPresent(String.self, forKey: .workspaceRel) ?? ""
            projectRel = try c.decode(String.self, forKey: .projectRel)
            appScheme = try c.decode(String.self, forKey: .appScheme)
            unitTarget = try c.decode(String.self, forKey: .unitTarget)
            uitestTarget = try c.decode(String.self, forKey: .uitestTarget)
            swiftlintConfigRel = try c.decodeIfPresent(String.self, forKey: .swiftlintConfigRel)
            podinstall = try c.decodeIfPresent(Bool.self, forKey: .podinstall) ?? true
            spmCacheRel = try c.decodeIfPresent(String.self, forKey: .spmCacheRel) ?? ".scratch/spm-cache"
            testInjection = try c.decodeIfPresent(String.self, forKey: .testInjection) ?? "xcodeproj"
            unitTestFilter = try c.decodeIfPresent(String.self, forKey: .unitTestFilter)
            setupScriptRel = try c.decodeIfPresent(String.self, forKey: .setupScriptRel)
            destination = try c.decode(String.self, forKey: .destination)
            simulatorName = try c.decode(String.self, forKey: .simulatorName)
            xcodeprojGemHome = try c.decodeIfPresent(String.self, forKey: .xcodeprojGemHome)
                ?? "/opt/homebrew/opt/cocoapods/libexec"
            rubyBin = try c.decodeIfPresent(String.self, forKey: .rubyBin) ?? "ruby"
        }
    }

    struct Sources: Decodable {
        var targetRepo: String
        var baseRef: String
        var pushGuard: Bool
        var seedLocalFiles: [String]
        var axkitFlowRepo: String
        var axkitFlowBranch: String?

        enum CodingKeys: String, CodingKey {
            case targetRepo = "target_repo"
            case baseRef = "base_ref"
            case pushGuard = "push_guard"
            case seedLocalFiles = "seed_local_files"
            case axkitFlowRepo = "axkit_flow_repo"
            case axkitFlowBranch = "axkit_flow_branch"
        }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            targetRepo = try c.decode(String.self, forKey: .targetRepo)
            baseRef = try c.decode(String.self, forKey: .baseRef)
            pushGuard = try c.decodeIfPresent(Bool.self, forKey: .pushGuard) ?? true
            seedLocalFiles = try c.decodeIfPresent([String].self, forKey: .seedLocalFiles) ?? []
            axkitFlowRepo = try c.decode(String.self, forKey: .axkitFlowRepo)
            axkitFlowBranch = try c.decodeIfPresent(String.self, forKey: .axkitFlowBranch)
        }
    }

    struct ClaudePolicy: Decodable {
        var bin: String
        var allowedTools: [String]?
        var disallowedTools: [String]?
        var permissionMode: String

        enum CodingKeys: String, CodingKey {
            case bin
            case allowedTools = "allowed_tools"
            case disallowedTools = "disallowed_tools"
            case permissionMode = "permission_mode"
        }
    }

    struct HandoffDef: Decodable {
        var stages: [String]
        var terminalStage: String
        var artifactRoot: String?

        enum CodingKeys: String, CodingKey {
            case stages
            case terminalStage = "terminal_stage"
            case artifactRoot = "artifact_root"
        }
    }

    var models: Models
    var runsPerCell: Int
    var arms: [String]
    var budgets: Budgets
    var ios: IOS
    var sources: Sources
    var claude: ClaudePolicy
    var handoff: HandoffDef

    enum CodingKeys: String, CodingKey {
        case models
        case runsPerCell = "runs_per_cell"
        case arms
        case budgets
        case ios
        case sources
        case claude
        case handoff
    }

    // Cached load of the default config path (replaces functools.lru_cache).
    private static var cached: Config?

    static func load(path: URL? = nil) throws -> Config {
        if path == nil, let cached { return cached }
        let p = path ?? RepoRoot.configPath
        let text = try String(contentsOf: p, encoding: .utf8)
        let cfg = try YAMLDecoder().decode(Config.self, from: text)
        if path == nil { cached = cfg }
        return cfg
    }
}
