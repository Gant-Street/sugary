defmodule Sugary.RepoMaterializerTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  defp with_env(name, value, fun) do
    previous = System.get_env(name)
    System.put_env(name, value)

    try do
      fun.()
    after
      if previous do
        System.put_env(name, previous)
      else
        System.delete_env(name)
      end
    end
  end

  defp mock_martian_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sugary-repo-materializer-martian-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    Sugary.Json.write!(Path.join(dir, "case-one.json"), %{
      id: "https://github.com/example/repo/pull/123",
      repo: "example/repo",
      title: "Add route",
      diff:
        "diff --git a/src/app.ex b/src/app.ex\n--- a/src/app.ex\n+++ b/src/app.ex\n+get \"/admin\", AdminController, :index\n",
      changed_files: ["src/app.ex"],
      expectedClaims: [
        %{
          id: "missing-auth",
          description: "Admin route does not check authorization.",
          category: "security",
          severity: "high"
        }
      ]
    })

    Sugary.Json.write!(Path.join(dir, "case-two.json"), %{
      id: "local-non-github-case",
      repo: "example/repo",
      title: "Local only",
      diff: "diff --git a/src/local.ex b/src/local.ex\n+++ b/src/local.ex\n+local",
      changed_files: ["src/local.ex"],
      expectedClaims: []
    })

    dir
  end

  test "parses supported GitHub PR and commit URLs" do
    assert {:ok, pr} =
             Sugary.RepoMaterializer.parse_github_url(
               "https://github.com/grafana/grafana/pull/97529"
             )

    assert pr.type == "pull_request"
    assert pr.repo_full_name == "grafana/grafana"
    assert pr.number == 97529

    assert {:ok, commit} =
             Sugary.RepoMaterializer.parse_github_url(
               "https://github.com/discourse/discourse/commit/ffbaf8c54269df2ce510de91245760fddce09896"
             )

    assert commit.type == "commit"
    assert commit.head_sha == "ffbaf8c54269df2ce510de91245760fddce09896"

    assert {:error, :unsupported_github_url} =
             Sugary.RepoMaterializer.parse_github_url(
               "https://github.com/grafana/grafana/issues/1"
             )
  end

  test "plan mode writes repo context records without network access" do
    dir = mock_martian_dir()

    with_env("MARTIAN_BENCH_DIR", dir, fn ->
      out_dir =
        Sugary.RepoMaterializer.run!(
          suite: "martian-offline",
          limit: 2,
          mode: "plan",
          id: "repo-materializer-test"
        )

      on_exit(fn -> File.rm_rf(out_dir) end)

      summary = Sugary.Json.read!(Path.join(out_dir, "summary.json"))
      assert summary["cases"] == 2
      assert summary["planned"] == 1
      assert summary["unsupported"] == 1
      assert summary["repos"] == ["example/repo"]

      report = File.read!(Path.join(out_dir, "repo-materialization-report.md"))
      assert report =~ "Repo Materialization v0"
      assert report =~ "example/repo"

      jsonl = File.read!(Path.join(out_dir, "repo-context.jsonl"))
      assert jsonl =~ "https://github.com/example/repo/pull/123"
    end)
  end

  test "CLI dispatches repo materialization" do
    dir = mock_martian_dir()

    with_env("MARTIAN_BENCH_DIR", dir, fn ->
      output =
        capture_io(fn ->
          Sugary.CLI.main([
            "repo",
            "materialize",
            "--suite",
            "martian-offline",
            "--limit",
            "1",
            "--mode",
            "plan",
            "--id",
            "repo-materializer-cli-test"
          ])
        end)

      assert output =~ ".sugary/research/repo-materializations/"

      output
      |> String.trim()
      |> File.rm_rf()
    end)
  end
end
