input = IO.read(:stdio, :eof)
bundle = :json.decode(input)

if Map.has_key?(bundle, "oracle") or String.contains?(input, "expectedClaims") do
  raise "oracle leaked to static analysis reviewer"
end

diff = Map.get(bundle, "diff", "")
method_id = "static-analysis-reviewer"

base_claim = fn id, claim, path, severity ->
  %{
    id: id,
    claim: claim,
    category: "bug",
    severity: severity,
    confidence: 0.74,
    path: path,
    introduced_by_pr: true,
    evidence: [
      %{
        type: "static_analysis_fixture",
        tier: 3,
        strength: "medium",
        summary: "Static-analysis fixture matched a deterministic code pattern."
      }
    ],
    dedupe_key: id,
    source: %{method: method_id, class: "research"},
    publish_decision: "candidate"
  }
end

claims =
  []
  |> then(fn claims ->
    if String.contains?(diff, "imaginaryClient") or
         String.contains?(diff, "hard_generated_api_hallucination") do
      [
        base_claim.(
          if(String.contains?(diff, "hard_generated_api_hallucination"),
            do: "generated-api-hallucination",
            else: "hallucinated-api-call"
          ),
          "Generated code calls an API that does not exist in the client.",
          "src/client.ex",
          "high"
        )
        | claims
      ]
    else
      claims
    end
  end)
  |> then(fn claims ->
    if String.contains?(diff, "hard_async_race_condition") do
      [
        base_claim.(
          "async-race-condition",
          "Generated async work can observe partially committed state.",
          "src/preferences.ex",
          "high"
        )
        | claims
      ]
    else
      claims
    end
  end)
  |> then(fn claims ->
    if String.contains?(diff, "rewriteAllHandlers") do
      [
        base_claim.(
          "overbroad-refactor-risk",
          "Generated refactor changes unrelated handlers in the same patch.",
          "src/handlers.ex",
          "medium"
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
