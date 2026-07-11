defmodule Sugary.CodexClaimRefuterTest do
  use ExUnit.Case

  test "returns a structured verdict from an isolated git worktree" do
    repo =
      Path.join(System.tmp_dir!(), "sugary-refuter-repo-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(repo, "src"))
    File.write!(Path.join(repo, "src/example.ex"), "defmodule Example, do: nil\n")
    System.cmd("git", ["init", "-q", repo])
    System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
    System.cmd("git", ["-C", repo, "config", "user.name", "Sugary Test"])
    System.cmd("git", ["-C", repo, "add", "."])
    System.cmd("git", ["-C", repo, "commit", "-qm", "fixture"])
    {sha, 0} = System.cmd("git", ["-C", repo, "rev-parse", "HEAD"])
    sha = String.trim(sha)

    fake_codex = Path.expand("test/fixtures/fake_codex_refuter.sh")
    script = Path.expand("scripts/reviewers/codex_claim_refuter.exs")

    bundle = %{
      case_id: "opaque-claim",
      suite: "claim-refutation",
      pr: %{title: "Fixture", body: ""},
      diff: "",
      context: %{},
      method: %{id: "codex-claim-refuter"},
      metadata: %{
        candidate_claim: %{
          id: "candidate-1",
          claim: "The changed behavior is preexisting.",
          path: "src/example.ex"
        },
        workspace: %{head: repo, base_sha: sha, head_sha: sha}
      }
    }

    on_exit(fn -> File.rm_rf!(repo) end)

    request_path = Path.join(repo, "request.json")

    Sugary.Json.write!(request_path, %{
      command: System.find_executable("elixir"),
      args: [script],
      cwd: File.cwd!(),
      env: %{
        "SUGARY_CODEX_BIN" => fake_codex,
        "SUGARY_CODEX_MODEL" => "fake-model",
        "SUGARY_CODEX_REASONING_EFFORT" => "low"
      },
      input: Sugary.Json.encode!(bundle),
      timeout_ms: 10_000,
      stdout_limit: 65_536,
      stderr_limit: 65_536
    })

    {runner_stdout, 0} =
      System.cmd("python3", [Path.expand("scripts/command_process_runner.py"), request_path])

    runner_result = Sugary.Json.decode!(runner_stdout)
    assert runner_result["exit_status"] == 0
    stdout = runner_result["stdout"]

    result = Sugary.Json.decode!(stdout)
    verdict = result["artifacts"] |> hd()

    assert result["errors"] == []
    assert verdict["verdict"] == "refute"
    assert verdict["confidence"] == 0.91
    assert verdict["proof_type"] == "history"
    assert hd(verdict["evidence"])["path"] == "src/example.ex"
  end
end
