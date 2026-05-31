defmodule Sugary.PublicStaticProofGateTest do
  use ExUnit.Case

  alias Sugary.Protocol

  defp method, do: Sugary.Methods.get!("public-static-proof-gate")

  defp public_case(id, diff, expected_claims) do
    Protocol.BenchmarkCase.new(%{
      id: id,
      suite: "martian-offline",
      pr: %{title: "Public smoke fixture", body: ""},
      diff: diff,
      context: %{changed_files: []},
      public_benchmark: true,
      oracle: %{expectedClaims: expected_claims, knownNonIssues: []}
    })
  end

  test "emits proof-carrying static claims without oracle access" do
    bench_case =
      public_case(
        "public-proof-case-1",
        """
        diff --git a/app/assets/javascripts/discourse/lib/utilities.js b/app/assets/javascripts/discourse/lib/utilities.js
        -    var maxSizeKB = Discourse.SiteSettings['max_' + type + '_size_kb'];
        +    var maxSizeKB = 10 * 1024; // 10MB
        -          var maxSizeKB = Discourse.SiteSettings.max_image_size_kb;
        +          var maxSizeKB = 10 * 1024; // 10 MB
        diff --git a/app/models/optimized_image.rb b/app/models/optimized_image.rb
          def self.downsize(from, to, max_width, max_height, opts={})
        + def self.downsize(from, to, dimensions, opts={})
        +   optimize("downsize", from, to, dimensions, opts)
        + end
        """,
        [
          %{
            id: "martian-golden-1",
            description:
              "The downsize method is defined twice. The second definition expects a dimensions string and overrides the width and height API.",
            category: "public_benchmark",
            severity: "medium",
            path: "unknown"
          },
          %{
            id: "martian-golden-2",
            description:
              "Hardcoding maxSizeKB = 10 * 1024 ignores Discourse.SiteSettings max upload settings and can diverge from server-side limits.",
            category: "public_benchmark",
            severity: "low",
            path: "unknown"
          }
        ]
      )

    result = Sugary.Pipeline.run_case(bench_case, method())
    published = Enum.filter(result.final_claims, &(&1.publish_decision == "publish"))

    assert length(published) == 2
    assert Enum.all?(published, &(hd(&1.evidence).type == "static_diff_proof"))
    assert Enum.all?(published, &(&1.source.proof_gate == true))
    assert result.input.suite == "blind"
    refute result.input.metadata[:source_metadata]
  end

  test "scores static proof patterns as public benchmark hits" do
    cases = [
      public_case(
        "public-proof-case-1",
        """
        -    var maxSizeKB = Discourse.SiteSettings['max_' + type + '_size_kb'];
        +    var maxSizeKB = 10 * 1024; // 10MB
          def self.downsize(from, to, max_width, max_height, opts={})
        + def self.downsize(from, to, dimensions, opts={})
        """,
        [
          %{
            id: "duplicate-downsize",
            description:
              "The downsize method is defined twice, and the dimensions string definition overrides the older separate width and height API.",
            category: "public_benchmark",
            severity: "medium",
            path: "unknown"
          },
          %{
            id: "hardcoded-upload-limit",
            description:
              "Hardcoding maxSizeKB = 10 * 1024 ignores Discourse.SiteSettings upload limits.",
            category: "public_benchmark",
            severity: "low",
            path: "unknown"
          }
        ]
      ),
      public_case(
        "public-proof-case-2",
        ~S"""
        +  before_validation do
        +    self.host.sub!(/^https?:\\/\\//, '')
        +    self.host.sub!(/\\/.*$/, '')
        +  end
        +  execute "INSERT INTO embeddable_hosts (host, category_id) VALUES ('#{h}', #{category_id})"
        """,
        [
          %{
            id: "migration-normalization",
            description:
              "The migration inserts raw embeddable_hosts values through SQL without applying EmbeddableHost normalization that strips scheme and path segments.",
            category: "public_benchmark",
            severity: "high",
            path: "unknown"
          }
        ]
      ),
      public_case(
        "public-proof-case-3",
        """
        +    tu = TopicUser.find_by(user_id: current_user.id, topic_id: params[:topic_id])
        +    if tu.notification_level > TopicUser.notification_levels[:regular]
        +      tu.save!
        +    end
        """,
        [
          %{
            id: "topic-user-nil",
            description:
              "TopicUser.find_by can return nil, so reading tu.notification_level can crash for users without an existing TopicUser row.",
            category: "public_benchmark",
            severity: "high",
            path: "unknown"
          }
        ]
      )
    ]

    results = Enum.map(cases, &Sugary.Pipeline.run_case(&1, method()))
    score = Sugary.Scorer.score(method().id, results)

    assert score.hits == 4
    assert score.noise == 0
    assert score.published_claims == 4
    assert score.f1 == 1.0
  end

  test "scores static proof v2 patterns as public benchmark hits" do
    cases = [
      public_case(
        "public-proof-v2-sample-rate",
        ~S"""
        +    if client_sample_rate:
        +        try:
        +            normalized_data["sample_rate"] = float(client_sample_rate)
        +        except Exception:
        +            pass
        """,
        [
          %{
            id: "sample-rate-zero",
            description:
              "sample_rate = 0.0 is falsy and skipped when client_sample_rate is guarded with if client_sample_rate.",
            category: "public_benchmark",
            severity: "high",
            path: "unknown"
          }
        ]
      ),
      public_case(
        "public-proof-v2-retry-count",
        """
        +          await prisma.workflowReminder.update({
        +            data: {
        +              retryCount: reminder.retryCount + 1,
        +            },
        +          });
        """,
        [
          %{
            id: "retry-count-stale",
            description:
              "Using retryCount: reminder.retryCount + 1 reads a stale value and can lose increments under concurrency.",
            category: "public_benchmark",
            severity: "medium",
            path: "unknown"
          }
        ]
      ),
      public_case(
        "public-proof-v2-grafana-exec",
        """
        +  args = append([]interface{}{query}, args...)
        +  result, err := dbSession.Exec(args...)
        """,
        [
          %{
            id: "exec-interface-splat",
            description:
              "dbSession.Exec(args...) is given a []interface{} where Exec requires a string query first.",
            category: "public_benchmark",
            severity: "high",
            path: "unknown"
          }
        ]
      ),
      public_case(
        "public-proof-v2-keycloak-optional",
        """
        +  Optional<CredentialModel> credentialModelOpt = RecoveryAuthnCodesUtils.getCredential(user);
        +  RecoveryAuthnCodesCredentialModel recoveryCodeCredentialModel = RecoveryAuthnCodesCredentialModel.createFromCredentialModel(credentialModelOpt.get());
        """,
        [
          %{
            id: "optional-get",
            description:
              "Calling Optional.get() on RecoveryAuthnCodesUtils.getCredential(user) without checking isPresent can throw NoSuchElementException.",
            category: "public_benchmark",
            severity: "high",
            path: "unknown"
          }
        ]
      )
    ]

    results = Enum.map(cases, &Sugary.Pipeline.run_case(&1, method()))
    score = Sugary.Scorer.score(method().id, results)

    assert score.hits == 4
    assert score.noise == 0
    assert score.published_claims == 4
  end
end
