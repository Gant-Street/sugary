defmodule Sugary.Runner do
  alias Sugary.Protocol

  def init_research! do
    [
      ".sugary/research/sources/papers",
      ".sugary/research/claims",
      ".sugary/research/experiments",
      ".sugary/research/runs",
      ".sugary/research/campaigns",
      ".sugary/research/leaderboards",
      ".sugary/research/benchmarks"
    ]
    |> Enum.each(&File.mkdir_p!/1)

    :ok
  end

  def run_bench!(suite, method_id, opts \\ []) do
    method = Sugary.Methods.get!(method_id)
    cases = load_suite!(suite, opts)
    split = Keyword.get(opts, :split)

    manifest =
      Protocol.ExperimentManifest.new(%{
        id: "#{suite}-#{method_id}",
        suite: suite,
        split: split,
        methods: [method]
      })

    {run_dir, _method_reports, _cases} =
      run_experiment_with_reports!(manifest, Map.put(method, :id, method_id), cases)

    run_dir
  end

  def run_experiment_file!(path) do
    manifest = Sugary.Toml.parse_file!(path)
    run_experiment_manifest!(manifest)
  end

  def run_experiment_manifest!(%Protocol.ExperimentManifest{} = manifest) do
    cases =
      load_suite!(manifest.suite,
        split: manifest.split,
        limit: manifest.limit,
        offset: manifest.offset
      )

    {run_dir, _method_reports, _cases} = run_experiment_with_reports!(manifest, nil, cases)
    run_dir
  end

  def run_experiment_manifest_with_reports!(%Protocol.ExperimentManifest{} = manifest) do
    cases =
      load_suite!(manifest.suite,
        split: manifest.split,
        limit: manifest.limit,
        offset: manifest.offset
      )

    run_experiment_with_reports!(manifest, nil, cases)
  end

  def report!(run_dir) do
    report = Path.join(run_dir, "report.md")

    if File.exists?(report) do
      File.read!(report)
    else
      raise ArgumentError, "report not found at #{report}"
    end
  end

  defp run_experiment_with_reports!(manifest, single_method, cases) do
    init_research!()
    run_dir = make_run_dir(manifest.id)
    File.mkdir_p!(run_dir)
    Sugary.Json.write!(Path.join(run_dir, "manifest.json"), manifest)
    File.write!(Path.join(run_dir, "manifest.toml"), render_manifest(manifest))

    methods =
      case single_method do
        nil ->
          Enum.map(manifest.methods, &Sugary.Methods.from_manifest_method/1) ++
            Enum.map(manifest.reviewers || [], &Sugary.Methods.from_manifest_reviewer/1)

        method ->
          [method]
      end

    method_reports =
      methods
      |> Enum.map(&inherit_manifest_options(&1, manifest))
      |> Enum.map(fn method ->
        run_method!(run_dir, manifest, method, cases)
      end)

    Sugary.Json.write!(
      Path.join(run_dir, "scores.json"),
      Enum.map(method_reports, &%{method_id: &1.method.id, score: &1.score})
    )

    Sugary.Reporter.write_report!(run_dir, manifest, method_reports, cases)
    Sugary.PublicBenchmarks.write_public_smoke!(run_dir, manifest, method_reports, cases)
    {run_dir, method_reports, cases}
  end

  defp run_method!(run_dir, _manifest, method, cases) do
    if Map.get(method, :type) == "team" do
      run_team!(run_dir, method, cases)
    else
      run_single_method!(run_dir, method, cases)
    end
  end

  defp run_single_method!(run_dir, method, cases) do
    method_dir = Path.join(run_dir, method.id)
    File.mkdir_p!(method_dir)

    results =
      Enum.map(cases, fn bench_case ->
        result = Sugary.Pipeline.run_case(bench_case, method)
        write_case_artifacts!(run_dir, method_dir, method, result)
        result
      end)

    score = Sugary.Scorer.score(method.id, results)
    failures = Sugary.Scorer.failures(method.id, results)

    Sugary.Json.write!(Path.join(method_dir, "scores.json"), score)
    Sugary.Json.write!(Path.join(method_dir, "failures.json"), failures)

    append_jsonl!(Path.join(run_dir, "failures.jsonl"), failures)

    %{
      method: method,
      score: score,
      failures: failures,
      results: results
    }
  end

  defp run_team!(run_dir, method, cases) do
    method_dir = Path.join(run_dir, method.id)
    File.mkdir_p!(method_dir)

    results =
      Enum.map(cases, fn bench_case ->
        result = Sugary.Teams.run_case(bench_case, method)
        write_case_artifacts!(run_dir, method_dir, method, result)
        result
      end)

    score = Sugary.Scorer.score(method.id, results)
    failures = Sugary.Scorer.failures(method.id, results)
    contributions = Sugary.Teams.contributions(results, score)

    Sugary.Json.write!(Path.join(method_dir, "scores.json"), score)
    Sugary.Json.write!(Path.join(method_dir, "failures.json"), failures)
    Sugary.Teams.write_artifacts!(method_dir, method, results, score, contributions, failures)

    append_jsonl!(Path.join(run_dir, "failures.jsonl"), failures)

    %{
      method: method,
      score: score,
      failures: failures,
      results: results,
      team: %{
        contributions: contributions,
        team_scorecard: Sugary.Teams.team_scorecard(method.id, results, score, contributions)
      }
    }
  end

  defp write_case_artifacts!(run_dir, method_dir, method, result) do
    case_id = result.case.id
    Sugary.Json.write!(Path.join([method_dir, "input-bundles", "#{case_id}.json"]), result.input)

    Sugary.Json.write!(
      Path.join([method_dir, "reviewer-results", "#{case_id}.json"]),
      result.reviewer_result
    )

    Sugary.Json.write!(Path.join([method_dir, "claims", "#{case_id}.json"]), result.final_claims)
    final_review_path = Path.join([method_dir, "final-reviews", "#{case_id}.md"])
    final_review_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(final_review_path, render_final_review(result))
    write_adapter_artifact!(method_dir, case_id, result)

    aggregate_name = "#{method.id}--#{case_id}"

    Sugary.Json.write!(
      Path.join([run_dir, "input-bundles", "#{aggregate_name}.json"]),
      result.input
    )

    Sugary.Json.write!(
      Path.join([run_dir, "reviewer-results", "#{aggregate_name}.json"]),
      result.reviewer_result
    )

    Sugary.Json.write!(
      Path.join([run_dir, "claims", "#{aggregate_name}.json"]),
      result.final_claims
    )

    aggregate_review_path = Path.join([run_dir, "final-reviews", "#{aggregate_name}.md"])
    aggregate_review_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(aggregate_review_path, render_final_review(result))
    write_adapter_artifact!(run_dir, aggregate_name, result)
  end

  defp write_adapter_artifact!(dir, name, result) do
    case result.reviewer_result.artifacts do
      [] ->
        :ok

      artifacts ->
        Sugary.Json.write!(Path.join([dir, "adapter-artifacts", "#{name}.json"]), artifacts)
    end
  end

  defp render_final_review(result) do
    published = Enum.filter(result.final_claims, &(&1.publish_decision == "publish"))

    body =
      if published == [] do
        "No claims published."
      else
        published
        |> Enum.map(fn claim ->
          "- #{claim.claim}\n  Evidence: #{claim.evidence |> List.first(%{}) |> Map.get(:summary, "none")}"
        end)
        |> Enum.join("\n")
      end

    "# Final Review: #{result.case.id}\n\n#{body}\n"
  end

  defp append_jsonl!(path, records) do
    path |> Path.dirname() |> File.mkdir_p!()

    lines =
      records
      |> Enum.map(&(Sugary.Json.encode!(&1) <> "\n"))
      |> Enum.join()

    File.write!(path, lines, [:append])
  end

  defp load_suite!(suite, opts) when suite in ["martian-offline", "cr-bench"],
    do: Sugary.PublicBenchmarks.load_cases!(suite, opts)

  defp load_suite!(suite, opts) do
    limit = Keyword.get(opts, :limit)
    offset = Keyword.get(opts, :offset) || 0

    suite
    |> Sugary.Fixtures.load_suite!(opts)
    |> Enum.drop(offset)
    |> maybe_limit(limit)
  end

  defp make_run_dir(id) do
    timestamp =
      DateTime.utc_now()
      |> Calendar.strftime("%Y%m%dT%H%M%SZ")

    Path.join(".sugary/research/runs", "#{timestamp}-#{id}")
  end

  defp render_manifest(manifest) do
    methods =
      manifest.methods
      |> Enum.map(fn method ->
        """
        [[methods]]
        id = "#{method["id"] || method[:id]}"
        reviewer = "#{method["reviewer"] || method[:reviewer]}"
        team = "#{method["team"] || method[:team]}"
        context = "#{method["context"] || method[:context]}"
        candidate_generation = "#{method["candidate_generation"] || method[:candidate_generation]}"
        evidence = "#{method["evidence"] || method[:evidence]}"
        refutation = "#{method["refutation"] || method[:refutation]}"
        ranking = "#{method["ranking"] || method[:ranking]}"
        """
      end)
      |> Enum.join("\n")

    reviewers =
      (manifest.reviewers || [])
      |> Enum.map(fn reviewer ->
        """
        [[reviewers]]
        id = "#{reviewer["id"] || reviewer[:id]}"
        type = "#{reviewer["type"] || reviewer[:type]}"
        command = "#{reviewer["command"] || reviewer[:command]}"
        """
      end)
      |> Enum.join("\n")

    """
    id = "#{manifest.id}"
    description = "#{manifest.description || ""}"
    suite = "#{manifest.suite}"
    split = "#{manifest.split || ""}"
    limit = "#{manifest.limit || ""}"
    offset = "#{manifest.offset || ""}"
    replay_mode = "#{manifest.replay_mode || ""}"

    #{methods}
    #{reviewers}
    """
  end

  defp inherit_manifest_options(method, manifest) do
    case Map.get(method, :replay_mode) do
      nil ->
        if manifest.replay_mode in [nil, ""] do
          method
        else
          Map.put(method, :replay_mode, manifest.replay_mode)
        end

      _value ->
        method
    end
  end

  defp maybe_limit(cases, nil), do: cases
  defp maybe_limit(cases, ""), do: cases
  defp maybe_limit(cases, limit) when is_integer(limit), do: Enum.take(cases, limit)

  defp maybe_limit(cases, limit) when is_binary(limit),
    do: cases |> maybe_limit(String.to_integer(limit))
end
