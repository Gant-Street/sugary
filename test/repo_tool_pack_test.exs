defmodule Sugary.RepoToolPackTest do
  use ExUnit.Case

  alias Sugary.Protocol.BenchmarkCase

  defp local_repo_fixture do
    unique = System.unique_integer([:positive])
    owner = "example"
    repo = "repo-tool-pack-#{unique}"
    root = Path.join(System.tmp_dir!(), "sugary-repo-tool-pack-#{unique}")
    work = Path.join(root, "work")
    bare = Path.join([".sugary/research/repo-cache/github.com", owner, "#{repo}.git"])
    case_id = "repo-tool-pack-case-#{unique}"

    File.mkdir_p!(Path.join(work, "src"))
    File.rm_rf!(bare)
    File.mkdir_p!(Path.dirname(bare))

    git!(["init", "--bare", bare])
    git!(["init", work])
    git!(["checkout", "-b", "main"], work)
    git!(["config", "user.email", "sugary@example.test"], work)
    git!(["config", "user.name", "Sugary Test"], work)

    File.write!(
      Path.join(work, "src/payment.ex"),
      "defmodule Payment do\n  def charge(user), do: {:ok, user}\nend\n"
    )

    git!(["add", "src/payment.ex"], work)
    git!(["commit", "-m", "base payment"], work)
    base_sha = git!(["rev-parse", "HEAD"], work)

    File.write!(
      Path.join(work, "src/payment.ex"),
      "defmodule Payment do\n  def charge(user), do: authorize_charge(user)\n  def authorize_charge(user), do: {:ok, user}\nend\n"
    )

    git!(["add", "src/payment.ex"], work)
    git!(["commit", "-m", "add authorize charge"], work)
    head_sha = git!(["rev-parse", "HEAD"], work)
    diff = git!(["diff", base_sha, head_sha, "--", "src/payment.ex"], work)
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

    BenchmarkCase.new(%{
      id: case_id,
      suite: "martian-offline",
      pr: %{
        title: "Payment authorization change",
        body: "",
        original_id: "https://github.com/#{owner}/#{repo}/commit/#{head_sha}"
      },
      diff: diff,
      context: %{allowed: %{changed_files: ["src/payment.ex"], benchmark: "martian-offline"}},
      repo: %{
        name: "#{owner}/#{repo}",
        workspace: %{
          root: Path.expand(workspace.root),
          base: Path.expand(workspace.base),
          head: Path.expand(workspace.head)
        }
      },
      oracle: %{
        expectedClaims: [
          %{id: "hidden-oracle", description: "This must not leak.", path: "src/payment.ex"}
        ],
        knownNonIssues: []
      },
      source_metadata: %{
        benchmark_metadata: %{
          target_url: "https://github.com/#{owner}/#{repo}/commit/#{head_sha}"
        }
      },
      public_benchmark: true
    })
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

  test "builds bounded repo tool packet from workspace and git history" do
    bench_case = local_repo_fixture()

    pack = Sugary.RepoToolPack.build(bench_case)

    assert pack.version == "repo-tool-pack-v0"
    assert pack.stats.workspace_available == true
    assert pack.stats.git_available == true
    assert pack.stats.changed_file_reads == 1
    assert pack.stats.git_history_entries >= 1
    assert Enum.any?(pack.identifiers, &(&1 in ["authorize_charge", "charge"]))
    assert [%{path: "src/payment.ex", snippet: snippet}] = pack.changed_file_reads
    assert snippet =~ "authorize_charge"
  end

  test "public input includes repo tools only when requested and excludes oracle" do
    bench_case = local_repo_fixture()

    no_tools =
      Sugary.Fixtures.input_bundle(
        bench_case,
        %{id: "codex-no-tools", class: "research"}
      )

    with_tools =
      Sugary.Fixtures.input_bundle(
        bench_case,
        %{id: "codex-repo-tools", class: "research", include_repo_tools: true}
      )

    refute Map.has_key?(no_tools.metadata, :repo_tools)
    assert with_tools.metadata.repo_tools.stats.workspace_available

    json = Sugary.Json.encode!(with_tools)
    refute String.contains?(json, "expectedClaims")
    refute String.contains?(json, "hidden-oracle")
    refute String.contains?(json, "oracle")
  end
end
