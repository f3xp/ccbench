#!/usr/bin/env bash
# Create the throwaway git repo the `example-greeter` task runs against.
# Run from the ccbench repo root:  bash examples/bootstrap-example.sh
set -euo pipefail

REPO="${1:-.scratch/example-repo}"
mkdir -p "$REPO"
cd "$REPO"

if [ ! -d .git ]; then
  git init -q
  git config user.email ccbench@local
  git config user.name ccbench
fi

cat > greet.py <<'PY'
def greet(name):
    # TODO: return a greeting like "Hello, <name>!"
    return ""
PY

git add -A
git commit -q -m "starter: greet stub" --allow-empty
git branch -M main
echo "Example repo ready at: $REPO (branch main)"
echo "Now run:  swift run ccbench run --tasks example-greeter --variants vanilla --runs 1"
