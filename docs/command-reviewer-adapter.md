# Command Reviewer Adapter

The command reviewer adapter lets external tools participate in Sugary experiments without giving them publishing control.

External reviewers receive sanitized `ReviewInputBundle` JSON on stdin and return `ReviewerResult` JSON on stdout. Sugary still owns validation, artifact capture, scoring, evidence gates, ranking, reports, and final publishing decisions.

## Contract

```text
stdin:
  ReviewInputBundle JSON

stdout:
  ReviewerResult JSON

stderr:
  diagnostic logs, captured and redacted

exit 0:
  success if stdout is valid ReviewerResult JSON

exit non-zero:
  reviewer failure, not experiment failure
```

External reviewers produce claims only. They must not publish GitHub comments or mutate pull requests directly.

## Manifest Shape

```toml
[[reviewers]]
id = "sample-command-reviewer"
type = "command"
command = "elixir"
args = ["scripts/sample_command_reviewer.exs"]
timeout_ms = 5000
cwd = "."
network = "inherit"
env_allowlist = []
env = { EXAMPLE_TOKEN = "local-secret" }
metadata = { provider = "sample" }
artifact_fields = ["raw_stdout", "raw_stderr"]
estimated_cost_usd = 0.0
stdout_limit = 65536
stderr_limit = 65536
```

Supported fields:

- `id`
- `type = "command"`
- `command`
- `args`
- `timeout_ms`
- `cwd`
- `network`
- `env_allowlist`
- `env` as an explicit inline map, or as `KEY=VALUE` entries for simple local manifests
- `metadata`
- `artifact_fields`
- `estimated_cost_usd`
- `stdout_limit`
- `stderr_limit`

Commands are executed as executable plus args, not through an implicit shell.

## Artifacts

Each command reviewer run records:

- input bundle
- redacted stdout
- redacted stderr
- parsed `ReviewerResult` when valid
- adapter metadata
- exit status
- timeout status
- duration
- estimated cost
- failure reason

Reviewer failures produce a `ReviewerResult` with no claims and an error entry. They do not crash the experiment.

## Future Tool Examples

These are examples only and are not required in CI.

```toml
[[reviewers]]
id = "opencode-review"
type = "command"
command = "opencode"
args = ["run", "/review", "--json"]
timeout_ms = 900000
env_allowlist = ["OPENCODE_API_KEY"]
```

```toml
[[reviewers]]
id = "claude-code-review"
type = "command"
command = "claude"
args = ["code", "review", "--json"]
timeout_ms = 900000
env_allowlist = ["ANTHROPIC_API_KEY"]
```

```toml
[[reviewers]]
id = "codex-review"
type = "command"
command = "codex"
args = ["review", "--json"]
timeout_ms = 900000
env_allowlist = ["OPENAI_API_KEY"]
```

```toml
[[reviewers]]
id = "semgrep"
type = "command"
command = "semgrep"
args = ["scan", "--json"]
timeout_ms = 300000
```

Internal reviewer scripts can use the same contract. They should read the input bundle from stdin, emit `ReviewerResult` JSON on stdout, and leave all scoring and publishing decisions to Sugary.
