input = IO.read(:stdio, :eof)
bundle = :json.decode(input)

if Map.has_key?(bundle, "oracle") or String.contains?(input, "expectedClaims") do
  raise "oracle leaked to text reviewer normalizer"
end

method_id = System.get_env("SUGARY_REVIEWER_ID") || "generic-llm-reviewer"
text = System.get_env("SUGARY_REVIEWER_TEXT") || ""

claims =
  text
  |> String.split("\n", trim: true)
  |> Enum.with_index(1)
  |> Enum.map(fn {line, index} ->
    %{
      id: "#{method_id}-text-#{index}",
      claim: String.trim(line),
      category: "external_text",
      severity: "medium",
      confidence: 0.35,
      path: "unknown",
      introduced_by_pr: false,
      evidence: [
        %{
          type: "plain_text_external_output",
          tier: 5,
          strength: "weak",
          summary: line
        }
      ],
      dedupe_key: "#{method_id}-text-#{index}",
      source: %{
        method: method_id,
        tool: "text_to_reviewer_result",
        raw_finding_ref: index
      },
      publish_decision: "candidate"
    }
  end)

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
