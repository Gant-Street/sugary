input = IO.read(:stdio, :eof)
bundle = :json.decode(input)

if Map.has_key?(bundle, "oracle") or String.contains?(input, "expectedClaims") do
  raise "oracle leaked to semgrep reviewer"
end

method_id = "semgrep-json"

claims =
  case System.get_env("SUGARY_SEMGREP_JSON") do
    nil ->
      []

    json ->
      json
      |> :json.decode()
      |> Map.get("results", [])
      |> Enum.with_index(1)
      |> Enum.map(fn {finding, index} ->
        path = get_in(finding, ["path"]) || "unknown"
        start = get_in(finding, ["start", "line"])
        check_id = Map.get(finding, "check_id", "semgrep-finding")
        message = get_in(finding, ["extra", "message"]) || check_id
        severity = get_in(finding, ["extra", "severity"]) || "medium"

        %{
          id: "semgrep-#{index}",
          claim: message,
          category: "static_analysis",
          severity: String.downcase(to_string(severity)),
          confidence: 0.65,
          path: path,
          start_line: start,
          end_line: start,
          introduced_by_pr: false,
          evidence: [
            %{
              type: "semgrep_json",
              tier: 3,
              strength: "medium",
              summary: message
            }
          ],
          dedupe_key: "#{check_id}:#{path}:#{start}",
          source: %{
            method: method_id,
            tool: "semgrep",
            raw_finding_ref: check_id
          },
          publish_decision: "candidate"
        }
      end)
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
