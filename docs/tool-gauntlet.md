# Tool Gauntlet v0

Tool Gauntlet v0 is Sugary's first ruthless test harness for reviewer tools. It is deliberately not a product feature. It is a replay-based research loop that asks whether one tool capability improves a fixed reviewer claim pool.

The point is variable isolation:

```text
fixed model output
+ fixed prompt
+ fixed benchmark cases
+ fixed scorer
+ fixed publish budget
+ one new tool signal
```

If the tool does not improve the fixed incumbent under guardrails, it is discarded or quarantined.

## Why These Tools First

The first tools are read-only because current research points to repository navigation and localization as high-leverage while execution can add more confounding variables:

- Agentless shows that localization -> repair -> validation can outperform more open-ended agents on SWE-bench Lite.
- HyperAgent reports that navigation is a core capability, not plumbing.
- SWE-agent shows that the agent-computer interface materially affects software-engineering performance.
- RepoCoder supports retrieval over repository context for repo-level code generation.
- CR-Bench shows that more search can increase recall while hurting usefulness and SNR, so every tool must be scored against noise.

The v0 capability order is:

```text
read_changed_files
base_preexisting_check
repo_rg
```

`read_changed_files` verifies whether a claim is grounded in changed files or the diff. `base_preexisting_check` tries to refute claims that are not introduced by the PR. `repo_rg` is neutral unless a local target checkout exists; it should not be counted as evidence when no checkout is available.

## Run

```sh
mix escript.build

./sugary tool gauntlet \
  --source-run .sugary/research/runs/<run-id> \
  --method public-pcrs-static-codex-low-team \
  --baseline codex-gpt-5.5-xhigh \
  --suite martian-offline \
  --limit 25 \
  --offset 25 \
  --tools read_changed_files,base_preexisting_check,repo_rg \
  --max-published 2 \
  --min-score 2.0
```

Artifacts are written under:

```text
.sugary/research/tool-gauntlets/<run-id>/
```

## Decisions

Each tool gets one of three decisions:

```text
keep:
  The tool improved F1, did not regress usefulness/SNR/noise/comment budget,
  and won more paired cases than it lost.

quarantine:
  The tool found extra signal but failed a guardrail. It may be useful for
  candidate generation, but should not influence publishing yet.

discard:
  The tool did not add measurable value over the fixed incumbent.
```

The gauntlet is sequential. A kept tool becomes part of the incumbent before testing the next tool. A discarded or quarantined tool is not carried forward.

## Non-Claims

Tool Gauntlet v0 does not prove benchmark superiority. It also does not prove that a model will use a tool well in live review. It only proves whether a specific tool-derived signal improves a fixed replayed claim pool under Sugary's current scoring.

That is intentional. Once a tool signal survives replay, the next step is a locked live experiment where the model can actually use the tool.
