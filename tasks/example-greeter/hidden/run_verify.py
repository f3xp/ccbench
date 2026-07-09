#!/usr/bin/env python3
# Hidden verifier for the example-greeter task. Overlaid into the finished
# worktree by ccbench (the agent never sees it), then run as the verify command.
# Emits the ccbench verify JSON contract on stdout.
import json, sys

def result(ok):
    return {
        "pass_rate": 1.0 if ok else 0.0,
        "passed": 1 if ok else 0,
        "total": 1,
        "criteria": [{"id": "greet-world", "passed": bool(ok)}],
        "infra_failure": False,
    }

ok = False
try:
    import importlib.util
    spec = importlib.util.spec_from_file_location("greet", "greet.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    ok = mod.greet("World") == "Hello, World!"
except Exception:
    ok = False

print(json.dumps(result(ok)))
