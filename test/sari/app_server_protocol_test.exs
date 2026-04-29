defmodule Sari.AppServer.ProtocolTest do
  use ExUnit.Case, async: true

  alias Sari.AppServer.Protocol
  alias Sari.Json

  test "handles initialize as a JSON-RPC response" do
    state = Protocol.new()

    {_state, [line]} =
      Protocol.handle_json_line(
        state,
        ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}})
      )

    assert %{
             "id" => 1,
             "result" => %{
               "serverInfo" => %{"name" => "sari"},
               "capabilities" => %{"backend" => "fake", "transport" => "in_memory"}
             }
           } = decode!(line)
  end

  test "starts a thread and returns an Entr'acte-compatible thread payload" do
    state = Protocol.new()

    {state, [line]} =
      Protocol.handle_json_line(
        state,
        ~s({"jsonrpc":"2.0","id":2,"method":"thread/start","params":{"cwd":"/tmp/work"}})
      )

    assert %{
             "id" => 2,
             "result" => %{
               "thread" => %{"id" => thread_id, "status" => "ready"},
               "cwd" => "/tmp/work"
             }
           } = decode!(line)

    assert Map.has_key?(state.sessions, thread_id)
  end

  test "starts a turn, responds first, and emits normalized app-server notifications" do
    state = Protocol.new()

    {state, [thread_line]} =
      Protocol.handle_json_line(
        state,
        ~s({"jsonrpc":"2.0","id":2,"method":"thread/start","params":{"cwd":"/tmp/work"}})
      )

    thread_id = get_in(decode!(thread_line), ["result", "thread", "id"])

    {_state, output_lines} =
      Protocol.handle_json_line(
        state,
        ~s({"jsonrpc":"2.0","id":3,"method":"turn/start","params":{"threadId":"#{thread_id}","input":[{"type":"text","text":"hello"}]}})
      )

    decoded = Enum.map(output_lines, &decode!/1)

    assert %{"id" => 3, "result" => %{"turn" => %{"id" => turn_id, "status" => "running"}}} =
             List.first(decoded)

    assert Enum.map(tl(decoded), & &1["method"]) == [
             "turn/started",
             "item/agentMessage/delta",
             "thread/tokenUsage/updated",
             "turn/completed"
           ]

    assert %{
             "method" => "turn/completed",
             "params" => %{
               "threadId" => ^thread_id,
               "turn" => %{"id" => ^turn_id, "status" => "completed"}
             }
           } = List.last(decoded)
  end

  test "accepts Entr'acte PR2 app-server request shape with policy and workspace fields" do
    state = Protocol.new()

    {state, [initialize_line]} =
      Protocol.handle_json_line(
        state,
        Json.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "capabilities" => %{"experimentalApi" => true},
            "clientInfo" => %{
              "name" => "symphony-orchestrator",
              "title" => "Symphony Orchestrator",
              "version" => "0.1.0"
            }
          }
        })
      )

    assert %{"id" => 1, "result" => %{"serverInfo" => %{"name" => "sari"}}} =
             decode!(initialize_line)

    {state, []} =
      Protocol.handle_json_line(
        state,
        Json.encode!(%{"jsonrpc" => "2.0", "method" => "initialized", "params" => %{}})
      )

    {state, [thread_line]} =
      Protocol.handle_json_line(
        state,
        Json.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "thread/start",
          "params" => %{
            "approvalPolicy" => "never",
            "sandbox" => "danger-full-access",
            "cwd" => "/tmp/sari-entracte-pr2",
            "dynamicTools" => []
          }
        })
      )

    thread_id = get_in(decode!(thread_line), ["result", "thread", "id"])

    {_state, output_lines} =
      Protocol.handle_json_line(
        state,
        Json.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "turn/start",
          "params" => %{
            "threadId" => thread_id,
            "input" => [%{"type" => "text", "text" => "Reply exactly: sari-ok"}],
            "cwd" => "/tmp/sari-entracte-pr2",
            "title" => "TEI-9: adapter smoke",
            "approvalPolicy" => "never",
            "sandboxPolicy" => %{"mode" => "danger-full-access"}
          }
        })
      )

    decoded = Enum.map(output_lines, &decode!/1)

    assert %{"id" => 3, "result" => %{"turn" => %{"status" => "running"}}} =
             List.first(decoded)

    assert Enum.map(tl(decoded), & &1["method"]) == [
             "turn/started",
             "item/agentMessage/delta",
             "thread/tokenUsage/updated",
             "turn/completed"
           ]
  end

  test "fails closed when a turn references an unknown thread" do
    state = Protocol.new()

    {_state, [line]} =
      Protocol.handle_json_line(
        state,
        ~s({"jsonrpc":"2.0","id":3,"method":"turn/start","params":{"threadId":"missing","input":[]}})
      )

    assert %{
             "id" => 3,
             "error" => %{
               "code" => "unknown_thread",
               "message" => "thread not found: \"missing\""
             }
           } = decode!(line)
  end

  test "fails closed on malformed JSON input" do
    {_state, [line]} = Protocol.handle_json_line(Protocol.new(), "{")

    assert %{"id" => nil, "error" => %{"code" => "parse_error"}} = decode!(line)
  end

  defp decode!(line) do
    assert {:ok, decoded} = Json.decode(line)
    decoded
  end
end
