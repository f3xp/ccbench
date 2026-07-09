// Parse xcresult bundles for pass/fail counts.
//
// Port of scorers/xcresult.py. Uses the Xcode 16+ `xcresulttool get test-results
// summary` JSON API, with a fallback to the legacy object API for older
// toolchains.
import Foundation

struct TestCounts {
    var total: Int = 0
    var passed: Int = 0
    var failed: Int = 0
    var skipped: Int = 0
    var parsed: Bool = false

    var passRate: Double {
        let denom = total - skipped
        return denom > 0 ? Double(passed) / Double(denom) : 0.0
    }
}

enum XCResult {
    private static func run(_ args: [String]) -> ProcessResult {
        (try? Shell.run(args)) ?? ProcessResult(exitCode: -1, stdout: "", stderr: "", timedOut: false)
    }

    static func parseSummary(_ xcresult: URL) -> TestCounts {
        // New API (Xcode 16+).
        let proc = run([
            "xcrun", "xcresulttool", "get", "test-results", "summary",
            "--path", xcresult.path, "--format", "json",
        ])
        if proc.exitCode == 0, !proc.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let data = proc.stdout.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var counts = TestCounts()
            counts.parsed = true
            counts.passed = JSONVal.int(obj["passedTests"])
            counts.failed = JSONVal.int(obj["failedTests"])
            counts.skipped = JSONVal.int(obj["skippedTests"])
            if obj["totalTestCount"] != nil {
                counts.total = JSONVal.int(obj["totalTestCount"])
            } else {
                counts.total = counts.passed + counts.failed + counts.skipped
            }
            return counts
        }

        // Legacy fallback.
        let legacy = run([
            "xcrun", "xcresulttool", "get", "--legacy",
            "--path", xcresult.path, "--format", "json",
        ])
        if legacy.exitCode == 0, !legacy.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let data = legacy.stdout.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let metrics = (obj["metrics"] as? [String: Any]) ?? [:]
            func metricValue(_ key: String) -> Int {
                JSONVal.int((metrics[key] as? [String: Any])?["_value"])
            }
            let total = metricValue("testsCount")
            let failed = metricValue("testsFailedCount")
            let skipped = metricValue("testsSkippedCount")
            var counts = TestCounts()
            counts.total = total
            counts.failed = failed
            counts.skipped = skipped
            counts.passed = max(total - failed - skipped, 0)
            counts.parsed = true
            return counts
        }

        return TestCounts()
    }
}
