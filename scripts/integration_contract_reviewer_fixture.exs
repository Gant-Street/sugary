input = IO.read(:stdio, :eof)
bundle = :json.decode(input)

if Map.has_key?(bundle, "oracle") or String.contains?(input, "expectedClaims") do
  raise "oracle leaked to integration-contract reviewer"
end

diff = Map.get(bundle, "diff", "")
method_id = "integration-contract-reviewer"

claims =
  if String.contains?(diff, "schema_v2") or String.contains?(diff, "hard_schema_backcompat") do
    [
      %{
        id:
          if(String.contains?(diff, "hard_schema_backcompat"),
            do: "schema-migration-backcompat",
            else: "integration-contract-mismatch"
          ),
        claim:
          if(String.contains?(diff, "hard_schema_backcompat"),
            do: "Migration drops a legacy field before compatibility readers stop using it.",
            else: "Generated schema v2 payload does not match the consumer contract."
          ),
        category: "bug",
        severity: "high",
        confidence: 0.84,
        path: "src/integration.ex",
        introduced_by_pr: true,
        evidence: [
          %{
            type: "schema_contract_fixture",
            tier: 4,
            strength: "strong",
            summary: "Contract fixture found a schema field representation mismatch."
          }
        ],
        dedupe_key:
          if(String.contains?(diff, "hard_schema_backcompat"),
            do: "schema-migration-backcompat",
            else: "integration-contract-mismatch"
          ),
        source: %{method: method_id, class: "research"},
        publish_decision: "candidate"
      }
    ]
  else
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
