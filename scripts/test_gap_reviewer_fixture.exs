input = IO.read(:stdio, :eof)
bundle = :json.decode(input)

if Map.has_key?(bundle, "oracle") or String.contains?(input, "expectedClaims") do
  raise "oracle leaked to test-gap reviewer"
end

diff = Map.get(bundle, "diff", "")
method_id = "test-gap-reviewer"

claim = fn id, text, path ->
  %{
    id: id,
    claim: text,
    category: "test",
    severity: "medium",
    confidence: 0.76,
    path: path,
    introduced_by_pr: true,
    evidence: [
      %{
        type: "test_gap_fixture",
        tier: 4,
        strength: "medium",
        summary: "Test-gap fixture found new behavior without matching regression coverage."
      }
    ],
    dedupe_key: id,
    source: %{method: method_id, class: "research"},
    publish_decision: "candidate"
  }
end

claims =
  cond do
    String.contains?(diff, "hard_test_only_false_confidence") ->
      [
        claim.(
          "test-only-false-confidence",
          "The added tests cover only the happy path and miss the generated parser edge case.",
          "test/parser_test.exs"
        )
      ]

    String.contains?(diff, "edge_case_missing") ->
      [
        claim.(
          "missing-edge-case-test",
          "Generated branch lacks the edge-case test that would catch empty input.",
          "test/parser_test.exs"
        )
      ]

    String.contains?(diff, "new_behavior_no_test") ->
      [
        claim.(
          "new-behavior-missing-test",
          "New behavior is not covered by a regression test.",
          "test/fallback_test.exs"
        )
      ]

    true ->
      []
  end

IO.write(
  :json.encode(%{
    reviewer_id: method_id,
    method_id: method_id,
    class: "research",
    claims: claims,
    cost: 0.0,
    latency_ms: 1,
    artifacts: [],
    errors: []
  })
)
