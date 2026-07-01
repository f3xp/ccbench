// Subprocess helper — the Swift analogue of Python's `subprocess.run(...)`.
//
// Every external tool the harness drives (`git`, `claude`, `xcodebuild`, `pod`,
// `ruby`, `xcrun`, `swiftlint`) is invoked through `Shell.run`. It captures
// stdout/stderr as UTF-8, honours a working directory + environment, and
// implements a watchdog timeout (Foundation.Process has no built-in one).
import Foundation

struct ProcessResult {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
}

enum ShellError: Error, CustomStringConvertible {
    case launchFailed(String)
    case nonZeroExit(argv: [String], code: Int32, stderr: String)

    var description: String {
        switch self {
        case .launchFailed(let m): return "failed to launch: \(m)"
        case .nonZeroExit(let argv, let code, let stderr):
            return "command \(argv.first ?? "?") exited \(code): \(stderr)"
        }
    }
}

enum Shell {
    /// Run a command to completion. Mirrors `subprocess.run(capture_output=True, text=True)`.
    ///
    /// - Parameters:
    ///   - check: when true, a non-zero exit throws `ShellError.nonZeroExit` (Python `check=True`).
    ///   - timeout: seconds; on expiry the process is terminated and `timedOut` is set.
    @discardableResult
    static func run(
        _ argv: [String],
        cwd: URL? = nil,
        env: [String: String]? = nil,
        check: Bool = false,
        timeout: Double? = nil
    ) throws -> ProcessResult {
        guard let first = argv.first else {
            throw ShellError.launchFailed("empty argv")
        }

        let proc = Process()
        // Resolve via /usr/bin/env so PATH lookup matches the Python behaviour.
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = argv
        if let cwd { proc.currentDirectoryURL = cwd }
        if let env { proc.environment = env }
        _ = first  // argv[0] is passed through env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Drain pipes on background queues to avoid deadlock on large output.
        var outData = Data()
        var errData = Data()
        let outQ = DispatchQueue(label: "shell.out")
        let errQ = DispatchQueue(label: "shell.err")
        let group = DispatchGroup()

        do {
            try proc.run()
        } catch {
            throw ShellError.launchFailed(String(describing: error))
        }

        group.enter()
        outQ.async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        errQ.async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        var timedOut = false
        if let timeout {
            let deadline = DispatchTime.now() + timeout
            let watchdog = DispatchQueue(label: "shell.watchdog")
            let sem = DispatchSemaphore(value: 0)
            watchdog.async {
                proc.waitUntilExit()
                sem.signal()
            }
            if sem.wait(timeout: deadline) == .timedOut {
                timedOut = true
                proc.terminate()
                proc.waitUntilExit()
            }
        } else {
            proc.waitUntilExit()
        }

        group.wait()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        let code = proc.terminationStatus

        if check && !timedOut && code != 0 {
            throw ShellError.nonZeroExit(argv: argv, code: code, stderr: stderr)
        }
        return ProcessResult(exitCode: code, stdout: stdout, stderr: stderr, timedOut: timedOut)
    }

    /// True if `name` resolves on PATH (Python `shutil.which`).
    static func which(_ name: String) -> Bool {
        guard let res = try? run(["which", name]) else { return false }
        return res.exitCode == 0 && !res.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
