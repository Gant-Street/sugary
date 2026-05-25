defmodule Sugary.PublicBenchmarks do
  alias Sugary.Protocol.BenchmarkCase

  @adapter_version "public-benchmark-bridge-v0"

  @registry %{
    "martian-offline" => %{
      adapter: "local-smoke",
      notes: "unofficial local scoring",
      module: Sugary.Martian
    },
    "cr-bench" => %{
      adapter: "local-smoke",
      notes: "unofficial local scoring",
      module: Sugary.CRBench
    },
    "c-crab" => %{
      adapter: "none",
      notes: "not implemented in v0",
      module: nil,
      planned: true
    }
  }

  def adapter_version, do: @adapter_version

  def list do
    @registry
    |> Enum.map(fn {id, info} ->
      status =
        cond do
          info[:planned] -> "planned"
          locate(id) != nil -> "available"
          true -> "missing"
        end

      %{
        benchmark: id,
        status: status,
        adapter: info.adapter,
        notes: info.notes
      }
    end)
    |> Enum.sort_by(& &1.benchmark)
  end

  def render_list(rows) do
    body =
      rows
      |> Enum.map(fn row ->
        "#{pad(row.benchmark, 18)} #{pad(row.status, 12)} #{pad(row.adapter, 13)} #{row.notes}"
      end)
      |> Enum.join("\n")

    "Benchmark          Status       Adapter       Notes\n" <> body
  end

  def fetch(suite, opts \\ []) do
    module!(suite).fetch(opts)
  end

  def locate("martian-offline"), do: Sugary.Martian.locate()
  def locate("cr-bench"), do: Sugary.CRBench.locate()
  def locate(_suite), do: nil

  def list_cases(suite, opts \\ []) do
    suite
    |> module!()
    |> apply(:list_cases, [opts])
  end

  def load_cases!(suite, opts \\ []) do
    case list_cases(suite, opts) do
      {:ok, cases} -> cases
      {:error, message} -> raise ArgumentError, message
    end
  end

  def inspect_cases(suite, opts \\ []) do
    suite
    |> load_cases!(opts)
    |> Enum.map(&case_summary/1)
  end

  def normalize_case(suite, path, raw, source_root, index) do
    decoded = decode_case(raw)
    original_id = text_field(decoded, ["id", "case_id", "pull_request_id"]) || Path.basename(path)
    repo = text_field(decoded, ["repo", "repository", "project"]) || "unknown"
    pr = map_field(decoded, "pr") || %{}
    title = text_field(pr, ["title"]) || text_field(decoded, ["title"]) || "#{suite} smoke case"

    body =
      text_field(pr, ["body", "description"]) || text_field(decoded, ["body", "description"]) ||
        ""

    diff = text_field(decoded, ["diff", "patch", "changes"]) || raw
    expected = expected_claims(decoded)
    known_non_issues = known_non_issues(decoded)
    source_commit = git_sha(source_root)
    now = DateTime.utc_now() |> Calendar.strftime("%Y-%m-%dT%H:%M:%SZ")

    BenchmarkCase.new(%{
      id: "#{suite}-#{index}-#{slug(original_id)}",
      suite: suite,
      pr: %{title: title, body: body, original_id: original_id},
      diff: diff,
      context: %{allowed: %{changed_files: changed_files(decoded), benchmark: suite}},
      repo: %{name: repo, source_path: path},
      oracle: %{expectedClaims: expected, knownNonIssues: known_non_issues},
      tags: ["public-smoke", suite],
      public_benchmark: true,
      source_metadata: %{
        benchmark: suite,
        source_url: source_url(suite),
        source_path: source_root,
        source_commit_sha: source_commit,
        original_case_id: original_id,
        repo: repo,
        pr: pr,
        license_note: license_note(suite),
        normalization_timestamp: now,
        adapter_version: @adapter_version,
        source_file: path
      }
    })
  end

  def normalize_files(files, suite, source_root, limit) do
    files
    |> Enum.flat_map(&file_records/1)
    |> Enum.with_index(1)
    |> Enum.take(limit)
    |> Enum.map(fn {{path, raw}, index} ->
      normalize_case(suite, path, raw, source_root, index)
    end)
  end

  def leakage_report(run_dir, cases) do
    case_ids = Enum.map(cases, &source_case_id/1)

    input_leaks =
      run_dir
      |> Path.join("input-bundles/*.json")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        body = File.read!(path)
        Enum.filter(case_ids, &(is_binary(&1) and &1 != "" and String.contains?(body, &1)))
      end)
      |> Enum.uniq()
      |> Enum.sort()

    oracle_leaks =
      run_dir
      |> Path.join("input-bundles/*.json")
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        body = File.read!(path)

        String.contains?(body, "expectedClaims") or String.contains?(body, "gold") or
          String.contains?(body, "oracle")
      end)

    %{
      fatal?: input_leaks != [] or oracle_leaks != [],
      input_case_id_leaks: input_leaks,
      oracle_input_files: oracle_leaks,
      warnings: []
    }
  end

  def write_public_smoke!(run_dir, manifest, method_reports, cases) do
    if public_suite?(manifest.suite) do
      public_dir = Path.join(".sugary/research/public-smoke", Path.basename(run_dir))
      File.rm_rf!(public_dir)
      File.mkdir_p!(public_dir)

      copy_public_artifacts!(run_dir, public_dir)
      write_metadata!(public_dir, manifest, cases)

      leakage = leakage_report(run_dir, cases)
      Sugary.Json.write!(Path.join(public_dir, "leakage-report.json"), leakage)

      File.write!(
        Path.join(public_dir, "public-smoke-report.md"),
        render_public_report(manifest, method_reports, cases, leakage)
      )

      public_dir
    else
      nil
    end
  end

  def public_suite?(suite), do: suite in ["martian-offline", "cr-bench"]

  def compare(run_dirs) do
    run_dirs
    |> Enum.map(&summarize_run/1)
  end

  def render_compare(summaries) do
    rows =
      summaries
      |> Enum.map(fn summary ->
        best = summary.best || %{}

        "| #{summary.run} | #{summary.suite} | #{best["method_id"] || "none"} | #{fmt(get_in(best, ["score", "f1"]))} | #{fmt(get_in(best, ["score", "usefulness"]))} | #{fmt(get_in(best, ["score", "snr"]))} | #{summary.warning} |"
      end)
      |> Enum.join("\n")

    """
    # Benchmark Comparison

    | Run | Suite | Best Method | F1 | Usefulness | SNR | Warning |
    | --- | --- | --- | --- | --- | --- | --- |
    #{rows}

    This comparison is local and unofficial. It is meant to expose transfer gaps, category gaps, noise gaps, reviewer ranking changes, and brittle local promotions.
    """
  end

  defp module!(suite) do
    case @registry[suite] do
      %{module: nil} ->
        raise ArgumentError, "benchmark #{suite} is planned but not implemented in v0"

      %{module: module} ->
        module

      nil ->
        raise ArgumentError, "unknown public benchmark #{inspect(suite)}"
    end
  end

  defp case_summary(%BenchmarkCase{} = bench_case) do
    %{
      id: bench_case.id,
      suite: bench_case.suite,
      title: bench_case.pr[:title] || bench_case.pr["title"],
      source_metadata: bench_case.source_metadata,
      expected_claims: length(Map.get(bench_case.oracle, :expectedClaims, []))
    }
  end

  defp decode_case(raw) do
    Sugary.Json.decode!(raw)
  rescue
    _error -> %{"diff" => raw, "id" => :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)}
  end

  defp file_records(path) do
    raw = File.read!(path)

    if Path.extname(path) == ".jsonl" do
      raw
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.with_index(1)
      |> Enum.map(fn {line, index} -> {"#{path}##{index}", line} end)
    else
      [{path, raw}]
    end
  end

  defp expected_claims(decoded) do
    decoded
    |> first_list([
      "expectedClaims",
      "expected_claims",
      "golden_comments",
      "gold_comments",
      "comments",
      "labels"
    ])
    |> Enum.with_index(1)
    |> Enum.map(fn {claim, index} ->
      claim = if is_map(claim), do: claim, else: %{"description" => to_string(claim)}

      %{
        id: text_field(claim, ["id"]) || "public-expected-#{index}",
        description:
          text_field(claim, ["description", "comment", "body", "summary"]) ||
            "Expected public benchmark finding",
        category: text_field(claim, ["category", "type"]) || "public_benchmark",
        severity: text_field(claim, ["severity"]) || "medium",
        path: text_field(claim, ["path", "file"]) || "unknown",
        line: int_field(claim, ["line", "start_line"]) || 1,
        difficulty: text_field(claim, ["difficulty"]) || "unknown",
        specialist: text_field(claim, ["specialist"]) || "public_benchmark",
        required_context: first_list(claim, ["required_context"])
      }
    end)
  end

  defp known_non_issues(decoded) do
    decoded
    |> first_list(["knownNonIssues", "known_non_issues", "non_issues"])
    |> Enum.with_index(1)
    |> Enum.map(fn {claim, index} ->
      claim = if is_map(claim), do: claim, else: %{"description" => to_string(claim)}

      %{
        id: text_field(claim, ["id"]) || "public-non-issue-#{index}",
        description:
          text_field(claim, ["description", "comment", "body", "summary"]) ||
            "Known public benchmark non-issue",
        trapCategory: text_field(claim, ["trapCategory", "category"]) || "public_non_issue",
        path: text_field(claim, ["path", "file"]) || "unknown"
      }
    end)
  end

  defp changed_files(decoded) do
    first_list(decoded, ["changed_files", "files"])
    |> Enum.map(fn
      %{} = file -> text_field(file, ["path", "filename", "file"]) || "unknown"
      file -> to_string(file)
    end)
  end

  defp text_field(map, keys) when is_map(map) do
    keys
    |> Enum.find_value(fn key ->
      case fetch_field(map, key) do
        value when is_binary(value) -> value
        value when is_integer(value) -> to_string(value)
        _ -> nil
      end
    end)
  end

  defp text_field(_map, _keys), do: nil

  defp int_field(map, keys) when is_map(map) do
    keys
    |> Enum.find_value(fn key ->
      case fetch_field(map, key) do
        value when is_integer(value) -> value
        value when is_binary(value) -> parse_int(value)
        _ -> nil
      end
    end)
  end

  defp int_field(_map, _keys), do: nil

  defp map_field(map, key) when is_map(map) do
    case fetch_field(map, key) do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp first_list(map, keys) when is_map(map) do
    keys
    |> Enum.find_value([], fn key ->
      case fetch_field(map, key) do
        list when is_list(list) -> list
        _ -> nil
      end
    end)
  end

  defp first_list(_map, _keys), do: []

  defp fetch_field(map, key) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {map_key, value} when is_atom(map_key) ->
          if Atom.to_string(map_key) == key, do: value

        _other ->
          nil
      end)
  end

  defp parse_int(value) do
    case Integer.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp source_url("martian-offline"), do: "https://github.com/withmartian/code-review-benchmark"
  defp source_url("cr-bench"), do: "https://arxiv.org/abs/2603.11078"
  defp source_url(_), do: ""

  defp license_note("martian-offline"),
    do: "Use according to the local benchmark repository license."

  defp license_note("cr-bench"), do: "Use according to the local CR-Bench data license."
  defp license_note(_), do: ""

  defp git_sha(path) do
    case System.cmd("git", ["-C", path, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "case"
      slug -> slug
    end
  end

  defp source_case_id(bench_case),
    do: get_in(bench_case.source_metadata || %{}, [:original_case_id])

  defp copy_public_artifacts!(run_dir, public_dir) do
    mapping = [
      {"input-bundles", "input-bundles"},
      {"reviewer-results", "reviewer-results"},
      {"final-reviews", "final-reviews"},
      {"manifest.json", "manifest.json"},
      {"scores.json", "scores.json"},
      {"failures.jsonl", "failures.jsonl"}
    ]

    Enum.each(mapping, fn {source, dest} ->
      source_path = Path.join(run_dir, source)
      dest_path = Path.join(public_dir, dest)

      cond do
        File.dir?(source_path) -> File.cp_r!(source_path, dest_path)
        File.exists?(source_path) -> File.cp!(source_path, dest_path)
        true -> :ok
      end
    end)
  end

  defp write_metadata!(public_dir, manifest, cases) do
    Sugary.Json.write!(Path.join(public_dir, "benchmark-metadata.json"), %{
      suite: manifest.suite,
      adapter_version: @adapter_version,
      unofficial: true,
      warning: "Unofficial local smoke run. Not an official benchmark score.",
      cases: Enum.map(cases, & &1.source_metadata)
    })

    cases_dir = Path.join(public_dir, "normalized-cases")
    File.mkdir_p!(cases_dir)
    Enum.each(cases, &Sugary.Json.write!(Path.join(cases_dir, "#{&1.id}.json"), &1))
  end

  defp render_public_report(manifest, method_reports, cases, leakage) do
    best =
      Enum.max_by(method_reports, &{&1.score.f1, &1.score.usefulness, &1.score.snr}, fn -> nil end)

    rows =
      method_reports
      |> Enum.map(fn report ->
        "| #{report.method.id} | #{fmt(report.score.recall)} | #{fmt(report.score.usefulness)} | #{fmt(report.score.snr)} | #{fmt(report.score.f1)} | #{report.score.noise} |"
      end)
      |> Enum.join("\n")

    failures =
      method_reports
      |> Enum.flat_map(& &1.failures)
      |> Enum.group_by(& &1.category)
      |> Enum.map(fn {category, values} -> "- #{category}: #{length(values)}" end)
      |> Enum.join("\n")

    source_rows =
      cases
      |> Enum.take(5)
      |> Enum.map(fn bench_case ->
        metadata = bench_case.source_metadata || %{}

        "| #{bench_case.id} | #{metadata[:original_case_id]} | #{metadata[:repo]} | #{metadata[:source_commit_sha] || "n/a"} |"
      end)
      |> Enum.join("\n")

    """
    # Public Smoke Report: #{manifest.id}

    Unofficial local smoke run. Not an official benchmark score.

    Suite: `#{manifest.suite}`
    Adapter version: `#{@adapter_version}`
    Cases: #{length(cases)}

    ## Summary

    - Best method: #{if best, do: best.method.id, else: "none"}
    - Promoted local candidate transfer visible: #{transfer_summary(method_reports)}
    - Leakage fatal: #{leakage.fatal?}
    - Too small or unofficial to interpret as a benchmark claim: yes

    | Method | Recall | Usefulness | SNR | F1 | Noise |
    | --- | --- | --- | --- | --- | --- |
    #{rows}

    ## Failure Clusters

    #{if failures == "", do: "- none", else: failures}

    ## Source Metadata

    Full source metadata is written to `benchmark-metadata.json`.

    | Normalized Case | Original Case | Repo | Source Commit |
    | --- | --- | --- | --- |
    #{source_rows}

    ## Next Research Loop

    Use public smoke failures to redesign local fixtures, reviewer context retrieval, evidence construction, external normalization, or category specialists. Do not submit or claim official scores from this report.
    """
  end

  defp transfer_summary(method_reports) do
    method_reports
    |> Enum.find(&(&1.method.id in ["promoted-local-candidate", "hard-specialist-team"]))
    |> case do
      nil -> "not measured"
      report -> if report.score.hits > 0, do: "some hits", else: "no hits"
    end
  end

  defp summarize_run(run_dir) do
    scores = read_json(Path.join(run_dir, "scores.json")) || []
    manifest = read_json(Path.join(run_dir, "manifest.json")) || %{}
    best = Enum.max_by(scores, &score_tuple/1, fn -> nil end)

    %{
      run: run_dir,
      suite: manifest["suite"] || "unknown",
      best: best,
      warning: if(String.contains?(run_dir, "public-smoke"), do: "unofficial", else: "local")
    }
  end

  defp score_tuple(%{"score" => score}),
    do: {score["f1"] || 0, score["usefulness"] || 0, score["snr"] || 0}

  defp score_tuple(_), do: {0, 0, 0}

  defp read_json(path), do: if(File.exists?(path), do: Sugary.Json.read!(path), else: nil)

  defp fmt(nil), do: "n/a"
  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp fmt(value), do: to_string(value)

  defp pad(value, size) do
    value = to_string(value)
    value <> String.duplicate(" ", max(size - String.length(value), 1))
  end
end
