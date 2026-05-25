defmodule Sugary.PcrsCodexProofReviewerTest do
  use ExUnit.Case

  alias Sugary.Protocol.ReviewInputBundle

  defp run_reviewer(input) do
    request_path =
      Path.join(
        System.tmp_dir!(),
        "sugary-pcrs-wrapper-test-#{System.unique_integer([:positive])}.json"
      )

    request = %{
      command: "elixir",
      args: ["scripts/reviewers/pcrs_codex_proof_reviewer.exs"],
      cwd: File.cwd!(),
      env: %{
        "SUGARY_PCRS_SKIP_CODEX" => "1",
        "SUGARY_REVIEWER_ID" => "pcrs-wrapper-test"
      },
      input: Sugary.Json.encode!(input),
      timeout_ms: 5_000,
      stdout_limit: 65_536,
      stderr_limit: 65_536
    }

    try do
      File.write!(request_path, Sugary.Json.encode!(request))
      {stdout, 0} = System.cmd("python3", ["scripts/command_process_runner.py", request_path])
      runner = Sugary.Json.decode!(stdout)
      assert runner["exit_status"] == 0
      Sugary.Json.decode!(runner["stdout"])
    after
      File.rm(request_path)
    end
  end

  test "wrapper emits static proof claims without live Codex access" do
    input =
      ReviewInputBundle.new(%{
        case_id: "pcrs-wrapper-static-proof",
        suite: "blind",
        pr: %{title: "Upload resizing", body: ""},
        diff: """
        diff --git a/app/assets/javascripts/discourse/lib/utilities.js b/app/assets/javascripts/discourse/lib/utilities.js
        -    var maxSizeKB = Discourse.SiteSettings['max_' + type + '_size_kb'];
        +    var maxSizeKB = 10 * 1024; // 10MB
        -          var maxSizeKB = Discourse.SiteSettings.max_image_size_kb;
        +          var maxSizeKB = 10 * 1024; // 10 MB
        diff --git a/app/models/optimized_image.rb b/app/models/optimized_image.rb
          def self.downsize(from, to, max_width, max_height, opts={})
        + def self.downsize(from, to, dimensions, opts={})
        +   optimize("downsize", from, to, dimensions, opts)
        + end
        """,
        context: %{changed_files: []},
        method: %{id: "pcrs-wrapper-test"},
        metadata: %{}
      })

    result = run_reviewer(input)
    claims = result["claims"]

    assert result["reviewer_id"] == "pcrs-wrapper-test"
    assert length(claims) == 2
    assert Enum.all?(claims, &(&1["source"]["proof_gate"] == true))
    assert Enum.all?(claims, &(&1["evidence"] |> hd() |> Map.get("type") == "static_diff_proof"))
    assert result["artifacts"] |> hd() |> Map.get("codex_claims") == 0
  end
end
