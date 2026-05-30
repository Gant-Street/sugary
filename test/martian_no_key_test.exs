defmodule Sugary.MartianNoKeyTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  defp mock_martian_root do
    root =
      Path.join(System.tmp_dir!(), "sugary-martian-no-key-#{System.unique_integer([:positive])}")

    results = Path.join([root, "offline", "results"])
    File.mkdir_p!(Path.join(results, "judge-model"))
    File.mkdir_p!(Path.join(results, "sugary_model"))

    Sugary.Json.write!(Path.join(results, "benchmark_data.json"), %{
      "https://example.test/pr/1" => %{
        "golden_comments" => [%{"comment" => "missing auth"}, %{"comment" => "bad null"}],
        "reviews" => [
          %{"tool" => "sugary-test", "review_comments" => [%{"body" => "missing auth"}]}
        ]
      },
      "https://example.test/pr/2" => %{
        "golden_comments" => [%{"comment" => "bad cache"}],
        "reviews" => [
          %{"tool" => "sugary-test", "review_comments" => [%{"body" => "bad cache"}]}
        ]
      }
    })

    Sugary.Json.write!(Path.join([results, "sugary_model", "candidates.json"]), %{
      "https://example.test/pr/1" => %{"sugary-test" => [%{"text" => "missing auth"}]},
      "https://example.test/pr/2" => %{"sugary-test" => [%{"text" => "bad cache"}]}
    })

    Sugary.Json.write!(Path.join([results, "sugary_model", "dedup_groups.json"]), %{
      "https://example.test/pr/1" => %{"sugary-test" => [[0]]},
      "https://example.test/pr/2" => %{"sugary-test" => [[0]]}
    })

    Sugary.Json.write!(Path.join([results, "judge-model", "evaluations.json"]), %{
      "https://example.test/pr/1" => %{
        "coderabbit" => %{
          "tool" => "coderabbit",
          "skipped" => false,
          "tp" => 1,
          "fp" => 1,
          "fn" => 1,
          "total_candidates" => 2,
          "total_golden" => 2,
          "errors_count" => 0
        },
        "greptile" => %{
          "tool" => "greptile",
          "skipped" => false,
          "tp" => 2,
          "fp" => 0,
          "fn" => 0,
          "total_candidates" => 2,
          "total_golden" => 2,
          "errors_count" => 0
        }
      },
      "https://example.test/pr/2" => %{
        "coderabbit" => %{
          "tool" => "coderabbit",
          "skipped" => false,
          "tp" => 1,
          "fp" => 0,
          "fn" => 0,
          "total_candidates" => 1,
          "total_golden" => 1,
          "errors_count" => 0
        }
      }
    })

    root
  end

  test "writes no-key competitor and unjudged Sugary report" do
    File.rm_rf(".sugary/research/martian-no-key")
    root = mock_martian_root()

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(".sugary/research/martian-no-key")
    end)

    out_dir =
      Sugary.MartianNoKey.report!(
        martian_dir: root,
        sugary_tool: "sugary-test",
        model_dir: "sugary_model",
        id: "martian-no-key-test"
      )

    summary = Sugary.Json.read!(Path.join(out_dir, "summary.json"))
    assert summary["official_sugary_score"] == "unavailable_without_MARTIAN_API_KEY"
    assert summary["sugary_candidate_summary"]["candidates"] == 2
    assert summary["sugary_candidate_summary"]["judge_pair_calls"] == 3

    [model] = Sugary.Json.read!(Path.join(out_dir, "model-scorecards.json"))
    assert model["best_tool"]["tool"] == "greptile"
    assert model["best_tool"]["f1"] == 1.0

    report = File.read!(Path.join(out_dir, "report.md"))
    assert report =~ "does not judge Sugary"
    assert report =~ "coderabbit"
    assert report =~ "greptile"
  end

  test "CLI exposes no-key Martian report" do
    File.rm_rf(".sugary/research/martian-no-key")
    root = mock_martian_root()

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(".sugary/research/martian-no-key")
    end)

    output =
      capture_io(fn ->
        Sugary.CLI.main([
          "martian",
          "no-key",
          "report",
          "--martian-dir",
          root,
          "--sugary-tool",
          "sugary-test",
          "--model-dir",
          "sugary_model",
          "--id",
          "martian-no-key-cli-test"
        ])
      end)

    assert output =~ ".sugary/research/martian-no-key/"
  end
end
