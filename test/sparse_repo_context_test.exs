defmodule Sugary.SparseRepoContextTest do
  use ExUnit.Case

  test "builds sparse AACR workspace without leaking oracle labels" do
    root = tmp_dir("sparse-context")

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(".sugary/research/repo-cache/github.com/example/repo.git")
    end)

    source_repo = Path.join(root, "source")
    bare_repo = Path.join(root, "repo.git")
    aacr_dir = Path.join(root, "aacr")
    dataset_dir = Path.join(aacr_dir, "dataset")

    File.mkdir_p!(source_repo)
    File.mkdir_p!(dataset_dir)

    git!(["-C", source_repo, "init", "-q"])
    git!(["-C", source_repo, "config", "user.email", "sugary@example.com"])
    git!(["-C", source_repo, "config", "user.name", "Sugary Test"])

    File.mkdir_p!(Path.join(source_repo, "src"))

    File.write!(
      Path.join(source_repo, "src/reviewer.ts"),
      "export function review(value) {\n  return value;\n}\n"
    )

    git!(["-C", source_repo, "add", "."])
    git!(["-C", source_repo, "commit", "-q", "-m", "base"])
    base_sha = git_out!(["-C", source_repo, "rev-parse", "HEAD"])

    File.write!(
      Path.join(source_repo, "src/reviewer.ts"),
      "export function review(value) {\n  if (!value.user) return true;\n  return value.user.canReview;\n}\n"
    )

    File.mkdir_p!(Path.join(source_repo, "test"))

    File.write!(
      Path.join(source_repo, "test/reviewer_test.ts"),
      "import { review } from '../src/reviewer';\n"
    )

    git!(["-C", source_repo, "add", "."])
    git!(["-C", source_repo, "commit", "-q", "-m", "head"])
    head_sha = git_out!(["-C", source_repo, "rev-parse", "HEAD"])
    diff = git_out!(["-C", source_repo, "diff", base_sha, head_sha])
    git!(["clone", "--bare", source_repo, bare_repo])

    Sugary.Json.write!(Path.join(dataset_dir, "positive_samples.json"), [
      %{
        githubPrUrl: "https://github.com/example/repo/pull/1",
        source_commit: base_sha,
        target_commit: head_sha,
        project_main_language: "TypeScript",
        change_line_count: 3,
        diff: diff,
        comments: [
          %{
            is_ai_comment: true,
            note: "The reviewer now returns true when value.user is missing.",
            path: "src/reviewer.ts",
            from_line: 2,
            to_line: 2,
            category: "Code Defect",
            context: "Repository Level"
          }
        ]
      }
    ])

    Sugary.Json.write!(Path.join(dataset_dir, "negative_samples.json"), [])

    with_env("AACR_BENCH_DIR", aacr_dir, fn ->
      with_env("SUGARY_GITHUB_CLONE_URL_TEMPLATE", "file://#{bare_repo}", fn ->
        out_dir =
          Sugary.SparseRepoContext.run!(%{
            "suite" => "aacr-bench",
            "limit" => 1,
            "id" => "sparse-context-test"
          })

        on_exit(fn -> File.rm_rf(out_dir) end)

        summary = Sugary.Json.read!(Path.join(out_dir, "summary.json"))
        assert summary["sparse_workspace_ready"] == 1
        assert summary["changed_files_written"] >= 1

        [bench_case] = Sugary.PublicBenchmarks.load_cases!("aacr-bench", limit: 1)
        workspace = bench_case.repo.workspace

        assert File.exists?(Path.join(workspace.head, "src/reviewer.ts"))
        assert File.exists?(Path.join(workspace.base, "src/reviewer.ts"))
        assert File.exists?(Path.join(workspace.head, "SUGARY_REVIEW_CONTEXT.md"))

        workspace_context = File.read!(Path.join(workspace.head, "SUGARY_REVIEW_CONTEXT.md"))

        workspace_metadata =
          Sugary.Json.read!(Path.join(workspace.head, "sugary_sparse_context.json"))

        refute String.contains?(workspace_context, "aacr-bench")
        refute String.contains?(workspace_context, "https://github.com/example/repo/pull/1")
        refute Map.has_key?(workspace_metadata, "case_source_url")
        refute Map.has_key?(workspace_metadata, "benchmark")
        assert workspace_metadata["oracle_included"] == false
        assert workspace_metadata["source_url_included"] == false

        input = Sugary.Fixtures.input_bundle(bench_case, %{id: "x", include_workspace: true})
        encoded = Sugary.Json.encode!(input)

        assert get_in(input.metadata, [:workspace, :head])
        refute String.contains?(encoded, "expectedClaims")
        refute String.contains?(encoded, "The reviewer now returns true")
      end)
    end)
  end

  defp tmp_dir(name) do
    Path.join(System.tmp_dir!(), "sugary-#{name}-#{System.unique_integer([:positive])}")
  end

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

  defp git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{out}")
    end
  end

  defp git_out!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{out}")
    end
  end
end
