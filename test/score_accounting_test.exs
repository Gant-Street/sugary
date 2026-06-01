defmodule Sugary.ScoreAccountingTest do
  use ExUnit.Case

  alias Sugary.Protocol

  test "separates precision denominator from noise events" do
    bench_case =
      Protocol.BenchmarkCase.new(%{
        id: "accounting",
        suite: "unit",
        pr: %{title: "Accounting", body: ""},
        diff: "",
        context: %{},
        oracle: %{
          expectedClaims: [
            %{
              id: "expected-1",
              description: "Null value reaches runtime crash",
              category: "bug",
              path: "src/app.ts"
            }
          ],
          knownNonIssues: [
            %{
              id: "trap-1",
              description: "Null value reaches runtime crash",
              category: "bug",
              path: "src/app.ts"
            }
          ]
        }
      })

    claim =
      Protocol.ReviewClaim.new(%{
        id: "claim-1",
        claim: "Null value reaches runtime crash",
        category: "bug",
        severity: "high",
        confidence: 0.8,
        path: "src/app.ts",
        introduced_by_pr: true,
        evidence: [%{type: "unit", tier: 3, strength: "medium", summary: "null crash"}],
        dedupe_key: "claim-1",
        source: %{method: "unit"},
        publish_decision: "publish"
      })

    accounting = Sugary.ScoreAccounting.claim_accounting(bench_case, [claim])

    assert accounting.precision_denominator == 1
    assert accounting.unique_hits == 1
    assert accounting.noisy_or_trap_comments == 1
    assert accounting.hit_and_trap_comments == 1
    assert accounting.noise_events == 1
  end
end
