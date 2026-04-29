defmodule Sari.AppServer.ContractFixtureTest do
  use ExUnit.Case, async: true

  alias Sari.AppServer.Protocol
  alias Sari.{Json, RuntimeEvent}

  @fixtures Path.expand("../fixtures/app_server_contract", __DIR__)

  test "basic app-server session and turn contract matches golden JSON" do
    assert_fixture("basic", Protocol.new())
  end

  test "unknown thread failures match golden JSON" do
    assert_fixture("unknown_thread", Protocol.new())
  end

  test "tool, approval, and cancellation events match golden JSON" do
    assert_fixture(
      "tool_approval_cancel",
      Protocol.new(
        backend_opts: [
          events: [
            RuntimeEvent.new(:turn_started, %{input: "contract tools"}),
            RuntimeEvent.new(:tool_started, %{
              id: "tool-1",
              name: "read",
              arguments: %{"filePath" => "/tmp/a"}
            }),
            RuntimeEvent.new(:approval_requested, %{
              id: "approval-1",
              reason: "filesystem read",
              tool_call_id: "tool-1"
            }),
            RuntimeEvent.new(:turn_cancelled, %{reason: "contract cancellation"})
          ]
        ]
      )
    )
  end

  defp assert_fixture(name, state) do
    actual =
      name
      |> input_lines()
      |> Enum.reduce({state, []}, fn line, {state, outputs} ->
        {state, new_outputs} = Protocol.handle_json_line(state, line)
        {state, outputs ++ new_outputs}
      end)
      |> elem(1)
      |> Enum.map(&decode!/1)

    expected = name |> expected_lines() |> Enum.map(&decode!/1)

    assert actual == expected
  end

  defp input_lines(name), do: fixture_lines(name, "input")
  defp expected_lines(name), do: fixture_lines(name, "expected")

  defp fixture_lines(name, kind) do
    @fixtures
    |> Path.join("#{name}.#{kind}.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  defp decode!(line) do
    assert {:ok, decoded} = Json.decode(line)
    decoded
  end
end
