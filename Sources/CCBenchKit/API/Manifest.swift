// Declarative manifests: the on-disk description of what to benchmark.
//
// A **variant** describes how to prime and drive one Claude Code run (the
// control is just a variant that mounts nothing). A **task** describes a coding
// job in a git repo and how to score the result. Both are plain JSON the macOS
// UI and open-source users author by hand; these typed structs are the in-memory
// model the engine works with.
import Foundation

// MARK: - Variant

/// How a variant primes the Claude Code session.
public enum VariantKind: String, Codable, Sendable {
    /// Mounts nothing; runs with `--setting-sources user`. The fair control.
    case vanilla
    /// Mounts a directory (a skill / plugin / `.claude` project) into the worktree
    /// and runs with `--setting-sources project` so Claude Code loads it.
    case skill
    /// Seeds the first prompt with a spec but sets up nothing on disk.
    case spec
}

public struct Variant: Codable, Sendable, Identifiable {
    public var id: String
    public var kind: VariantKind
    /// Exactly one variant in a run should set this; deltas are computed against it.
    public var control: Bool
    /// `.skill`: a local directory linked into the worktree (abs, `~`, or relative
    /// to the variants dir).
    public var mount: String?
    /// Name the mount appears as inside the worktree (default: mount's basename).
    public var mountAs: String?
    /// Override `--setting-sources` (default: `project` for `.skill`, else `user`).
    public var settingSources: String?
    /// Prepended verbatim to the task prompt (e.g. "Load and follow skill X.").
    public var promptPrefix: String?
    /// A spec file (abs/`~`/variants-relative) whose contents are prepended to the prompt.
    public var promptFile: String?
    // Per-variant overrides:
    public var model: String?
    public var effort: String?
    public var appendSystemPrompt: String?
    public var allowedTools: [String]?
    public var disallowedTools: [String]?

    public init(id: String, kind: VariantKind, control: Bool = false) {
        self.id = id
        self.kind = kind
        self.control = control
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, control, mount, mountAs, settingSources
        case promptPrefix, promptFile, model, effort, appendSystemPrompt
        case allowedTools, disallowedTools
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(VariantKind.self, forKey: .kind)
        control = try c.decodeIfPresent(Bool.self, forKey: .control) ?? false
        mount = try c.decodeIfPresent(String.self, forKey: .mount)
        mountAs = try c.decodeIfPresent(String.self, forKey: .mountAs)
        settingSources = try c.decodeIfPresent(String.self, forKey: .settingSources)
        promptPrefix = try c.decodeIfPresent(String.self, forKey: .promptPrefix)
        promptFile = try c.decodeIfPresent(String.self, forKey: .promptFile)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        appendSystemPrompt = try c.decodeIfPresent(String.self, forKey: .appendSystemPrompt)
        allowedTools = try c.decodeIfPresent([String].self, forKey: .allowedTools)
        disallowedTools = try c.decodeIfPresent([String].self, forKey: .disallowedTools)
    }

    /// The `--setting-sources` value this variant drives Claude Code with.
    public var effectiveSettingSources: String {
        settingSources ?? (kind == .skill ? "project" : "user")
    }

    /// The directory name this variant mounts into the worktree (if any).
    public var effectiveMountAs: String? {
        guard kind == .skill, let mount else { return nil }
        return mountAs ?? URL(fileURLWithPath: Manifests.expand(mount)).lastPathComponent
    }
}

// MARK: - Task

/// A command run inside the worktree (argv form, not a shell string).
public struct CommandSpec: Codable, Sendable {
    public var command: [String]
    public var timeoutS: Int?
    /// Working directory, worktree-relative (default: worktree root).
    public var cwd: String?

    public init(command: [String], timeoutS: Int? = nil, cwd: String? = nil) {
        self.command = command
        self.timeoutS = timeoutS
        self.cwd = cwd
    }
}

/// One LLM-judge dimension for a task, with its rubric and (optional) references
/// used to self-test the judge before its scores are trusted.
public struct JudgeSpec: Codable, Sendable {
    public var dimension: String
    /// Rubric markdown (YAML frontmatter: good_floor/bad_ceiling/scale_max),
    /// task-relative.
    public var rubric: String
    /// Task-relative dir of a correct reference solution (self-test upper bound).
    public var goodRef: String?
    /// Task-relative dir of a plausible-but-wrong solution (self-test lower bound).
    public var badRef: String?

    public init(dimension: String, rubric: String, goodRef: String? = nil, badRef: String? = nil) {
        self.dimension = dimension
        self.rubric = rubric
        self.goodRef = goodRef
        self.badRef = badRef
    }
}

public struct GoldenSpec: Codable, Sendable {
    /// Task-relative dir of expected files.
    public var expectedDir: String
    /// Optional subset of worktree-relative paths to compare (default: all files
    /// present under `expectedDir`).
    public var files: [String]?

    public init(expectedDir: String, files: [String]? = nil) {
        self.expectedDir = expectedDir
        self.files = files
    }
}

public struct Scoring: Codable, Sendable {
    /// Deterministic correctness gate: a command emitting the verify JSON contract.
    public var verify: CommandSpec?
    /// LLM judges with per-task rubric dimensions.
    public var judges: [JudgeSpec]?
    /// Golden-output comparison.
    public var golden: GoldenSpec?
    /// Record git-diff size metrics (default: true).
    public var diffMetrics: Bool?

    public init(verify: CommandSpec? = nil, judges: [JudgeSpec]? = nil,
                golden: GoldenSpec? = nil, diffMetrics: Bool? = nil) {
        self.verify = verify
        self.judges = judges
        self.golden = golden
        self.diffMetrics = diffMetrics
    }
}

public struct BenchTask: Codable, Sendable, Identifiable {
    public var id: String
    /// Path to the git repo the task runs against (abs or `~`).
    public var repo: String
    /// Ref the isolated worktree is created off (branch/tag/sha).
    public var baseRef: String
    /// Inline prompt handed to the agent. If nil, `promptFile` is read.
    public var prompt: String?
    /// Task-relative file whose contents are the prompt.
    public var promptFile: String?
    /// Task-relative git patch applied to establish the "to-implement" state.
    public var starterPatch: String?
    /// Repo-relative gitignored files copied from the target working tree into the
    /// worktree (build config the commit doesn't carry).
    public var seedFiles: [String]
    /// Setup command (deps install) — failures are classified as infra, not quality.
    public var setup: CommandSpec?
    /// Task-relative directory overlaid into the worktree *after* the agent runs,
    /// *before* verify — the hidden acceptance files the agent never sees.
    public var hiddenDir: String?
    public var scoring: Scoring

    /// The task's on-disk directory. Set by the loader; not decoded.
    public var dir: URL = URL(fileURLWithPath: ".")

    public init(id: String, repo: String, baseRef: String, scoring: Scoring = Scoring()) {
        self.id = id
        self.repo = repo
        self.baseRef = baseRef
        self.seedFiles = []
        self.scoring = scoring
    }

    enum CodingKeys: String, CodingKey {
        case id, repo, baseRef, prompt, promptFile, starterPatch
        case seedFiles, setup, hiddenDir, scoring
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        repo = try c.decode(String.self, forKey: .repo)
        baseRef = try c.decode(String.self, forKey: .baseRef)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        promptFile = try c.decodeIfPresent(String.self, forKey: .promptFile)
        starterPatch = try c.decodeIfPresent(String.self, forKey: .starterPatch)
        seedFiles = try c.decodeIfPresent([String].self, forKey: .seedFiles) ?? []
        setup = try c.decodeIfPresent(CommandSpec.self, forKey: .setup)
        hiddenDir = try c.decodeIfPresent(String.self, forKey: .hiddenDir)
        scoring = try c.decodeIfPresent(Scoring.self, forKey: .scoring) ?? Scoring()
    }

    /// The prompt handed to the agent (inline `prompt`, else `promptFile`'s contents).
    func resolvedPrompt() -> String {
        if let prompt { return prompt }
        if let pf = promptFile {
            let url = Manifests.resolve(pf, base: dir)
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        }
        return "Implement the task described for \(id)."
    }
}

// MARK: - Loading

public enum Manifests {
    /// Expand a leading `~` to the home directory.
    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Resolve a possibly-relative path against `base` (abs and `~` pass through).
    static func resolve(_ path: String, base: URL) -> URL {
        let expanded = expand(path)
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        return base.appendingPathComponent(expanded)
    }

    public static func loadVariants(from variantsDir: URL, ids: [String]) throws -> [Variant] {
        let fm = FileManager.default
        let wantsAll = ids.isEmpty || ids.contains("all") || ids.contains("*")
        var files: [URL] = []
        if wantsAll {
            guard fm.fileExists(atPath: variantsDir.path),
                  let entries = try? fm.contentsOfDirectory(at: variantsDir, includingPropertiesForKeys: nil)
            else { return [] }
            files = entries.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
        } else {
            for raw in ids {
                let vid = raw.trimmingCharacters(in: .whitespaces)
                if vid.isEmpty { continue }
                let p = variantsDir.appendingPathComponent("\(vid).json")
                if !fm.fileExists(atPath: p.path) { throw CCError("variant not found: \(p.path)") }
                files.append(p)
            }
        }
        return try files.map { url in
            let data = try Data(contentsOf: url)
            do { return try CCJSON.decoder.decode(Variant.self, from: data) }
            catch { throw CCError("invalid variant \(url.lastPathComponent): \(error)") }
        }
    }

    public static func loadTasks(from tasksDir: URL, ids: [String]) throws -> [BenchTask] {
        let fm = FileManager.default
        let wantsAll = ids.isEmpty || ids.contains("all") || ids.contains("*")
        var dirs: [URL] = []
        if wantsAll {
            guard fm.fileExists(atPath: tasksDir.path),
                  let entries = try? fm.contentsOfDirectory(at: tasksDir, includingPropertiesForKeys: nil)
            else { return [] }
            dirs = entries.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    && fm.fileExists(atPath: $0.appendingPathComponent("task.json").path)
            }.sorted { $0.path < $1.path }
        } else {
            for raw in ids {
                let tid = raw.trimmingCharacters(in: .whitespaces)
                if tid.isEmpty { continue }
                let p = tasksDir.appendingPathComponent(tid)
                if !fm.fileExists(atPath: p.appendingPathComponent("task.json").path) {
                    throw CCError("task not found: \(p.appendingPathComponent("task.json").path)")
                }
                dirs.append(p)
            }
        }
        return try dirs.map { dir in
            let manifest = dir.appendingPathComponent("task.json")
            let data = try Data(contentsOf: manifest)
            do {
                var task = try CCJSON.decoder.decode(BenchTask.self, from: data)
                task.dir = dir
                return task
            } catch { throw CCError("invalid task \(dir.lastPathComponent): \(error)") }
        }
    }

    // MARK: - Saving

    /// Write a variant manifest to `url` using the on-disk conventions
    /// (snake_case keys, sorted, pretty-printed). Parent directories are created.
    public static func save(_ variant: Variant, to url: URL) throws {
        try write(try CCJSON.encoder.encode(variant), to: url)
    }

    /// Write a task manifest to `url` (typically `<task>/task.json`). The task's
    /// `dir` is not part of the schema, so it is not written.
    public static func save(_ task: BenchTask, to url: URL) throws {
        try write(try CCJSON.encoder.encode(task), to: url)
    }

    private static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Validation

    /// Static, cheap manifest validation covering the invariants the engine assumes.
    /// Non-blocking: returns issues (with `isError` distinguishing hard failures from
    /// warnings) rather than throwing, so an editor can surface them all at once.
    public static func validate(task: BenchTask) -> [ManifestIssue] {
        var issues: [ManifestIssue] = []
        let fm = FileManager.default

        func requirePath(_ path: String?, field: String, isError: Bool = true) {
            guard let path, !path.isEmpty else { return }
            let url = resolve(path, base: task.dir)
            if !fm.fileExists(atPath: url.path) {
                issues.append(ManifestIssue(field: field,
                                            message: "referenced path does not exist: \(path)",
                                            isError: isError))
            }
        }

        if task.repo.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(ManifestIssue(field: "repo", message: "repo is required", isError: true))
        }
        if task.baseRef.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(ManifestIssue(field: "base_ref", message: "base_ref is required", isError: true))
        }
        // A prompt must come from somewhere.
        let hasInline = !(task.prompt?.isEmpty ?? true)
        if !hasInline && (task.promptFile?.isEmpty ?? true) {
            issues.append(ManifestIssue(field: "prompt",
                                        message: "task has neither an inline prompt nor a prompt_file",
                                        isError: true))
        }
        requirePath(task.promptFile, field: "prompt_file")
        requirePath(task.starterPatch, field: "starter_patch")
        requirePath(task.hiddenDir, field: "hidden_dir")

        // Scoring: a verify gate is expected (warn, not error, if absent).
        if task.scoring.verify == nil {
            issues.append(ManifestIssue(field: "scoring.verify",
                                        message: "no verify command; correctness cannot be gated",
                                        isError: false))
        }
        for (i, judge) in (task.scoring.judges ?? []).enumerated() {
            requirePath(judge.rubric, field: "scoring.judges[\(i)].rubric")
            requirePath(judge.goodRef, field: "scoring.judges[\(i)].good_ref")
            requirePath(judge.badRef, field: "scoring.judges[\(i)].bad_ref")
        }
        if let golden = task.scoring.golden {
            requirePath(golden.expectedDir, field: "scoring.golden.expected_dir")
        }
        return issues
    }

    /// Validate a variant against its sibling set: exactly one control across the
    /// set, and (for `.skill`) that the mount resolves on disk.
    public static func validate(variant: Variant, in variantsDir: URL) -> [ManifestIssue] {
        var issues: [ManifestIssue] = []

        if let set = try? loadVariants(from: variantsDir, ids: ["all"]) {
            let controls = set.filter { $0.control }.map(\.id)
            if controls.isEmpty {
                issues.append(ManifestIssue(field: "control",
                                            message: "no variant in the set is marked control",
                                            isError: true))
            } else if controls.count > 1 {
                issues.append(ManifestIssue(field: "control",
                                            message: "multiple controls: \(controls.joined(separator: ", "))",
                                            isError: true))
            }
        }

        if variant.kind == .skill {
            if let mount = variant.mount, !mount.isEmpty {
                let url = resolve(mount, base: variantsDir)
                if !FileManager.default.fileExists(atPath: url.path) {
                    issues.append(ManifestIssue(field: "mount",
                                                message: "mount path does not exist: \(mount)",
                                                isError: true))
                }
            } else {
                issues.append(ManifestIssue(field: "mount",
                                            message: ".skill variant has no mount",
                                            isError: true))
            }
        }
        return issues
    }
}

/// A single validation finding on a manifest. `isError` distinguishes a hard
/// failure (the engine would reject or misbehave) from a warning.
public struct ManifestIssue: Sendable, Equatable {
    public var field: String
    public var message: String
    public var isError: Bool

    public init(field: String, message: String, isError: Bool) {
        self.field = field
        self.message = message
        self.isError = isError
    }
}
