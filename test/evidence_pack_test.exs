defmodule Sugary.EvidencePackTest do
  use ExUnit.Case

  alias Sugary.Protocol

  test "builds evidence pack from diff and workspace without oracle fields" do
    root = tmp_dir("evidence-pack")
    head = Path.join(root, "head")
    base = Path.join(root, "base")

    File.mkdir_p!(Path.join(head, "src"))
    File.mkdir_p!(Path.join(base, "src"))

    File.write!(Path.join(head, "src/app.ts"), "export function app() {\n  return 2\n}\n")
    File.write!(Path.join(base, "src/app.ts"), "export function app() {\n  return 1\n}\n")
    File.write!(Path.join(head, "package.json"), ~s({"name":"example"}))

    bench_case =
      Protocol.BenchmarkCase.new(%{
        id: "public-case-secret",
        suite: "aacr-bench",
        pr: %{title: "Test", body: ""},
        diff: """
        diff --git a/src/app.ts b/src/app.ts
        index 0000000..1111111 100644
        --- a/src/app.ts
        +++ b/src/app.ts
        @@ -1,3 +1,3 @@
         export function app() {
        -  return 1
        +  return 2
         }
        """,
        context: %{allowed: %{changed_files: ["src/app.ts"]}},
        repo: %{workspace: %{head: head, base: base}},
        oracle: %{
          expectedClaims: [%{id: "oracle-claim", description: "hidden expected claim"}],
          knownNonIssues: []
        },
        public_benchmark: true
      })

    pack = Sugary.EvidencePack.build(bench_case, %{include_evidence_pack: true})
    encoded = Sugary.Json.encode!(pack)

    assert pack.oracle_included == false
    assert pack.stats.sections > 0
    assert encoded =~ "src/app.ts"
    refute encoded =~ "hidden expected claim"
    refute encoded =~ "public-case-secret"

    File.rm_rf!(root)
  end

  test "classifies broad AACR-style claim types" do
    assert Sugary.EvidencePack.classify_claim_type(%{
             category: "Maintainability and Readability",
             description: "extract duplicate validation"
           }) == "maintainability"

    assert Sugary.EvidencePack.classify_claim_type(%{
             category: "Code Defect",
             description: "translation key mismatch in i18n config"
           }) == "contract"
  end

  defp tmp_dir(name) do
    Path.join(System.tmp_dir!(), "sugary-#{name}-#{System.unique_integer([:positive])}")
  end
end
