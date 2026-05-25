input = IO.read(:stdio, :eof)
bundle = :json.decode(input)

if Map.has_key?(bundle, "oracle") or String.contains?(input, "expectedClaims") do
  raise "oracle leaked to security specialist reviewer"
end

diff = Map.get(bundle, "diff", "")
method_id = "security-specialist-reviewer"

claim = fn id, text, path ->
  %{
    id: id,
    claim: text,
    category: "security",
    severity: "high",
    confidence: 0.83,
    path: path,
    introduced_by_pr: true,
    evidence: [
      %{
        type: "auth_pattern_fixture",
        tier: 3,
        strength: "strong",
        summary: "Security fixture found an authorization-sensitive route pattern."
      }
    ],
    dedupe_key: id,
    source: %{method: method_id, class: "research"},
    publish_decision: "candidate"
  }
end

claims =
  cond do
    String.contains?(diff, "hard_tenant_leak") ->
      [
        claim.(
          "tenant-isolation-leak",
          "Generated export route trusts an account_id parameter without tenant scoping.",
          "src/routes.ex"
        )
      ]

    String.contains?(diff, "hard_wrong_permission_object") ->
      [
        claim.(
          "permission-check-wrong-object",
          "Generated delete path checks workspace permissions but not the target document owner.",
          "src/documents.ex"
        )
      ]

    String.contains?(diff, "generatedRoute") ->
      [
        claim.(
          "weak-auth-generated-route",
          "Generated route checks login but not tenant or role authorization.",
          "src/routes.ex"
        )
      ]

    String.contains?(diff, "route_admin") ->
      [
        claim.(
          "admin-route-missing-auth",
          "Admin route is added without an authorization guard.",
          "src/router.ex"
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
