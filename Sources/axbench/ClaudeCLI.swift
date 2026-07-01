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

    static func buildArgv(
        _ cfg: Config,
        prompt: String,
        workdir: URL,
        model: String,
        effort: String? = nil,
        appendSystemPrompt: String? = nil,
        settingSources: String = "project",
        extraAddDirs: [String]? = nil
    ) -> [String] {
        let c = cfg.claude
        var argv: [String] = [
            c.bin,
            "-p",
            prompt,
            "--output-format", "json",
            "--model", model,
            "--permission-mode", c.permissionMode,
            "--setting-sources", settingSources,
            "--add-dir", workdir.path,
        ]
        if let effort { argv += ["--effort", effort] }
        if let appendSystemPrompt { argv += ["--append-system-prompt", appendSystemPrompt] }
        if let allowed = c.allowedTools, !allowed.isEmpty { argv += ["--allowedTools"] + allowed }
        if let disallowed = c.disallowedTools, !disallowed.isEmpty {
            argv += ["--disallowedTools"] + disallowed
        }
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
        extraAddDirs: [String]? = nil
    ) -> ClaudeResult {
        let argv = buildArgv(
            cfg, prompt: prompt, workdir: workdir, model: model, effort: effort,
            appendSystemPrompt: appendSystemPrompt, settingSources: settingSources,
            extraAddDirs: extraAddDirs
        )
        let start = Date()
        var timedOut = false
        var stdout = ""
        var stderr = ""
        var code: Int32 = -1
        if let res = try? Shell.run(argv, cwd: workdir, timeout: Double(timeoutS)) {
            stdout = res.stdout
            stderr = res.stderr
            code = res.exitCode
            timedOut = res.timedOut
        } else {
            stderr = "failed to launch claude"
        }
        let wall = Date().timeIntervalSince(start)

        var envelope: [String: Any] = [:]
        if !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let data = stdout.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) {
            envelope = normalizeEnvelope(parsed)
        }

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
