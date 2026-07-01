// Build + test gate for ZohoDeskiOS (CocoaPods workspace).
//
// Port of scorers/ios_build.py. Per cell, on the agent's worktree:
//   1. injectTests()   — add the ticket's HIDDEN acceptance files into the
//                        ZohoDeskUnitTests / ZohoDeskUITests targets (classic
//                        project → use the xcodeproj ruby gem).
//   2. podInstall()    — `pod install` in the build root.
//   3. build()         — `xcodebuild build-for-testing -workspace … -scheme ZohoDesk`.
//   4. runTests()      — `test-without-building -only-testing:<target>`, parsed.
//
// pod install / package / simulator failures are classified as infra so they
// don't masquerade as quality regressions.
import Foundation

struct StepResult {
    var ok: Bool = false
    var infraFailure: Bool = false
    var logPath: String?
    var message: String = ""
}

struct TestResult {
    var ran: Bool = false
    var infraFailure: Bool = false
    var unit: TestCounts = TestCounts()
    var uitest: TestCounts = TestCounts()
    var xcresultPath: String?
    var message: String = ""

    var acceptancePassRate: Double? {
        let total = (unit.total - unit.skipped) + (uitest.total - uitest.skipped)
        if total <= 0 { return nil }
        return Double(unit.passed + uitest.passed) / Double(total)
    }
}

enum IOSBuild {
    static let overlayDirname = "_AxbenchAcceptance"

    static let infraMarkers = [
        "Unable to find a destination",
        "Unable to boot",
        "Failed to load the test bundle",
        "Simulator device failed",
        "Testing failed: Communication with the test runner was lost",
        "xcodebuild: error: Unable to find a device",
        // Package / pod / artifact resolution failures are environment, not agent code.
        "Could not resolve package dependencies",
        "failed downloading",
        "badResponseStatusCode",
        "Couldn't get target",
        "error: No such module",  // often a pod-not-installed symptom
    ]

    static let podInfraMarkers = [
        "Authentication failed",
        "could not read Username",
        "Couldn't determine repo",
        "Unable to find a specification",
        "CDN: trunk",
        "Couldn't download",
        "Permission denied",
        "fatal: could not read",
        "spec repo",
    ]

    // SPM (Swift Package Manager) resolution failures — auth/network to the private
    // package repos are environment problems, not agent quality regressions.
    static let spmInfraMarkers = [
        "Authentication failed",
        "could not read Username",
        "Authentication required",
        "fatal: could not read",
        "failed to resolve dependencies",
        "Failed to clone repository",
        "terminated(128)",
        "The server certificate",
        "Couldn't get the list of tags",
        "dependencies could not be resolved",
        "No such module",
    ]

    static func detect(_ log: String, _ markers: [String]) -> Bool {
        markers.contains { log.contains($0) }
    }

    static func buildRoot(_ cfg: Config, _ worktree: URL) -> URL {
        worktree.appendingPathComponent(cfg.ios.buildRootRel)
    }

    // MARK: 1. Inject hidden acceptance tests

    static func injectTests(_ cfg: Config, worktree: URL, ticketDir: URL, runDir: URL) -> StepResult {
        let fm = FileManager.default
        let ios = cfg.ios
        let project = worktree.appendingPathComponent(ios.projectRel)
        let log = runDir.appendingPathComponent("logs/inject.log")
        try? fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)

        let plan = [("UnitTests", ios.unitTarget), ("UITests", ios.uitestTarget)]
        let strategy = ios.testInjection
        var fullEnv = ProcessInfo.processInfo.environment
        fullEnv["GEM_HOME"] = ios.xcodeprojGemHome
        let ruby = ios.rubyBin

        var logs: [String] = []
        var injectedAny = false
        for (sub, target) in plan {
            let src = ticketDir.appendingPathComponent("acceptance").appendingPathComponent(sub)
            if !fm.fileExists(atPath: src.path) { continue }
            // Copy the hidden files into a dedicated folder inside the test target's
            // directory. For synchronized-group projects that is enough — the files
            // are picked up by filesystem membership automatically.
            let dest = worktree.appendingPathComponent(ios.buildRootRel)
                .appendingPathComponent(target).appendingPathComponent(overlayDirname)
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.copyItem(at: src, to: dest)
            } catch {
                logs.append("$ inject \(target)\ncopy failed: \(error)")
                try? logs.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
                return StepResult(ok: false, logPath: log.path,
                                  message: "test injection failed for \(target)")
            }
            let files = swiftFiles(under: dest).sorted()
            if files.isEmpty { continue }

            if strategy == "filesystem" {
                // Synchronized root group: on-disk presence == target membership.
                logs.append("$ filesystem-inject \(target) → \(dest.path) (\(files.count) file(s))")
                injectedAny = true
                continue
            }

            // Classic project: register references via the xcodeproj ruby gem.
            let group = "\(target)/\(overlayDirname)"
            let argv = [ruby, RepoRoot.injectRB.path, project.path, target, group] + files
            let proc = (try? Shell.run(argv, env: fullEnv))
                ?? ProcessResult(exitCode: -1, stdout: "", stderr: "launch failed", timedOut: false)
            logs.append("$ inject \(target)\n\(proc.stdout)\n\(proc.stderr)")
            if proc.exitCode != 0 {
                try? logs.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
                return StepResult(ok: false, logPath: log.path,
                                  message: "test injection failed for \(target)")
            }
            injectedAny = true
        }

        let logText = logs.isEmpty ? "no acceptance files to inject" : logs.joined(separator: "\n")
        try? logText.write(to: log, atomically: true, encoding: .utf8)
        return StepResult(ok: true, logPath: log.path,
                          message: injectedAny ? "injected" : "nothing to inject")
    }

    /// Recursively collect `*.swift` paths (Python `Path.rglob("*.swift")`).
    static func swiftFiles(under dir: URL) -> [String] {
        var out: [String] = []
        guard let en = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil
        ) else { return out }
        for case let url as URL in en where url.pathExtension == "swift" {
            out.append(url.path)
        }
        return out
    }

    // MARK: 2. pod install

    static func podInstall(_ cfg: Config, worktree: URL, runDir: URL) -> StepResult {
        if !cfg.ios.podinstall {
            return StepResult(ok: true, message: "podinstall disabled")
        }
        if !Shell.which("pod") {
            return StepResult(ok: false, infraFailure: true, message: "CocoaPods not installed")
        }

        let root = buildRoot(cfg, worktree)
        let log = runDir.appendingPathComponent("logs/pod-install.log")
        try? FileManager.default.createDirectory(
            at: log.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let timeout = Double(cfg.budgets.podInstallTimeoutS)

        guard let proc = try? Shell.run(
            ["pod", "install", "--repo-update"], cwd: root, timeout: timeout
        ) else {
            return StepResult(ok: false, infraFailure: true, message: "pod install launch failed")
        }
        let out = proc.stdout + "\n" + proc.stderr
        try? out.write(to: log, atomically: true, encoding: .utf8)

        if proc.timedOut {
            return StepResult(ok: false, infraFailure: true, logPath: log.path,
                              message: "pod install timed out")
        }
        if proc.exitCode != 0 {
            // Mirrors Python `_detect(...) or True` — always infra on pod failure.
            return StepResult(ok: false, infraFailure: detect(out, podInfraMarkers) || true,
                              logPath: log.path,
                              message: "pod install failed (exit \(proc.exitCode))")
        }
        return StepResult(ok: true, logPath: log.path, message: "pods installed")
    }

    /// Shared cloned-packages dir (outside worktrees) so each cell reuses clones.
    static func spmCache(_ cfg: Config) -> URL {
        let cache = RepoRoot.url.appendingPathComponent(cfg.ios.spmCacheRel).standardizedFileURL
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return cache
    }

    /// Resolve SPM package dependencies into the shared cache before building.
    /// Auth/network failures against the private package repos are classified as
    /// infra so they are not scored as agent quality regressions.
    static func spmResolve(_ cfg: Config, worktree: URL, runDir: URL) -> StepResult {
        let ios = cfg.ios
        let root = buildRoot(cfg, worktree)
        let log = runDir.appendingPathComponent("logs/spm-resolve.log")
        let timeout = cfg.budgets.podInstallTimeoutS
        let args = [
            "-resolvePackageDependencies",
            "-project", worktree.appendingPathComponent(ios.projectRel).path,
            "-scheme", ios.appScheme,
            "-clonedSourcePackagesDirPath", spmCache(cfg).path,
        ]
        let (code, out, timedOut) = xcodebuild(args, cwd: root, logPath: log, timeoutS: timeout)
        if timedOut {
            return StepResult(ok: false, infraFailure: true, logPath: log.path,
                              message: "SPM resolution timed out")
        }
        if code != 0 {
            return StepResult(ok: false, infraFailure: detect(out, spmInfraMarkers) || true,
                              logPath: log.path, message: "SPM resolution failed (exit \(code))")
        }
        return StepResult(ok: true, logPath: log.path, message: "packages resolved")
    }

    /// Prepare build dependencies: CocoaPods when enabled, else SPM resolution.
    static func resolveDependencies(_ cfg: Config, worktree: URL, runDir: URL) -> StepResult {
        cfg.ios.podinstall
            ? podInstall(cfg, worktree: worktree, runDir: runDir)
            : spmResolve(cfg, worktree: worktree, runDir: runDir)
    }

    // MARK: 3 + 4. build + test (workspace)

    static func xcodebuild(_ args: [String], cwd: URL, logPath: URL, timeoutS: Int)
        -> (code: Int32, out: String, timedOut: Bool) {
        try? FileManager.default.createDirectory(
            at: logPath.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let proc = try? Shell.run(["xcodebuild"] + args, cwd: cwd, timeout: Double(timeoutS)) else {
            try? "xcodebuild launch failed".write(to: logPath, atomically: true, encoding: .utf8)
            return (-1, "", true)
        }
        let out = proc.stdout + "\n" + proc.stderr
        try? out.write(to: logPath, atomically: true, encoding: .utf8)
        return (proc.exitCode, out, proc.timedOut)
    }

    static func wsArgs(_ cfg: Config, worktree: URL, derived: URL) -> [String] {
        let ios = cfg.ios
        // -workspace for CocoaPods targets; -project for plain SPM projects.
        let container: [String]
        if !ios.workspaceRel.trimmingCharacters(in: .whitespaces).isEmpty {
            container = ["-workspace", worktree.appendingPathComponent(ios.workspaceRel).path]
        } else {
            container = ["-project", worktree.appendingPathComponent(ios.projectRel).path]
        }
        var args = container + [
            "-scheme", ios.appScheme,
            "-destination", ios.destination,
            "-derivedDataPath", derived.path,
            "CODE_SIGNING_ALLOWED=NO",
        ]
        // Reuse the shared package clone cache for SPM targets.
        if !ios.podinstall {
            args += ["-clonedSourcePackagesDirPath", spmCache(cfg).path]
        }
        return args
    }

    static func build(_ cfg: Config, worktree: URL, runDir: URL) -> StepResult {
        let root = buildRoot(cfg, worktree)
        let derived = runDir.appendingPathComponent("DerivedData")
        let log = runDir.appendingPathComponent("logs/build.log")
        let timeout = cfg.budgets.buildTimeoutS
        let args = ["build-for-testing"] + wsArgs(cfg, worktree: worktree, derived: derived)
        let (code, out, timedOut) = xcodebuild(args, cwd: root, logPath: log, timeoutS: timeout)
        if timedOut {
            return StepResult(ok: false, infraFailure: true, logPath: log.path, message: "build timed out")
        }
        if code != 0 {
            return StepResult(ok: false, infraFailure: detect(out, infraMarkers),
                              logPath: log.path, message: "build failed (exit \(code))")
        }
        return StepResult(ok: true, logPath: log.path, message: "build ok")
    }

    static func runTests(_ cfg: Config, worktree: URL, runDir: URL, withUitests: Bool) -> TestResult {
        let ios = cfg.ios
        let root = buildRoot(cfg, worktree)
        let derived = runDir.appendingPathComponent("DerivedData")
        var res = TestResult()
        let timeout = cfg.budgets.buildTimeoutS

        func testTarget(_ target: String, tag: String, only: String? = nil) -> TestCounts? {
            let fm = FileManager.default
            let xcresult = runDir.appendingPathComponent("results/\(tag).xcresult")
            if fm.fileExists(atPath: xcresult.path) { try? fm.removeItem(at: xcresult) }
            try? fm.createDirectory(at: xcresult.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            let log = runDir.appendingPathComponent("logs/test-\(tag).log")
            let args = ["test-without-building"]
                + wsArgs(cfg, worktree: worktree, derived: derived)
                + ["-only-testing:\(only ?? target)", "-resultBundlePath", xcresult.path]
            let (_, out, timedOut) = xcodebuild(args, cwd: root, logPath: log, timeoutS: timeout)
            if timedOut || detect(out, infraMarkers) { res.infraFailure = true }
            res.xcresultPath = xcresult.path
            return fm.fileExists(atPath: xcresult.path) ? XCResult.parseSummary(xcresult) : nil
        }

        // Optionally scope the unit run to a specific suite (cleaner acceptance signal).
        let unitOnly = ios.unitTestFilter.map { "\(ios.unitTarget)/\($0)" }
        if let unit = testTarget(ios.unitTarget, tag: "unit", only: unitOnly) {
            res.unit = unit
            res.ran = true
        }
        if withUitests {
            if let ui = testTarget(ios.uitestTarget, tag: "uitest") {
                res.uitest = ui
                res.ran = true
            }
        }
        return res
    }
}
