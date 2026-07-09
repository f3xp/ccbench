# verify-ios — iOS build+test as a ccbench verify command (WIP)

This is the reference **verify plugin** that shows how the old iOS/Xcode scoring path becomes
one implementation of ccbench's language-agnostic [verify contract](../../README.md#the-verify-contract).
It is not wired into the core library — a task opts in via `scoring.verify.command`.

Given a worktree with the hidden acceptance tests already overlaid by ccbench, it should:

1. Inject the acceptance test files into the Xcode test target (`inject_tests.rb`, or the
   filesystem-synchronized-group strategy).
2. Resolve dependencies (`pod install` or SPM package resolution) — failures → `infra_failure`.
3. `xcodebuild build-for-testing` then `test-without-building` scoped to the hidden suite.
4. Parse the `.xcresult` and print the verify JSON:
   `{"pass_rate", "passed", "total", "criteria": [...], "infra_failure"}`.

## Status

The Swift sources moved out of the core library live in `src/` (`IOSBuild.swift`,
`XCResult.swift`, `Lint.swift`) and still reference the old `Config.ios` shape. Turning them
into a standalone `ccbench-verify-ios` executable (its own `Package.swift`, reading repo /
scheme / targets / simulator from CLI flags or a small JSON config, and emitting the verify
contract) is the remaining task. Once built, an iOS task's manifest looks like:

```jsonc
{ "scoring": { "verify": {
    "command": ["ccbench-verify-ios", "--config", "verify-ios.json"] } } }
```

The **golden reproduction** check from the migration plan — run a migrated iOS task through
this tool and confirm the numbers match the pre-refactor `IOSBuild`/`XCResult` output for the
same worktree — requires a real iOS repo + Xcode and is the acceptance test for this plugin.
