input = IO.read(:stdio, :eof)
bundle = :json.decode(input)

if Map.has_key?(bundle, "oracle") or String.contains?(input, "expectedClaims") do
  raise "oracle leaked to generic JSON reviewer"
end

diff = Map.get(bundle, "diff", "")
method_id = "fixture-json-reviewer"

claim = fn id, text, path, category, severity, confidence ->
  %{
    id: id,
    claim: text,
    category: category,
    severity: severity,
    confidence: confidence,
    path: path,
    start_line: 1,
    end_line: 1,
    introduced_by_pr: true,
    evidence: [
      %{
        type: "external_json_fixture",
        tier: 4,
        strength: "medium",
        summary: "External JSON fixture produced a structured finding."
      }
    ],
    dedupe_key: id,
    source: %{
      method: method_id,
      tool: "generic_json_reviewer",
      class: "external_fixture",
      raw_finding_ref: id
    },
    publish_decision: "candidate"
  }
end

claims =
  []
  |> then(fn claims ->
    if String.contains?(diff, "hard_async_race_condition") do
      [
        claim.(
          "async-race-condition",
          "External fixture detected async work that can observe partially committed state.",
          "src/preferences.ex",
          "runtime",
          "high",
          0.72
        )
        | claims
      ]
    else
      claims
    end
  end)
  |> then(fn claims ->
    if String.contains?(diff, "hard_test_only_false_confidence") do
      [
        claim.(
          "test-only-false-confidence",
          "External fixture detected tests that miss the generated parser edge case.",
          "test/parser_test.exs",
          "test",
          "medium",
          0.7
        )
        | claims
      ]
    else
      claims
    end
  end)
  |> Enum.reverse()

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
