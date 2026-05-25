input = IO.read(:stdio, :eof)
bundle = :json.decode(input)
diff = Map.get(bundle, "diff", "")
method_id = "sample-command-reviewer"

claims =
  if String.contains?(diff, "route_admin") do
    [
      %{
        id: "sample-command-admin-route",
        claim: "Sample command reviewer saw an admin route change.",
        category: "security",
        severity: "medium",
        confidence: 0.7,
        path: "src/router.ex",
        introduced_by_pr: true,
        evidence: [
          %{
            type: "command_reviewer",
            tier: 4,
            strength: "medium",
            summary: "The sanitized input diff contains route_admin."
          }
        ],
        dedupe_key: "sample-command-admin-route",
        source: %{method: method_id, class: "research"},
        publish_decision: "candidate"
      }
    ]
  else
    []
  end

result = %{
  reviewer_id: method_id,
  method_id: method_id,
  class: "research",
  claims: claims,
  cost: 0.0,
  latency_ms: 1,
  artifacts: [],
  errors: []
}

IO.write(:json.encode(result))
