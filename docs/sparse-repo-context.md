# Sparse Repo Context

Sparse Repo Context v0 is a benchmark-agnostic context builder for public benchmark PRs where full repository checkout is too slow or unnecessary for a transfer smoke.

It exists to test one variable:

```text
Does giving the same reviewer sparse repo files improve transfer?
```

It should not change the reviewer model, prompt, publisher, or add benchmark-specific patterns.

## Command

```sh
./sugary repo sparse-context --suite aacr-bench --limit 50 --id pcrs-v5-aacr-sparse-context-first50
```

The command writes local artifacts under:

```text
.sugary/research/sparse-repo-context/<run-id>/
```

and sparse base/head workspaces under:

```text
.sugary/research/workspaces/<case-id>/{base,head}
```

## Inputs

For AACR-Bench, the builder uses benchmark metadata to find:

- GitHub repository owner/name
- base commit
- head commit
- changed file paths

By default, it fetches changed files through raw GitHub URLs at exact commit SHAs. Set `SUGARY_SPARSE_FETCH_MODE=git` to use a bare partial-clone path instead.

## Reviewer Boundary

Reviewer-visible sparse workspaces contain:

- changed files at the PR head
- changed files at the PR base, when available
- cheap related files such as local imports, nearby tests, and common project config
- `SUGARY_REVIEW_CONTEXT.md`
- `SUGARY_GREP_CONTEXT.md`
- `sugary_sparse_context.json`

They do not contain:

- expected claims
- known non-issues
- reference review comments
- scorer labels
- benchmark case IDs
- original PR URLs

The full research artifact can still record case IDs and source URLs outside the reviewer workspace for auditability.

## Current Result

PCRS v5 used sparse context on the first 50 AACR cases, then reran the unchanged `pcrs-v4-portable-codex-repo-low` reviewer.

| Check | Result |
| --- | ---: |
| AACR sparse workspaces ready | 50 / 50 |
| AACR portable pool hits | 8 |
| AACR portable precision | 0.182 |
| AACR published F1 | 0.031 |
| Martian qualified guardrail | pass |

Interpretation:

- Sparse repo context worked as infrastructure.
- It did not materially solve AACR transfer.
- AACR improved only slightly over the prior diff-only portable run: F1 `0.028 -> 0.031`.
- The next bottleneck is likely candidate generation, claim matching, or evidence construction, not simple changed-file availability.

Do not tune AACR-specific static patterns to improve this result.
