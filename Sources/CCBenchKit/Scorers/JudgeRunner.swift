// Shared machinery for auditable LLM judges.
//
// Port of scorers/judge_runner.py. Each judge is: a pinned model + a published
// rubric (markdown with YAML frontmatter carrying good_floor/bad_ceiling/
// scale_max) + a strict JSON output contract. Judges are deterministic-as-
// possible (pinned model id, low effort) and self-tested on good/bad references
// before being trusted.
import Foundation
import Yams

struct Rubric {
    var goodFloor: Double
    var badCeiling: Double
    var scaleMax: Double
    var body: String
}

struct JudgeScore {
    var score: Double?
    var raw: [String: Any] = [:]
    var ok: Bool = false
    var error: String?
}

enum JudgeRunner {
    static func loadRubric(_ path: URL) throws -> Rubric {
        let text = try String(contentsOf: path, encoding: .utf8)
        guard let (front, body) = splitFrontmatter(text) else {
            throw CCError("rubric \(path.path) missing YAML frontmatter")
        }
        let meta = ((try? Yams.load(yaml: front)) as? [String: Any]) ?? [:]
        guard let goodFloor = numeric(meta["good_floor"]),
              let badCeiling = numeric(meta["bad_ceiling"]) else {
            throw CCError("rubric \(path.path) missing good_floor/bad_ceiling")
        }
        let scaleMax = numeric(meta["scale_max"]) ?? 3.0
        return Rubric(goodFloor: goodFloor, badCeiling: badCeiling, scaleMax: scaleMax,
                      body: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Split a `---\n…\n---\n…` frontmatter document (Python `_FRONTMATTER` regex).
    static func splitFrontmatter(_ text: String) -> (front: String, body: String)? {
        let opener = "---\n"
        guard text.hasPrefix(opener) else { return nil }
        let afterOpen = text.index(text.startIndex, offsetBy: opener.count)
        guard let closeRange = text.range(of: "\n---\n", range: afterOpen..<text.endIndex) else {
            return nil
        }
        let front = String(text[afterOpen..<closeRange.lowerBound])
        let body = String(text[closeRange.upperBound...])
        return (front, body)
    }

    static func numeric(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber: return n.doubleValue
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String: return Double(s)
        default: return nil
        }
    }

    /// Format a scale value like Python's `:g` (drops trailing zeros: 3.0 → "3").
    static func g(_ value: Double) -> String {
        String(format: "%g", value)
    }

    static func prompt(_ rubric: Rubric, ticketText: String, codeText: String, kind: String) -> String {
        """
        You are an auditable code judge scoring the "\(kind)" dimension.
        Apply the rubric EXACTLY. Be strict and cite concrete evidence from the code.

        ## Rubric (scale 0..\(g(rubric.scaleMax)))
        \(rubric.body)

        ## Feature ticket
        \(ticketText)

        ## Code under review (a diff / set of files)
        \(codeText)

        ## Output contract
        Respond with ONLY a single JSON object, no prose, no code fences:
        {"score": <number 0..\(g(rubric.scaleMax))>,
         "per_criterion": [{"name": "<criterion>", "score": <number>, "evidence": "<file/line or symbol>"}],
         "rationale": "<one sentence>"}
        """
    }

    /// Extract the first `{ … }` block and parse it (Python `_JSON_OBJ`).
    static func extractJSON(_ text: String) -> [String: Any]? {
        guard let first = text.firstIndex(of: "{"),
              let last = text.lastIndex(of: "}"), first <= last else { return nil }
        let slice = String(text[first...last])
        guard let data = slice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    static func judge(
        _ cfg: Config, rubric: Rubric, ticketText: String, codeText: String,
        kind: String, workdir: URL, transcriptPath: URL? = nil
    ) -> JudgeScore {
        let p = prompt(rubric, ticketText: ticketText, codeText: codeText, kind: kind)
        let res = ClaudeCLI.runClaude(
            cfg, prompt: p, workdir: workdir,
            model: cfg.models.judge,
            timeoutS: 600,
            transcriptPath: transcriptPath,
            effort: cfg.models.judgeEffort,
            settingSources: "user"
        )
        if res.isError || res.resultText.isEmpty {
            return JudgeScore(ok: false, error: "judge call failed/empty")
        }
        guard let data = extractJSON(res.resultText), data["score"] != nil else {
            return JudgeScore(ok: false, error: "judge returned no parseable score")
        }
        guard let score = numeric(data["score"]) else {
            return JudgeScore(ok: false, error: "non-numeric score")
        }
        return JudgeScore(score: score, raw: data, ok: true)
    }
}
