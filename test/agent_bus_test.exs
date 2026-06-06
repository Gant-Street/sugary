defmodule Sugary.AgentBusTest do
  use ExUnit.Case

  test "local bus appends messages and reports counts" do
    root =
      Path.join(System.tmp_dir!(), "sugary-agent-bus-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)

    bus =
      Sugary.AgentBus.new!(
        id: "test-bus",
        requested_backend: "local-jsonl",
        root: root
      )

    Sugary.AgentBus.append!(bus, %{
      type: "REVIEW_REQUEST",
      from: "orchestrator",
      to: "sentinel",
      payload: %{focus_paths: ["lib/example.ex"]}
    })

    Sugary.AgentBus.append!(bus, %{
      type: "PUBLISH_DECISION",
      from: "orchestrator",
      to: "researcher",
      payload: %{published_claims: 1}
    })

    messages = Sugary.AgentBus.read!(bus)
    summary = Sugary.AgentBus.summary(bus)

    assert length(messages) == 2
    assert summary.effective_backend == "local-jsonl"
    assert summary.message_count == 2
    assert summary.message_counts_by_type["REVIEW_REQUEST"] == 1
    assert summary.message_counts_by_type["PUBLISH_DECISION"] == 1
  end

  test "auto backend falls back to local-jsonl when h5i is unavailable" do
    root =
      Path.join(System.tmp_dir!(), "sugary-agent-bus-auto-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)

    bus =
      Sugary.AgentBus.new!(
        id: "auto-bus",
        requested_backend: "auto",
        root: root
      )

    if System.find_executable("h5i") do
      assert bus.effective_backend == "h5i"
      assert bus.h5i_available == true
    else
      assert bus.effective_backend == "local-jsonl"
      assert bus.h5i_available == false
    end
  end
end
