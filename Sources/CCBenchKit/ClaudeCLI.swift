// Wrapper around the `claude` CLI in headless print mode.
//
// Port of harness/cli.py. Every agent action in the benchmark goes through
// `runClaude`, which invokes `claude -p --output-format json`, enforces a
// timeout, persists the raw JSON envelope (the transcript) to disk, and returns
// a parsed result.
import Foundation

/// Loose access helpers for the `[String: Any]` JSON envelope (Python dict).
enum JSONVal {
    static func string(_ any: Any?) -> String {
        switch any {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case .some(let v): return String(describing: v)
        case .none: return ""
        }
    }
    static func double(_ any: Any?) -> Double {
        switch any {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s) ?? 0.0
        default: return 0.0
        }
    }
    static func int(_ any: Any?) -> Int {
        switch any {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? 0
        default: return 0
        }
    }
    static func bool(_ any: Any?) -> Bool {
        switch any {
        case let n as NSNumber: return n.boolValue
        case let b as Bool: return b
        default: return false
        }
    }
}

struct ClaudeResult {
    var ok: Bool                       // process exited 0 and JSON parsed
    var timedOut: Bool
    var exitCode: Int32
    var wallClockS: Double
    var envelope: [String: Any]        // parsed --output-format json
    var rawStdout: String = ""
    var rawStderr: String = ""
    var transcriptPath: String?

    var resultText: String { JSONVal.string(envelope["result"]) }

    /// The CLI marks errors in the envelope even when it exits 0.
    var isError: Bool { JSONVal.bool(envelope["is_error"]) || !ok }
}

/// Lock-guarded collector for parsed stream-json objects, appended from the
/// streaming read loop's background queue.
final class ObjectsBox: @unchecked Sendable {
    private var objs: [[String: Any]] = []
    private let lock = NSLock()
    func append(_ o: [String: Any]) { lock.lock(); objs.append(o); lock.unlock() }
    var all: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return objs }
}

enum ClaudeCLI {
    /// Normalise --output-format json output to the single result dict.
    ///
    /// Depending on CLI version it may be a single result object or a list of
    /// message objects ending in one with type == "result".
    static func normalizeEnvelope(_ parsed: Any) -> [String: Any] {
        if let dict = parsed as? [String: Any] {
            return dict
        }
        if let list = parsed as? [Any] {
            for item in list.reversed() {
                if let d = item as? [String: Any], (d["type"] as? String) == "result" {
                    return d
                }
            }
            for item in list.reversed() {
                if let d = item as? [String: Any] { return d }
            }
        }
        return [:]
    }

    /// Parse one stream-json line into a JSON object (nil for blank/unparseable).
    static func parseStreamObject(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// Build a lightweight `AgentStreamEvent` from a parsed stream-json message.
    static func streamEvent(from obj: [String: Any], raw: String) -> AgentStreamEvent {
        let kind = (obj["type"] as? String) ?? "unknown"
        var text: String?
        switch kind {
        case "assistant", "user":
            if let msg = obj["message"] as? [String: Any],
               let content = msg["content"] as? [[String: Any]] {
                var pieces: [String] = []
                for block in content {
                    switch block["type"] as? String {
                    case "text": if let t = block["text"] as? String { pieces.append(t) }
                    case "tool_use": if let n = block["name"] as? String { pieces.append("[tool: \(n)]") }
                    case "tool_result": pieces.append("[tool_result]")
                    default: break
                    }
                }
                if !pieces.isEmpty { text = pieces.joined(separator: " ") }
            }
        case "result":
            text = obj["result"] as? String
        case "system":
            if let sub = obj["subtype"] as? String { text = "[system: \(sub)]" }
        default:
            break
        }
        let numTurns = (obj["num_turns"] as? NSNumber)?.intValue
        let cost = (obj["total_cost_usd"] as? NSNumber)?.doubleValue
        return AgentStreamEvent(kind: kind, text: text, numTurns: numTurns, costUsd: cost, raw: raw)
    }

    /// Convenience: parse a raw stream-json line straight to an `AgentStreamEvent`.
    static func parseStreamLine(_ line: String) -> AgentStreamEvent? {
        guard let obj = parseStreamObject(line) else { return nil }
        return streamEvent(from: obj, raw: line)
    }

    static func buildArgv(
        _ cfg: Config,
        prompt: String,
        workdir: URL,
        model: String,
        effort: String? = nil,
        appendSystemPrompt: String? = nil,
        settingSources: String = "project",
        allowedTools: [String]? = nil,
        disallowedTools: [String]? = nil,
        extraAddDirs: [String]? = nil,
        stream: Bool = false
    ) -> [String] {
        let c = cfg.claude
        // stream-json emits newline-delimited message objects; `-p` requires
        // --verbose alongside it. Plain json buffers a single result object.
        let formatArgs = stream
            ? ["--output-format", "stream-json", "--verbose"]
            : ["--output-format", "json"]
        var argv: [String] = [
            c.bin,
            "-p",
            prompt,
        ] + formatArgs + [
            "--model", model,
            "--permission-mode", c.permissionMode,
            "--setting-sources", settingSources,
            "--add-dir", workdir.path,
        ]
        if let effort { argv += ["--effort", effort] }
        if let appendSystemPrompt { argv += ["--append-system-prompt", appendSystemPrompt] }
        // Per-call overrides win over the run-wide policy.
        let allowed = allowedTools ?? c.allowedTools
        let disallowed = disallowedTools ?? c.disallowedTools
        if let allowed, !allowed.isEmpty { argv += ["--allowedTools"] + allowed }
        if let disallowed, !disallowed.isEmpty { argv += ["--disallowedTools"] + disallowed }
        for d in extraAddDirs ?? [] { argv += ["--add-dir", d] }
        return argv
    }

    static func runClaude(
        _ cfg: Config,
        prompt: String,
        workdir: URL,
        model: String,
        timeoutS: Int,
        transcriptPath: URL? = nil,
        effort: String? = nil,
        appendSystemPrompt: String? = nil,
        settingSources: String = "project",
        allowedTools: [String]? = nil,
        disallowedTools: [String]? = nil,
        extraAddDirs: [String]? = nil,
        onEvent: (@Sendable (AgentStreamEvent) -> Void)? = nil
    ) -> ClaudeResult {
        let streaming = onEvent != nil
        let argv = buildArgv(
            cfg, prompt: prompt, workdir: workdir, model: model, effort: effort,
            appendSystemPrompt: appendSystemPrompt, settingSources: settingSources,
            allowedTools: allowedTools, disallowedTools: disallowedTools,
            extraAddDirs: extraAddDirs, stream: streaming
        )
        let start = Date()
        var timedOut = false
        var stdout = ""
        var stderr = ""
        var code: Int32 = -1
        var envelope: [String: Any] = [:]

        if let onEvent {
            // Streaming path: parse each JSONL message live, forward it, and collect
            // the objects so the final `result` envelope drives telemetry as usual.
            let collected = ObjectsBox()
            let res = try? Shell.runStreaming(argv, cwd: workdir, timeout: Double(timeoutS)) { line in
                guard let obj = parseStreamObject(line) else { return }
                collected.append(obj)
                onEvent(streamEvent(from: obj, raw: line))
            }
            stdout = res?.stdout ?? ""
            stderr = res?.stderr ?? "failed to launch claude"
            code = res?.exitCode ?? -1
            timedOut = res?.timedOut ?? false
            envelope = normalizeEnvelope(collected.all)
        } else {
            if let res = try? Shell.run(argv, cwd: workdir, timeout: Double(timeoutS)) {
                stdout = res.stdout
                stderr = res.stderr
                code = res.exitCode
                timedOut = res.timedOut
            } else {
                stderr = "failed to launch claude"
            }
            if !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let data = stdout.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) {
                envelope = normalizeEnvelope(parsed)
            }
        }
        let wall = Date().timeIntervalSince(start)

        var res = ClaudeResult(
            ok: (code == 0 && !envelope.isEmpty && !timedOut),
            timedOut: timedOut,
            exitCode: code,
            wallClockS: wall,
            envelope: envelope,
            rawStdout: stdout,
            rawStderr: stderr
        )

        if let transcriptPath {
            try? FileManager.default.createDirectory(
                at: transcriptPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let payload: [String: Any] = [
                "argv": argv,
                "exit_code": Int(code),
                "timed_out": timedOut,
                "wall_clock_s": wall,
                "envelope": envelope,
                "raw_stdout": envelope.isEmpty ? stdout : NSNull(),
                "raw_stderr": stderr.isEmpty ? NSNull() : stderr,
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted]
            ) {
                try? data.write(to: transcriptPath)
            }
            res.transcriptPath = transcriptPath.path
        }

        return res
    }

    /// Cheap check that the CLI is installed and authenticated.
    static func preflightAuth(_ cfg: Config, workdir: URL) -> (Bool, String) {
        let res = runClaude(
            cfg,
            prompt: "Reply with exactly the word: pong",
            workdir: workdir,
            model: cfg.models.agent,
            timeoutS: 120,
            settingSources: "user"
        )
        if res.exitCode == 127 {
            return (false, "claude CLI not found on PATH")
        }
        if res.timedOut {
            return (false, "claude auth/preflight timed out")
        }
        if res.envelope.isEmpty {
            let tail = String(res.rawStderr.prefix(200))
            return (false, "claude returned no JSON (exit \(res.exitCode)): \(tail)")
        }
        if res.isError {
            return (false, "claude preflight error: \(String(res.resultText.prefix(200)))")
        }
        return (true, res.resultText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
