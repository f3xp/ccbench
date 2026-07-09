# Manifest reference

ccbench is driven entirely by declarative JSON: **variants** (how to prime Claude Code) and
**tasks** (a coding job + how to score it). Unknown keys are ignored, so `_comment` fields
are fine.

## Variant — `variants/<id>.json`

| Field | Type | Default | Notes |
|---|---|---|---|
| `id` | string | — | Unique; also the JSON filename. |
| `kind` | `vanilla` \| `skill` \| `spec` | — | See below. |
| `control` | bool | `false` | Exactly one variant should be `true`; deltas are vs it. |
| `mount` | string | — | `.skill`: a dir (abs / `~` / variants-relative) symlinked into the worktree. |
| `mountAs` | string | mount basename | Name the mount appears as in the worktree (e.g. `.claude`). |
| `settingSources` | string | per-kind | Override `--setting-sources`. |
| `promptPrefix` | string | — | Prepended to the task prompt. |
| `promptFile` | string | — | File (task-relative) whose contents are prepended. |
| `model` | string | config | Per-variant model override. |
| `effort` | string | config | Per-variant reasoning effort. |
| `appendSystemPrompt` | string | — | `--append-system-prompt`. |
| `allowedTools` / `disallowedTools` | [string] | config | Per-variant tool policy. |

**kinds**
- `vanilla` — mounts nothing, `--setting-sources user`. The control.
- `skill` — mounts `mount` into the worktree, `--setting-sources project` so Claude Code
  loads the skill / plugin / `.claude` project by path.
- `spec` — mounts nothing; primes the prompt via `promptPrefix` / `promptFile` only.

## Task — `tasks/<id>/task.json`

| Field | Type | Notes |
|---|---|---|
| `id` | string | Unique; matches the directory name. |
| `repo` | string | Git repo path (abs / `~` / CWD-relative). |
| `baseRef` | string | Branch/tag/sha the worktree is cut from. |
| `prompt` | string | Inline prompt handed to the agent. |
| `promptFile` | string | Task-relative file used if `prompt` is absent. |
| `starterPatch` | string | Task-relative git patch establishing the "to-implement" state. |
| `seedFiles` | [string] | Repo-relative gitignored files copied from the working tree. |
| `setup` | CommandSpec | Deps install; failures classified as infra. |
| `hiddenDir` | string | Task-relative dir overlaid post-agent, pre-verify. |
| `scoring` | Scoring | See below. |

**CommandSpec**: `{ "command": ["argv", …], "timeoutS": 1800, "cwd": "worktree-relative" }`

**Scoring**
- `verify`: CommandSpec emitting the [verify JSON contract](../README.md#the-verify-contract).
- `judges`: `[{ "dimension", "rubric", "goodRef"?, "badRef"? }]` — rubric is markdown with
  YAML frontmatter (`good_floor`, `bad_ceiling`, `scale_max`). If `goodRef`/`badRef` are
  given, the judge is self-tested and excluded if it can't separate them.
- `golden`: `{ "expectedDir", "files"? }` — byte-compare produced files to a reference.
- `diffMetrics`: bool (default `true`) — record git-diff size (over-build signal).

## Metrics in the report

Higher-is-better: `verify_pass_rate`, `golden_match_rate`, every `judge_<dim>`.
Lower-is-better: `total_cost_usd`, `wall_clock_s`, `output_tokens`, `num_turns`,
`lines_added`, `lines_removed`, `files_touched`. Deltas are median(variant) − median(control).
