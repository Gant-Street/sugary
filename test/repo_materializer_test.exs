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

  defp local_git_pull_fixture do
    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "sugary-repo-materializer-git-#{unique}")
    owner = "example"
    repo = "repo-#{unique}"
    number = 123
    case_id = "https://github.com/#{owner}/#{repo}/pull/#{number}"
    remote = Path.join([root, "remotes", owner, "#{repo}.git"])
    work = Path.join(root, "work")
    bench = Path.join(root, "bench")

    File.mkdir_p!(Path.dirname(remote))
    File.mkdir_p!(Path.join(work, "src"))
    File.mkdir_p!(bench)

    git!(["init", "--bare", remote])
    git!(["--git-dir", remote, "symbolic-ref", "HEAD", "refs/heads/main"])
    git!(["init", work])
    git!(["checkout", "-b", "main"], work)
    git!(["config", "user.email", "sugary@example.test"], work)
    git!(["config", "user.name", "Sugary Test"], work)

    File.write!(
      Path.join(work, "src/app.ex"),
      "defmodule App do\n  def route, do: :public\nend\n"
    )

    git!(["add", "src/app.ex"], work)
    git!(["commit", "-m", "base"], work)
    base_sha = git!(["rev-parse", "HEAD"], work)
    git!(["remote", "add", "origin", remote], work)
    git!(["push", "origin", "#{base_sha}:refs/heads/main"], work)

    git!(["checkout", "-b", "feature"], work)
    File.write!(Path.join(work, "src/app.ex"), "defmodule App do\n  def route, do: :admin\nend\n")
    git!(["add", "src/app.ex"], work)
    git!(["commit", "-m", "feature"], work)
    head_sha = git!(["rev-parse", "HEAD"], work)
    diff = git!(["diff", base_sha, head_sha, "--", "src/app.ex"], work)
    git!(["push", "origin", "#{head_sha}:refs/pull/#{number}/head"], work)

    git!(["checkout", "main"], work)
    git!(["merge", "--no-ff", "feature", "-m", "Merge pull request ##{number}"], work)
    merge_sha = git!(["rev-parse", "HEAD"], work)
    git!(["push", "origin", "#{merge_sha}:refs/pull/#{number}/merge"], work)

    Sugary.Json.write!(Path.join(bench, "case-one.json"), %{
      id: case_id,
      repo: "#{owner}/#{repo}",
      title: "Materialized PR",
      diff: diff,
      changed_files: ["src/app.ex"],
      expectedClaims: [
        %{
          id: "admin-route-missing-auth",
          description: "Generated admin route does not check authorization.",
          category: "security",
          severity: "high"
        }
      ]
    })

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(Path.join([".sugary/research/repo-cache/github.com", owner, "#{repo}.git"]))
      File.rm_rf(Sugary.RepoMaterializer.workspace_paths(case_id).root)
    end)

    %{
      bench: bench,
      case_id: case_id,
      base_sha: base_sha,
      head_sha: head_sha,
      clone_template: "file://#{Path.join([root, "remotes", "{owner}", "{repo}.git"])}"
    }
  end

  defp git!(args, cwd \\ nil) do
    opts =
      [stderr_to_stdout: true]
      |> maybe_put_cwd(cwd)

    case System.cmd("git", args, opts) do
      {out, 0} -> String.trim(out)
      {out, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{out}")
    end
  end

  defp maybe_put_cwd(opts, nil), do: opts
  defp maybe_put_cwd(opts, cwd), do: Keyword.put(opts, :cd, cwd)

  defp context_records(out_dir) do
    out_dir
    |> Path.join("repo-context.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Sugary.Json.decode!/1)
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

  test "fetch mode resolves GitHub pull request metadata from git refs before API fallback" do
    fixture = local_git_pull_fixture()

    with_env("MARTIAN_BENCH_DIR", fixture.bench, fn ->
      with_env("SUGARY_GITHUB_CLONE_URL_TEMPLATE", fixture.clone_template, fn ->
        out_dir =
          Sugary.RepoMaterializer.run!(
            suite: "martian-offline",
            limit: 1,
            mode: "fetch",
            id: "repo-materializer-git-test"
          )

        on_exit(fn -> File.rm_rf(out_dir) end)

        summary = Sugary.Json.read!(Path.join(out_dir, "summary.json"))
        assert summary["workspace_ready"] == 1
        assert summary["git_metadata_resolved"] == 1
        assert summary["api_metadata_resolved"] == 0

        [record] = context_records(out_dir)
        assert record["target"]["url"] == fixture.case_id
        assert record["status"] == "workspace_ready"
        assert record["diff_parity"] == "exact"
        assert record["refs"]["resolution_strategy"] == "git_pull_merge"
        assert record["refs"]["base_sha"] == fixture.base_sha
        assert record["refs"]["head_sha"] == fixture.head_sha
        refute Map.has_key?(record["refs"], "git_fallback_reason")

        report = File.read!(Path.join(out_dir, "repo-materialization-report.md"))
        assert report =~ "Git metadata resolved: 1"
        assert report =~ "GitHub API is only used as a fallback"
      end)
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
