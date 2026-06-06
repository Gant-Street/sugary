defmodule Sugary.RepoToolsTest do
  use ExUnit.Case

  alias Sugary.Protocol.BenchmarkCase

  defp local_repo_fixture do
    unique = System.unique_integer([:positive])
    owner = "example"
    repo = "repo-tools-#{unique}"
    root = Path.join(System.tmp_dir!(), "sugary-repo-tools-#{unique}")
    work = Path.join(root, "work")
    bare = Path.join([".sugary/research/repo-cache/github.com", owner, "#{repo}.git"])
    case_id = "repo-tools-case-#{unique}"

    File.mkdir_p!(Path.join(work, "src"))
    File.rm_rf!(bare)
    File.mkdir_p!(Path.dirname(bare))

    git!(["init", "--bare", bare])
    git!(["init", work])
    git!(["checkout", "-b", "main"], work)
    git!(["config", "user.email", "sugary@example.test"], work)
    git!(["config", "user.name", "Sugary Test"], work)

    File.write!(
      Path.join(work, "src/auth.ex"),
      "defmodule Auth do\n  def check, do: :public\nend\n"
    )

    git!(["add", "src/auth.ex"], work)
    git!(["commit", "-m", "base auth"], work)
    base_sha = git!(["rev-parse", "HEAD"], work)

    File.write!(
      Path.join(work, "src/auth.ex"),
      "defmodule Auth do\n  def check(user), do: authorize(user)\nend\n"
    )

    git!(["add", "src/auth.ex"], work)
    git!(["commit", "-m", "add authorization"], work)
    head_sha = git!(["rev-parse", "HEAD"], work)
    diff = git!(["diff", base_sha, head_sha, "--", "src/auth.ex"], work)
    git!(["remote", "add", "origin", Path.expand(bare)], work)
    git!(["push", "origin", "#{head_sha}:refs/heads/main"], work)

    workspace = Sugary.RepoMaterializer.workspace_paths(case_id)
    File.rm_rf!(workspace.root)
    File.mkdir_p!(workspace.base)
    File.mkdir_p!(workspace.head)
    git!(["--git-dir", bare, "--work-tree", workspace.base, "checkout", "-f", base_sha])
    git!(["--git-dir", bare, "--work-tree", workspace.head, "checkout", "-f", head_sha])

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(bare)
      File.rm_rf(workspace.root)
    end)

    bench_case =
      BenchmarkCase.new(%{
        id: case_id,
        suite: "martian-offline",
        pr: %{title: "Auth change", body: "", original_id: "#{owner}/#{repo}"},
        diff: diff,
        context: %{allowed: %{changed_files: ["src/auth.ex"], benchmark: "martian-offline"}},
        repo: %{
          name: "#{owner}/#{repo}",
          workspace: %{
            root: Path.expand(workspace.root),
            base: Path.expand(workspace.base),
            head: Path.expand(workspace.head)
          }
        },
        oracle: %{expectedClaims: [], knownNonIssues: []},
        source_metadata: %{
          benchmark_metadata: %{
            target_url: "https://github.com/#{owner}/#{repo}/commit/#{head_sha}"
          }
        },
        public_benchmark: true
      })

    %{case: bench_case, head_sha: head_sha}
  end

  defp claim(attrs \\ %{}) do
    Map.merge(
      %{
        id: "claim-1",
        claim: "Authorization behavior changed and should be reviewed.",
        category: "security",
        severity: "high",
        confidence: 0.9,
        path: "src/auth.ex",
        failure_path: ["Auth.check now calls authorize"],
        evidence: [%{summary: "authorize is introduced in the changed file.", tier: 3}],
        dedupe_key: "auth-authorize"
      },
      attrs
    )
  end

  defp git!(args, cwd \\ nil) do
    opts =
      [stderr_to_stdout: true]
      |> maybe_cwd(cwd)

    case System.cmd("git", args, opts) do
      {stdout, 0} -> String.trim(stdout)
      {stdout, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{stdout}")
    end
  end

  defp maybe_cwd(opts, nil), do: opts
  defp maybe_cwd(opts, cwd), do: Keyword.put(opts, :cd, cwd)

  test "repo grep and history tools return structured evidence from materialized workspaces" do
    fixture = local_repo_fixture()

    read = Sugary.RepoTools.evidence_for_claim(fixture.case, claim(), "read_changed_file")
    assert read.status == "support"
    assert [%{path: "src/auth.ex"} | _] = read.citations

    grep = Sugary.RepoTools.evidence_for_claim(fixture.case, claim(), "repo_grep")
    assert grep.status == "support"
    assert grep.query in ["auth", "authorize"]
    assert Enum.any?(grep.citations, &(&1.path == "src/auth.ex"))

    history = Sugary.RepoTools.evidence_for_claim(fixture.case, claim(), "git_history")
    assert history.status == "support"
    assert Enum.any?(history.citations, &(&1.commit == fixture.head_sha))

    history_grep = Sugary.RepoTools.evidence_for_claim(fixture.case, claim(), "git_grep_history")
    assert history_grep.status == "support"
    assert history_grep.query in ["auth", "authorize"]
    assert Enum.any?(history_grep.citations, &(&1.commit == fixture.head_sha))
  end

  test "read changed file refutes claims outside the changed-file set" do
    fixture = local_repo_fixture()

    signal =
      Sugary.RepoTools.evidence_for_claim(
        fixture.case,
        claim(%{path: "src/unrelated.ex"}),
        "read_changed_file"
      )

    assert signal.status == "counterargument"
    assert signal.penalty > signal.bonus
  end
end
