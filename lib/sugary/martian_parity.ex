defmodule Sugary.MartianParity do
  @moduledoc false

  @root ".sugary/research/martian-parity"
  @default_tool "sugary-pcrs-repo-budget-max2"
  @default_model_dir "sugary_local_parity_v0"

  def export!(opts) when is_map(opts) do
    opts
    |> Enum.map(fn {key, value} ->
      {String.to_atom(to_string(key) |> String.replace("-", "_")), value}
    end)
    |> export!()
  end

  def export!(opts) when is_list(opts) do
    source_run = fetch_opt!(opts, :source_run)
    method_id = fetch_opt!(opts, :method)
    tool = Keyword.get(opts, :tool, @default_tool)
    policy_id = Keyword.get(opts, :policy)
    limit = opts |> Keyword.get(:limit, 50) |> int()
    offset = opts |> Keyword.get(:offset, 0) |> int()
    id = Keyword.get(opts, :id, "martian-official-parity-v0")
    model_dir_name = Keyword.get(opts, :model_dir, @default_model_dir)
    {martian_root, offline_dir} = martian_paths(Keyword.get(opts, :martian_dir))

    cases =
      with_env("MARTIAN_BENCH_DIR", martian_root, fn ->
        Sugary.PublicBenchmarks.load_cases!("martian-offline", limit: limit, offset: offset)
      end)

    out_dir = make_out_dir(id)
    File.rm_rf!(out_dir)
    File.mkdir_p!(out_dir)

    benchmark_data_path = Path.join([offline_dir, "results", "benchmark_data.json"])
    benchmark_data = Sugary.Json.read!(benchmark_data_path)
    File.cp!(benchmark_data_path, Path.join(out_dir, "benchmark_data.before.json"))

    now = DateTime.utc_now() |> Calendar.strftime("%Y-%m-%dT%H:%M:%SZ")
    policy = policy(policy_id)

    exports =
      Enum.map(cases, fn bench_case ->
        claims = source_run |> claims_path(method_id, bench_case.id) |> Sugary.Json.read!()
        published = publish_claims(claims, policy)
        comments = Enum.map(published, &review_comment(&1, now))
        candidates = Enum.map(published, &candidate(&1))
        groups = published |> Enum.with_index() |> Enum.map(fn {_claim, index} -> [index] end)
        golden_url = source_case_id!(bench_case)

        %{
          case_id: bench_case.id,
          golden_url: golden_url,
          comments: comments,
          candidates: candidates,
          dedup_groups: groups,
          raw_claims: length(claims),
          published_claims: length(published)
        }
      end)

    updated_benchmark_data =
      Enum.reduce(exports, benchmark_data, fn export, acc ->
        Map.update!(acc, export.golden_url, fn entry ->
          reviews =
            entry
            |> Map.get("reviews", [])
            |> Enum.reject(&(Map.get(&1, "tool") == tool))
            |> Kernel.++([review_entry(entry, export, tool, source_run, method_id, policy_id)])

          Map.put(entry, "reviews", reviews)
        end)
      end)

    Sugary.Json.write!(benchmark_data_path, updated_benchmark_data)

    candidates_by_url =
      Map.new(exports, fn export -> {export.golden_url, %{tool => export.candidates}} end)

    dedup_by_url =
      Map.new(exports, fn export -> {export.golden_url, %{tool => export.dedup_groups}} end)

    model_dir = Path.join([offline_dir, "results", model_dir_name])
    candidates_path = Path.join(model_dir, "candidates.json")
    dedup_groups_path = Path.join(model_dir, "dedup_groups.json")
    Sugary.Json.write!(candidates_path, candidates_by_url)
    Sugary.Json.write!(dedup_groups_path, dedup_by_url)

    Sugary.Json.write!(Path.join(out_dir, "exported-reviews.json"), exports)
    Sugary.Json.write!(Path.join(out_dir, "candidates.json"), candidates_by_url)
    Sugary.Json.write!(Path.join(out_dir, "dedup_groups.json"), dedup_by_url)

    summary =
      summary(%{
        id: id,
        source_run: source_run,
        method_id: method_id,
        tool: tool,
        policy_id: policy_id || "raw-published",
        limit: limit,
        offset: offset,
        cases: cases,
        exports: exports,
        out_dir: out_dir,
        martian_root: martian_root,
        martian_commit_sha: git_sha(martian_root),
        benchmark_data_path: benchmark_data_path,
        candidates_path: candidates_path,
        dedup_groups_path: dedup_groups_path,
        credentials: credentials(offline_dir),
        model_dir_name: model_dir_name
      })

    Sugary.Json.write!(Path.join(out_dir, "summary.json"), summary)
    File.write!(Path.join(out_dir, "report.md"), render_report(summary))

    out_dir
  end

  defp fetch_opt!(opts, key) do
    Keyword.get(opts, key) || raise ArgumentError, "missing required option --#{dash(key)}"
  end

  defp martian_paths(nil) do
    case Sugary.Martian.locate() do
      nil ->
        raise ArgumentError,
              "Martian offline benchmark not found. Set --martian-dir or MARTIAN_BENCH_DIR."

      root ->
        martian_paths(root)
    end
  end

  defp martian_paths(path) do
    expanded = Path.expand(path)

    cond do
      File.exists?(Path.join([expanded, "results", "benchmark_data.json"])) ->
        {Path.dirname(expanded), expanded}

      File.exists?(Path.join([expanded, "offline", "results", "benchmark_data.json"])) ->
        {expanded, Path.join(expanded, "offline")}

      true ->
        raise ArgumentError, "Martian offline results not found under #{path}"
    end
  end

  defp make_out_dir(id) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    Path.join(@root, "#{timestamp}-#{id}")
  end

  defp claims_path(source_run, method_id, case_id) do
    aggregate = Path.join([source_run, "claims", "#{method_id}--#{case_id}.json"])
    method_local = Path.join([source_run, method_id, "claims", "#{case_id}.json"])

    cond do
      File.exists?(aggregate) -> aggregate
      File.exists?(method_local) -> method_local
      true -> raise ArgumentError, "claims not found for #{method_id} / #{case_id}"
    end
  end

  defp source_case_id!(bench_case) do
    bench_case
    |> Map.get(:source_metadata, %{})
    |> field(:original_case_id)
    |> case do
      value when is_binary(value) and value != "" -> value
      _other -> raise ArgumentError, "Martian case #{bench_case.id} is missing original_case_id"
    end
  end

  defp policy(nil), do: %{id: "raw-published", strategy: "raw"}
  defp policy("raw"), do: %{id: "raw-published", strategy: "raw"}
  defp policy("raw-published"), do: %{id: "raw-published", strategy: "raw"}

  defp policy("team-ev-max-1"),
    do: %{id: "team-ev-max-1", strategy: "team_ev", max_published: 1, min_score: 1.4}

  defp policy("team-ev-max-2"),
    do: %{id: "team-ev-max-2", strategy: "team_ev", max_published: 2, min_score: 1.4}

  defp policy("team-ev-max-3"),
    do: %{id: "team-ev-max-3", strategy: "team_ev", max_published: 3, min_score: 1.4}

  defp policy(other), do: raise(ArgumentError, "unknown Martian parity policy #{inspect(other)}")

  defp publish_claims(claims, %{strategy: "raw"}) do
    Enum.filter(claims, &(field(&1, :publish_decision, "publish") == "publish"))
  end

  defp publish_claims(claims, policy) do
    claims
    |> Enum.sort_by(&team_ev_score/1, :desc)
    |> Enum.with_index()
    |> Enum.filter(fn {claim, index} ->
      index < policy.max_published and team_ev_score(claim) >= policy.min_score
    end)
    |> Enum.map(fn {claim, _index} -> Map.put(claim, "publish_decision", "publish") end)
  end

  defp team_ev_score(claim) do
    confidence = field(claim, :confidence, 0.0) || 0.0
    confidence * severity_weight(field(claim, :severity, "low")) * agreement_count(claim)
  end

  defp severity_weight(severity) do
    %{"critical" => 4, "high" => 3, "medium" => 2, "low" => 1}
    |> Map.get(severity |> to_string() |> String.downcase(), 1)
  end

  defp agreement_count(claim), do: field(field(claim, :source, %{}), :agreement_count, 1) || 1

  defp review_comment(claim, created_at) do
    %{
      "path" => nullable_path(field(claim, :path)),
      "line" => field(claim, :start_line) || field(claim, :line),
      "body" => comment_body(claim),
      "created_at" => created_at
    }
  end

  defp candidate(claim) do
    %{
      "text" => candidate_text(claim),
      "path" => nullable_path(field(claim, :path)),
      "line" => field(claim, :start_line) || field(claim, :line),
      "source" => "sugary_claim",
      "claim_id" => field(claim, :id),
      "severity" => field(claim, :severity),
      "confidence" => field(claim, :confidence),
      "category" => field(claim, :category),
      "dedupe_key" => field(claim, :dedupe_key)
    }
  end

  defp review_entry(entry, export, tool, source_run, method_id, policy_id) do
    %{
      "tool" => tool,
      "repo_name" => "#{slug(Map.get(entry, "source_repo", "unknown"))}__sugary__local",
      "pr_url" => "local://sugary/#{export.case_id}",
      "review_comments" => export.comments,
      "sugary_metadata" => %{
        "source_run" => source_run,
        "method_id" => method_id,
        "policy_id" => policy_id || "raw-published",
        "raw_claims" => export.raw_claims,
        "published_claims" => export.published_claims
      }
    }
  end

  defp comment_body(claim) do
    [
      field(claim, :claim),
      evidence_text(claim),
      failure_path_text(claim),
      labeled_text("Suggested fix", field(claim, :suggested_fix)),
      labeled_text("Suggested test", field(claim, :suggested_test))
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp candidate_text(claim) do
    [field(claim, :claim), evidence_text(claim), failure_path_text(claim)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp evidence_text(claim) do
    claim
    |> field(:evidence, [])
    |> List.wrap()
    |> Enum.map(&field(&1, :summary))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> nil
      summaries -> "Evidence: " <> Enum.join(summaries, " ")
    end
  end

  defp failure_path_text(claim) do
    claim
    |> field(:failure_path, [])
    |> List.wrap()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> nil
      path -> "Failure path: " <> Enum.join(path, " -> ")
    end
  end

  defp labeled_text(_label, value) when value in [nil, ""], do: nil
  defp labeled_text(label, value), do: "#{label}: #{value}"

  defp nullable_path(path) when path in [nil, "", "unknown"], do: nil
  defp nullable_path(path), do: path

  defp summary(attrs) do
    total_candidates = attrs.exports |> Enum.map(&length(&1.candidates)) |> Enum.sum()
    credential_status = attrs.credentials

    %{
      id: attrs.id,
      generated_at: DateTime.utc_now() |> Calendar.strftime("%Y-%m-%dT%H:%M:%SZ"),
      source_run: attrs.source_run,
      method_id: attrs.method_id,
      tool: attrs.tool,
      policy_id: attrs.policy_id,
      cases_expected: attrs.limit,
      cases_exported: length(attrs.exports),
      cases_with_review_entry: length(attrs.exports),
      candidate_count: total_candidates,
      review_comment_count: total_candidates,
      martian_root: attrs.martian_root,
      martian_commit_sha: attrs.martian_commit_sha,
      benchmark_data_path: attrs.benchmark_data_path,
      candidates_path: attrs.candidates_path,
      dedup_groups_path: attrs.dedup_groups_path,
      model_dir: attrs.model_dir_name,
      credentials_present: credential_status.martian_api_key?,
      official_pipeline_status: official_pipeline_status(credential_status),
      no_submission: true,
      official_score_claim: false,
      out_dir: attrs.out_dir
    }
  end

  defp credentials(offline_dir) do
    %{
      martian_api_key?: env_or_dotenv?(offline_dir, "MARTIAN_API_KEY"),
      martian_model_configured?: env_or_dotenv?(offline_dir, "MARTIAN_MODEL"),
      martian_base_url_configured?: env_or_dotenv?(offline_dir, "MARTIAN_BASE_URL")
    }
  end

  defp official_pipeline_status(%{martian_api_key?: true}) do
    %{
      sugary_export: "complete",
      sugary_singleton_dedup: "complete",
      martian_step2_extract_comments: "ready_to_run",
      martian_step2_5_dedup_candidates: "ready_to_run",
      martian_step3_judge_comments: "ready_to_run",
      martian_dashboard: "ready_after_evaluations"
    }
  end

  defp official_pipeline_status(_credentials) do
    %{
      sugary_export: "complete",
      sugary_singleton_dedup: "complete",
      martian_step2_extract_comments: "blocked_missing_MARTIAN_API_KEY",
      martian_step2_5_dedup_candidates: "blocked_missing_MARTIAN_API_KEY",
      martian_step3_judge_comments: "blocked_missing_MARTIAN_API_KEY",
      martian_dashboard: "blocked_until_evaluations_exist"
    }
  end

  defp env_or_dotenv?(offline_dir, key) do
    System.get_env(key) not in [nil, ""] or dotenv_has_key?(Path.join(offline_dir, ".env"), key)
  end

  defp dotenv_has_key?(path, key) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.any?(fn line ->
        line = String.trim(line)
        String.starts_with?(line, "#{key}=") and not String.ends_with?(line, "=")
      end)
    else
      false
    end
  end

  defp render_report(summary) do
    status_rows =
      summary.official_pipeline_status
      |> Enum.map(fn {step, status} -> "| #{step} | #{status} |" end)
      |> Enum.join("\n")

    """
    # Martian Offline Parity Export

    Local-only parity artifact. This is not an official Martian score and was not submitted anywhere.

    ## Export

    - Tool: `#{summary.tool}`
    - Method: `#{summary.method_id}`
    - Policy: `#{summary.policy_id}`
    - Cases exported: #{summary.cases_exported}/#{summary.cases_expected}
    - Review comments/candidates: #{summary.candidate_count}
    - Martian commit: `#{summary.martian_commit_sha || "unknown"}`
    - Benchmark data: `#{summary.benchmark_data_path}`
    - Candidates: `#{summary.candidates_path}`
    - Dedup groups: `#{summary.dedup_groups_path}`

    ## Official Pipeline Status

    | Step | Status |
    | --- | --- |
    #{status_rows}

    The Sugary export wrote one Martian review entry per selected PR and wrote a model-local `candidates.json` plus singleton `dedup_groups.json`. The singleton groups are a local no-LLM dedup fallback; run Martian's official LLM dedup once `MARTIAN_API_KEY` is configured.

    ## Commands

    Run from the Martian `offline` directory:

    ```sh
    uv run python -m code_review_benchmark.step2_extract_comments --tool #{summary.tool} --force
    uv run python -m code_review_benchmark.step2_5_dedup_candidates --tool #{summary.tool} --force
    uv run python -m code_review_benchmark.step3_judge_comments --tool #{summary.tool} --dedup-groups results/#{summary.model_dir}/dedup_groups.json --force
    uv run python analysis/benchmark_dashboard.py
    ```

    No leaderboard claim should be made until the official local judge run completes and the resulting files are reviewed.
    """
  end

  defp git_sha(path) do
    case System.cmd("git", ["-C", path, "rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _other -> nil
    end
  end

  defp with_env(name, value, fun) do
    previous = System.get_env(name)
    System.put_env(name, value)

    try do
      fun.()
    after
      if previous in [nil, ""] do
        System.delete_env(name)
      else
        System.put_env(name, previous)
      end
    end
  end

  defp field(map, key, default \\ nil)

  defp field(%{} = map, key, default),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp field(_other, _key, default), do: default

  defp int(value) when is_integer(value), do: value
  defp int(value), do: value |> to_string() |> String.to_integer()

  defp slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp dash(key), do: key |> to_string() |> String.replace("_", "-")
end
