// Typed, code-constructed run configuration — the global (non-task) settings.
//
// Everything task- or repo-specific (which repo, base ref, prompt, how to verify)
// lives in the per-task manifest (`BenchTask`); everything workflow-specific lives
// in the per-variant manifest (`Variant`). `CCConfig` holds only the run-wide
// knobs: models, budgets, the Claude Code invocation policy, and the push guard.
import Foundation

public struct CCConfig: Sendable {
    public struct Models: Sendable {
        public var agent: String
        public var agentEffort: String?
        public var judge: String
        public var judgeEffort: String

        public init(agent: String = "opus", agentEffort: String? = "high",
                    judge: String = "claude-opus-4-8", judgeEffort: String = "low") {
            self.agent = agent
            self.agentEffort = agentEffort
            self.judge = judge
            self.judgeEffort = judgeEffort
        }
    }

    public struct Budgets: Sendable {
        /// Hard cap on total agent cost for one cell (0 = unlimited).
        public var maxCostUsdPerRun: Double
        /// Timeout for the agent session.
        public var sessionTimeoutS: Int
        /// Timeout for a task's setup (deps install) command.
        public var setupTimeoutS: Int
        /// Timeout for a task's verify command.
        public var verifyTimeoutS: Int
        /// Timeout for a single judge call.
        public var judgeTimeoutS: Int

        public init(maxCostUsdPerRun: Double = 40.0, sessionTimeoutS: Int = 3600,
                    setupTimeoutS: Int = 1800, verifyTimeoutS: Int = 3600,
                    judgeTimeoutS: Int = 600) {
            self.maxCostUsdPerRun = maxCostUsdPerRun
            self.sessionTimeoutS = sessionTimeoutS
            self.setupTimeoutS = setupTimeoutS
            self.verifyTimeoutS = verifyTimeoutS
            self.judgeTimeoutS = judgeTimeoutS
        }
    }

    public struct ClaudePolicy: Sendable {
        public var bin: String
        public var allowedTools: [String]?
        public var disallowedTools: [String]?
        public var permissionMode: String

        public init(bin: String = "claude", allowedTools: [String]? = nil,
                    disallowedTools: [String]? = nil,
                    permissionMode: String = "bypassPermissions") {
            self.bin = bin
            self.allowedTools = allowedTools
            self.disallowedTools = disallowedTools
            self.permissionMode = permissionMode
        }
    }

    public var models: Models
    public var runsPerCell: Int
    public var budgets: Budgets
    public var claude: ClaudePolicy
    /// Refuse to drive an agent in a worktree whose `git push` is not disabled.
    public var pushGuard: Bool

    public init(models: Models = Models(), runsPerCell: Int = 3,
                budgets: Budgets = Budgets(),
                claude: ClaudePolicy = ClaudePolicy(), pushGuard: Bool = true) {
        self.models = models
        self.runsPerCell = runsPerCell
        self.budgets = budgets
        self.claude = claude
        self.pushGuard = pushGuard
    }

    /// Sensible starting point: Opus agent, pinned judge, push guard on, a
    /// permissive tool policy (tighten via `claude.allowedTools` as needed).
    public static let `default` = CCConfig()
}

// Internal alias so existing `_ cfg: Config` signatures compile unchanged.
typealias Config = CCConfig
