# Replay Cache

Real reviewers can be expensive, slow, and nondeterministic. Sugary caches command reviewer results under:

```text
.sugary/research/replay-cache/
```

The cache stores `ReviewerResult` artifacts. It does not store secret values.

## Cache Key

The cache key includes:

- reviewer id
- reviewer manifest hash
- command and args hash
- sanitized input bundle hash
- environment shape hash, excluding secret values
- required secret names
- tool version when declared
- Sugary protocol version

Changing the input bundle, command, args, reviewer manifest, or declared environment shape invalidates the cache.

## Replay Modes

Use:

```sh
./sugary experiment run experiments/external-real-pack-local-smoke.toml --replay-mode cache-first
```

Modes:

- `live`: always run the command and write cache.
- `cache-first`: use cache if present, otherwise run and write cache.
- `replay-only`: use cache only; skip when missing.
- `refresh`: run command and overwrite cache.

## Artifacts

Every command reviewer artifact records:

- execution mode: `live`, `replay`, or `skip`
- replay mode
- cache key
- cache hit/miss
- duration
- estimated cost
- cost model
- stdout/stderr sizes and truncation
- tool version when declared
- network requirement
- required secret names only
- quality warnings

Reports include an `External Reviewer Execution` table so live and replayed results are visible.

## Recommended Use

During local development:

```sh
--replay-mode cache-first
```

For offline reproduction:

```sh
--replay-mode replay-only
```

When intentionally refreshing a tool result:

```sh
--replay-mode refresh
```

Do not treat replayed public benchmark smoke as an official score. Replay is for reproducibility and cost control, not benchmark submission.
