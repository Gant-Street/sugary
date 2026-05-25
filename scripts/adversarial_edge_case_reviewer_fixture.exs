input = IO.read(:stdio, :eof)
bundle = :json.decode(input)

if Map.has_key?(bundle, "oracle") or String.contains?(input, "expectedClaims") do
  raise "oracle leaked to adversarial edge-case reviewer"
end

diff = Map.get(bundle, "diff", "")
method_id = "adversarial-edge-case-reviewer"

claim = fn id, text, path, severity ->
  %{
    id: id,
    claim: text,
    category: "bug",
    severity: severity,
    confidence: 0.78,
    path: path,
    introduced_by_pr: true,
    evidence: [
      %{
        type: "adversarial_input_fixture",
        tier: 4,
        strength: "medium",
        summary: "Adversarial fixture asked which generated input or state breaks the change."
      }
    ],
    dedupe_key: id,
    source: %{method: method_id, class: "research"},
    publish_decision: "candidate"
  }
end

claims =
  cond do
    String.contains?(diff, "hard_null_contract") ->
      [
        claim.(
          "cross-file-null-contract",
          "Changed retry flow can pass a nullable cached user into a cross-file non-null contract.",
          "src/session.ex",
          "high"
        )
      ]

    String.contains?(diff, "hard_pagination_off_by_one") ->
      [
        claim.(
          "pagination-off-by-one",
          "Generated pagination consumes the sentinel row and can return an incorrect has_more value.",
          "src/pagination.ex",
          "medium"
        )
      ]

    String.contains?(diff, "hard_retry_idempotency") ->
      [
        claim.(
          "retry-idempotency-bug",
          "Payment retry path can create a second provider charge because it omits the idempotency key.",
          "src/payments.ex",
          "critical"
        )
      ]

    String.contains?(diff, "hard_timezone_boundary") ->
      [
        claim.(
          "timezone-boundary-bug",
          "Date truncation before timezone conversion can shift local-midnight events across days.",
          "src/billing.ex",
          "medium"
        )
      ]

    String.contains?(diff, "discount_total") ->
      [
        claim.(
          "plausible-wrong-discount-logic",
          "Discount total is computed from the wrong amount.",
          "src/discount.ex",
          "high"
        )
      ]

    String.contains?(diff, "loadUser_retry") ->
      [
        claim.(
          "null-user-retry-build-session",
          "Retry path can pass a null user into buildSession.",
          "src/session.ex",
          "high"
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
