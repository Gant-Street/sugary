defmodule Sugary.CodexStagedReviewReviewerTest do
  use ExUnit.Case

  alias Sugary.Protocol.ReviewInputBundle

  defp run_reviewer(input, env \\ %{}) do
    request_path =
      Path.join(
        System.tmp_dir!(),
        "sugary-staged-review-wrapper-test-#{System.unique_integer([:positive])}.json"
      )

    request = %{
      command: "elixir",
      args: ["scripts/reviewers/codex_staged_review_reviewer.exs"],
      cwd: File.cwd!(),
      env:
        Map.merge(
          %{
            "SUGARY_STAGED_FAKE_CODEX" => "1",
            "SUGARY_REVIEWER_ID" => "staged-wrapper-test"
          },
          env
        ),
      input: Sugary.Json.encode!(input),
      timeout_ms: 5_000,
      stdout_limit: 131_072,
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

  test "fake mode generates candidates, validates with repo evidence, and emits claims" do
    workspace = tmp_dir("staged-review-workspace")

    on_exit(fn -> File.rm_rf(workspace) end)

    File.mkdir_p!(Path.join(workspace, "src"))

    File.write!(
      Path.join(workspace, "src/reviewer.ts"),
      "export function review(value) {\n  return value.user.canReview;\n}\n"
    )

    input =
      ReviewInputBundle.new(%{
        case_id: "blind-case",
        suite: "blind",
        pr: %{title: "Reviewer change", body: "Tighten review checks"},
        diff: """
        diff --git a/src/reviewer.ts b/src/reviewer.ts
        -  return true;
        +  return value.user.canReview;
        """,
        context: %{changed_files: [%{path: "src/reviewer.ts"}]},
        method: %{id: "staged-wrapper-test"},
        metadata: %{workspace: %{head: workspace, base: workspace}}
      })

    result = run_reviewer(input)
    [artifact] = result["artifacts"]
    [claim] = result["claims"]

    assert result["reviewer_id"] == "staged-wrapper-test"
    assert artifact["adapter"] == "codex_staged_review_reviewer"
    assert artifact["staged_review"] == true
    assert artifact["workspace_provided"] == true
    assert artifact["candidate_count"] == 1
    assert artifact["validation_count"] == 1
    assert artifact["validated_count"] == 1
    assert artifact["validation_stage"] |> hd() |> Map.get("verdict") == "validated"

    assert artifact["validation_stage"]
           |> hd()
           |> Map.get("evidence_tools")
           |> Enum.map(& &1["tool"]) == [
             "changed_files",
             "read_file"
           ]

    assert claim["id"] == "staged-wrapper-test-claim-1"
    assert claim["source"]["tool"] == "codex_staged_review"
    assert claim["source"]["validator_verdict"] == "validated"
    assert claim["evidence"] |> hd() |> Map.get("type") == "staged_validation"
  end

  test "fake mode does not validate without a materialized workspace" do
    input =
      ReviewInputBundle.new(%{
        case_id: "blind-case",
        suite: "blind",
        pr: %{title: "Reviewer change", body: ""},
        diff: "diff --git a/src/reviewer.ts b/src/reviewer.ts\n+export const value = 1;\n",
        context: %{changed_files: [%{path: "src/reviewer.ts"}]},
        method: %{id: "staged-wrapper-test"},
        metadata: %{}
      })

    result = run_reviewer(input)
    [artifact] = result["artifacts"]

    assert result["claims"] == []
    assert artifact["candidate_count"] == 1
    assert artifact["validation_count"] == 1
    assert artifact["validated_count"] == 0
    assert artifact["validation_stage"] |> hd() |> Map.get("verdict") == "uncertain"
  end

  test "proof gate suppresses fake claim without expected failure evidence" do
    workspace = tmp_dir("staged-proof-workspace")

    on_exit(fn -> File.rm_rf(workspace) end)

    File.mkdir_p!(Path.join(workspace, "src"))
    File.write!(Path.join(workspace, "src/reviewer.ts"), "export const value = 1;\n")

    input =
      ReviewInputBundle.new(%{
        case_id: "blind-case",
        suite: "blind",
        pr: %{title: "Reviewer change", body: ""},
        diff: "diff --git a/src/reviewer.ts b/src/reviewer.ts\n+export const value = 1;\n",
        context: %{changed_files: [%{path: "src/reviewer.ts"}]},
        method: %{id: "staged-wrapper-test"},
        metadata: %{workspace: %{head: workspace, base: workspace}}
      })

    result = run_reviewer(input, %{"SUGARY_STAGED_PROOF_GATE" => "1"})
    [artifact] = result["artifacts"]
    [validation] = artifact["validation_stage"]

    assert result["claims"] == []
    assert artifact["proof_gate"] == true
    assert validation["proof_decision"] == "suppress"
    assert "missing_expected_failure" in validation["proof_reasons"]
  end

  test "proof gate suppresses duplicate root cause claims across paths" do
    workspace = tmp_dir("staged-proof-duplicate-workspace")

    on_exit(fn -> File.rm_rf(workspace) end)

    File.mkdir_p!(Path.join(workspace, "src"))

    File.write!(
      Path.join(workspace, "src/caller.ts"),
      "export function caller(value) {\n  return FakeApi.call(value);\n}\n"
    )

    File.write!(
      Path.join(workspace, "src/contract.ts"),
      "export function normalize(value) {\n  return value;\n}\n"
    )

    input =
      ReviewInputBundle.new(%{
        case_id: "blind-case",
        suite: "blind",
        pr: %{title: "Reviewer change", body: ""},
        diff: """
        diff --git a/src/caller.ts b/src/caller.ts
        +  return FakeApi.call(value);
        diff --git a/src/contract.ts b/src/contract.ts
        +export function normalize(value) { return value; }
        """,
        context: %{changed_files: [%{path: "src/caller.ts"}, %{path: "src/contract.ts"}]},
        method: %{id: "staged-wrapper-test"},
        metadata: %{workspace: %{head: workspace, base: workspace}}
      })

    result =
      run_reviewer(input, %{
        "SUGARY_STAGED_PROOF_GATE" => "1",
        "SUGARY_STAGED_FAKE_DUPLICATE" => "1"
      })

    [artifact] = result["artifacts"]

    assert length(result["claims"]) == 1
    assert artifact["candidate_count"] == 2
    assert artifact["validated_count"] == 1
    assert artifact["proof_summary"]["duplicate_root_cause"] == 1
    assert artifact["proof_summary"]["suppressions"]["duplicate_root_cause"] == 1

    assert Enum.count(
             artifact["validation_stage"],
             &(&1["proof_decision"] == "suppress" and
                 "duplicate_root_cause" in &1["proof_reasons"])
           ) == 1
  end

  test "dedupe v5 suppresses api contract duplicates with the same affected symbol" do
    workspace = tmp_dir("staged-proof-api-duplicate-workspace")

    on_exit(fn -> File.rm_rf(workspace) end)

    File.mkdir_p!(Path.join(workspace, "lib"))

    File.write!(
      Path.join(workspace, "lib/optimized_image.rb"),
      "class OptimizedImage\n  def self.downsize(from, to, dimensions, opts = {})\n  end\nend\n"
    )

    File.write!(
      Path.join(workspace, "lib/caller.rb"),
      "OptimizedImage.downsize(from, to, max_width, max_height, opts)\n"
    )

    input =
      ReviewInputBundle.new(%{
        case_id: "blind-case",
        suite: "blind",
        pr: %{title: "Downsize API change", body: ""},
        diff: """
        diff --git a/lib/optimized_image.rb b/lib/optimized_image.rb
        +  def self.downsize(from, to, dimensions, opts = {})
        diff --git a/lib/caller.rb b/lib/caller.rb
        +OptimizedImage.downsize(from, to, max_width, max_height, opts)
        """,
        context: %{
          changed_files: [%{path: "lib/optimized_image.rb"}, %{path: "lib/caller.rb"}]
        },
        method: %{id: "staged-wrapper-test"},
        metadata: %{workspace: %{head: workspace, base: workspace}}
      })

    result =
      run_reviewer(input, %{
        "SUGARY_STAGED_PROOF_GATE" => "1",
        "SUGARY_STAGED_DEDUPE_VERSION" => "5",
        "SUGARY_STAGED_FAKE_TYPED_CASE" => "api_duplicate"
      })

    [artifact] = result["artifacts"]

    assert artifact["dedupe_version"] == 5
    assert length(result["claims"]) == 1
    assert artifact["candidate_count"] == 2
    assert artifact["validated_count"] == 1
    assert artifact["proof_summary"]["duplicate_root_cause"] == 1
  end

  test "dedupe v5 suppresses theme color migration duplicates across selectors" do
    workspace = tmp_dir("staged-proof-theme-duplicate-workspace")

    on_exit(fn -> File.rm_rf(workspace) end)

    File.mkdir_p!(Path.join(workspace, "app/assets/stylesheets"))

    File.write!(
      Path.join(workspace, "app/assets/stylesheets/modal.scss"),
      ".custom-message-length { color: scale-color($primary, $lightness: 30%); }\n"
    )

    File.write!(
      Path.join(workspace, "app/assets/stylesheets/post.scss"),
      ".reply a { color: scale-color($primary, $lightness: 70%); }\n"
    )

    input =
      ReviewInputBundle.new(%{
        case_id: "blind-case",
        suite: "blind",
        pr: %{title: "Theme color migration", body: ""},
        diff: """
        diff --git a/app/assets/stylesheets/modal.scss b/app/assets/stylesheets/modal.scss
        +.custom-message-length { color: scale-color($primary, $lightness: 30%); }
        diff --git a/app/assets/stylesheets/post.scss b/app/assets/stylesheets/post.scss
        +.reply a { color: scale-color($primary, $lightness: 70%); }
        """,
        context: %{
          changed_files: [
            %{path: "app/assets/stylesheets/modal.scss"},
            %{path: "app/assets/stylesheets/post.scss"}
          ]
        },
        method: %{id: "staged-wrapper-test"},
        metadata: %{workspace: %{head: workspace, base: workspace}}
      })

    result =
      run_reviewer(input, %{
        "SUGARY_STAGED_PROOF_GATE" => "1",
        "SUGARY_STAGED_DEDUPE_VERSION" => "5",
        "SUGARY_STAGED_FAKE_TYPED_CASE" => "theme_color_duplicate"
      })

    [artifact] = result["artifacts"]

    assert artifact["dedupe_version"] == 5
    assert length(result["claims"]) == 1
    assert artifact["candidate_count"] == 2
    assert artifact["validated_count"] == 1
    assert artifact["proof_summary"]["duplicate_root_cause"] == 1
  end

  test "typed proof gate lets invariant-supported upload contract claims survive speculation wording" do
    workspace = tmp_dir("staged-typed-upload-workspace")

    on_exit(fn -> File.rm_rf(workspace) end)

    File.mkdir_p!(Path.join(workspace, "src"))

    File.write!(
      Path.join(workspace, "src/upload.ts"),
      "export const limit = '10 MB';\nexport const setting = 'SiteSetting max upload size';\n"
    )

    input =
      ReviewInputBundle.new(%{
        case_id: "blind-case",
        suite: "blind",
        pr: %{title: "Upload limit change", body: ""},
        diff: "diff --git a/src/upload.ts b/src/upload.ts\n+export const limit = '10 MB';\n",
        context: %{changed_files: [%{path: "src/upload.ts"}]},
        method: %{id: "staged-wrapper-test"},
        metadata: %{workspace: %{head: workspace, base: workspace}}
      })

    result =
      run_reviewer(input, %{
        "SUGARY_STAGED_PROOF_GATE" => "1",
        "SUGARY_STAGED_TYPED_PROOF_GATES" => "1",
        "SUGARY_STAGED_INVARIANT_LEDGER" => "invariants/pcrs-v8-discourse-invariants-v0.json",
        "SUGARY_STAGED_FAKE_TYPED_CASE" => "upload_limit"
      })

    [artifact] = result["artifacts"]
    [claim] = result["claims"]
    [validation] = artifact["validation_stage"]

    assert artifact["typed_proof_gates"] == true
    assert artifact["invariant_ledger"]["id"] == "pcrs-v8-discourse-invariants-v0"
    assert claim["source"]["proof_features"]["proof_type"] == "upload_limit_contract"

    assert "discourse-upload-size-settings-contract" in validation["proof_features"][
             "matched_invariants"
           ]

    refute "speculative_language" in validation["proof_reasons"]
  end

  test "typed proof gate suppresses sql injection claims without controllable input proof" do
    workspace = tmp_dir("staged-typed-sql-workspace")

    on_exit(fn -> File.rm_rf(workspace) end)

    File.mkdir_p!(Path.join(workspace, "db/migrate"))

    File.write!(
      Path.join(workspace, "db/migrate/001_fake.rb"),
      "class FakeMigration\n  def change\n    execute \"INSERT INTO rows\"\n  end\nend\n"
    )

    input =
      ReviewInputBundle.new(%{
        case_id: "blind-case",
        suite: "blind",
        pr: %{title: "Migration change", body: ""},
        diff:
          "diff --git a/db/migrate/001_fake.rb b/db/migrate/001_fake.rb\n+execute \"INSERT INTO rows\"\n",
        context: %{changed_files: [%{path: "db/migrate/001_fake.rb"}]},
        method: %{id: "staged-wrapper-test"},
        metadata: %{workspace: %{head: workspace, base: workspace}}
      })

    result =
      run_reviewer(input, %{
        "SUGARY_STAGED_PROOF_GATE" => "1",
        "SUGARY_STAGED_TYPED_PROOF_GATES" => "1",
        "SUGARY_STAGED_INVARIANT_LEDGER" => "invariants/pcrs-v8-discourse-invariants-v0.json",
        "SUGARY_STAGED_FAKE_TYPED_CASE" => "sql_injection"
      })

    [artifact] = result["artifacts"]
    [validation] = artifact["validation_stage"]

    assert result["claims"] == []
    assert validation["proof_features"]["proof_type"] == "security_injection"

    assert "sql-injection-needs-controllable-input" in validation["proof_features"][
             "suppressing_invariants"
           ]

    assert "missing_controllable_input_proof" in validation["proof_reasons"]
  end

  test "typed proof gate suppresses topic user nil claims without absence proof" do
    workspace = tmp_dir("staged-typed-topic-user-workspace")

    on_exit(fn -> File.rm_rf(workspace) end)

    File.mkdir_p!(Path.join(workspace, "app/controllers"))

    File.write!(
      Path.join(workspace, "app/controllers/topics_controller.rb"),
      "tu = TopicUser.find_by(user_id: current_user.id, topic_id: params[:topic_id])\ntu.notification_level\n"
    )

    input =
      ReviewInputBundle.new(%{
        case_id: "blind-case",
        suite: "blind",
        pr: %{title: "Topic unsubscribe", body: ""},
        diff:
          "diff --git a/app/controllers/topics_controller.rb b/app/controllers/topics_controller.rb\n+tu = TopicUser.find_by(user_id: current_user.id, topic_id: params[:topic_id])\n+tu.notification_level\n",
        context: %{changed_files: [%{path: "app/controllers/topics_controller.rb"}]},
        method: %{id: "staged-wrapper-test"},
        metadata: %{workspace: %{head: workspace, base: workspace}}
      })

    result =
      run_reviewer(input, %{
        "SUGARY_STAGED_PROOF_GATE" => "1",
        "SUGARY_STAGED_TYPED_PROOF_GATES" => "1",
        "SUGARY_STAGED_INVARIANT_LEDGER" => "invariants/pcrs-v8-discourse-invariants-v0.json",
        "SUGARY_STAGED_FAKE_TYPED_CASE" => "topic_user_nil"
      })

    [artifact] = result["artifacts"]
    [validation] = artifact["validation_stage"]

    assert result["claims"] == []
    assert validation["proof_features"]["proof_type"] == "runtime_nil"

    assert "topic-user-nil-needs-absence-proof" in validation["proof_features"][
             "suppressing_invariants"
           ]

    assert "missing_topic_user_absence_proof" in validation["proof_reasons"]
  end

  defp tmp_dir(name) do
    Path.join(System.tmp_dir!(), "sugary-#{name}-#{System.unique_integer([:positive])}")
  end
end
