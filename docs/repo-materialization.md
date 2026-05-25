# Repo Materialization v0

Repo Materialization v0 prepares real repository state for code-review backtests. It is a substrate, not a reviewer improvement.

The target state for a benchmark case is:

```text
base commit + head commit + PR diff + changed files + full read-only repo context
```

Without that, tools like `rg`, `read_file`, and future test execution are measuring the wrong code.

## Modes

```text
plan:
  Parse benchmark records and verify that each case points at a supported
  GitHub pull request or commit. No network or git fetch.

metadata:
  Resolve exact base/head SHAs through the GitHub API. No repo checkout.

fetch:
  Create/update a local bare repo cache, checkout base/head workspaces,
  and compare git changed files against the benchmark diff.
```

## Commands

```sh
./sugary repo materialize \
  --suite martian-offline \
  --limit 30 \
  --offset 0 \
  --mode plan

./sugary repo materialize \
  --suite martian-offline \
  --limit 30 \
  --offset 0 \
  --mode metadata

./sugary repo materialize \
  --suite martian-offline \
  --limit 10 \
  --offset 0 \
  --mode fetch
```

Artifacts are written under:

```text
.sugary/research/repo-materializations/<run-id>/
```

Fetched repositories and workspaces live under:

```text
.sugary/research/repo-cache/
.sugary/research/workspaces/
```

These paths are local research artifacts and should not be committed.

## Diff Parity

Every fetched case records diff parity:

```text
exact:
  git diff base..head changed files match the benchmark changed files.

partial:
  one changed-file set is a subset of the other.

mismatch:
  the benchmark diff and git diff point at different files.

unavailable:
  the workspace was not fetched or git diff failed.
```

Only `exact` and carefully reviewed `partial` cases should be used for tool backtests.

## Tool Readiness

When a case is `workspace_ready`, Sugary can safely expose read-only tools over the materialized repo state:

```text
list_changed_files
read_changed_file
read_base_file
rg_head
rg_base
```

Do not use repo tools on cases where materialization failed or diff parity is unknown.

## Current Martian Result

On May 25, 2026:

- `plan` mode found 30/30 parseable Martian cases.
- `metadata` mode resolved exact refs for 30/30 cases.
- `fetch` mode materialized 10/10 Discourse cases with exact diff parity.

This establishes that Martian can back real repo-context experiments, but it does not validate any reviewer architecture yet.
