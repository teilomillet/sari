defmodule Sari.AppServer.ProtocolTest do
  use ExUnit.Case, async: true

  alias Sari.AppServer.Protocol
  alias Sari.{Json, RuntimeEvent}

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

  test "streaming turn path yields the turn response before notifications" do
    state = Protocol.new()

    {state, [thread_line]} =
      Protocol.handle_json_line_stream(
        state,
        ~s({"jsonrpc":"2.0","id":2,"method":"thread/start","params":{"cwd":"/tmp/work"}})
      )

    thread_id = get_in(decode!(thread_line), ["result", "thread", "id"])

    {_state, output_lines} =
      Protocol.handle_json_line_stream(
        state,
        ~s({"jsonrpc":"2.0","id":3,"method":"turn/start","params":{"threadId":"#{thread_id}","input":[{"type":"text","text":"hello"}]}})
      )

    [response_line | notification_lines] = Enum.to_list(output_lines)

    assert %{"id" => 3, "result" => %{"turn" => %{"id" => turn_id, "status" => "running"}}} =
             decode!(response_line)

    assert Enum.map(notification_lines, &decode!(&1)["method"]) == [
             "turn/started",
             "item/agentMessage/delta",
             "thread/tokenUsage/updated",
             "turn/completed"
           ]

    assert %{
             "method" => "turn/completed",
             "params" => %{"threadId" => ^thread_id, "turn" => %{"id" => ^turn_id}}
           } = notification_lines |> List.last() |> decode!()
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

  test "tool_started event maps to item/started notification" do
    state =
      Protocol.new(
        backend_opts: [
          events: [
            RuntimeEvent.new(:turn_started, %{input: "test"}),
            RuntimeEvent.new(:tool_started, %{
              id: "tool-abc",
              name: "bash",
              arguments: %{"command" => "ls"}
            }),
            RuntimeEvent.new(:turn_completed, %{result: "ok"})
          ]
        ]
      )

    {state, [thread_line]} =
      Protocol.handle_json_line(
        state,
        ~s({"jsonrpc":"2.0","id":1,"method":"thread/start","params":{"cwd":"/tmp"}})
      )

    thread_id = get_in(decode!(thread_line), ["result", "thread", "id"])

    {_state, output_lines} =
      Protocol.handle_json_line(
        state,
        ~s({"jsonrpc":"2.0","id":2,"method":"turn/start","params":{"threadId":"#{thread_id}","input":[]}})
      )

    decoded = Enum.map(output_lines, &decode!/1)
    item_started = Enum.find(decoded, &(&1["method"] == "item/started"))

    assert %{
             "method" => "item/started",
             "params" => %{
               "threadId" => ^thread_id,
               "item" => %{
                 "id" => "tool-abc",
                 "type" => "tool_call",
                 "name" => "bash",
                 "arguments" => %{"command" => "ls"}
               }
             }
           } = item_started
  end

  test "tool_output event maps to item/commandExecution/outputDelta notification" do
    state =
      Protocol.new(
        backend_opts: [
          events: [
            RuntimeEvent.new(:turn_started, %{input: "test"}),
            RuntimeEvent.new(:tool_output, %{
              tool_call_id: "tool-1",
              output: "file contents here"
            }),
            RuntimeEvent.new(:turn_completed, %{result: "ok"})
          ]
        ]
      )

    {state, [thread_line]} =
      Protocol.handle_json_line(
        state,
        ~s({"jsonrpc":"2.0","id":1,"method":"thread/start","params":{"cwd":"/tmp"}})
      )

    thread_id = get_in(decode!(thread_line), ["result", "thread", "id"])

    {_state, output_lines} =
      Protocol.handle_json_line(
        state,
        ~s({"jsonrpc":"2.0","id":2,"method":"turn/start","params":{"threadId":"#{thread_id}","input":[]}})
      )

    decoded = Enum.map(output_lines, &decode!/1)
    output_delta = Enum.find(decoded, &(&1["method"] == "item/commandExecution/outputDelta"))

    assert %{
             "method" => "item/commandExecution/outputDelta",
             "params" => %{
               "threadId" => ^thread_id,
               "itemId" => "tool-1",
               "delta" => "file contents here"
             }
           } = output_delta
  end

  test "approval_requested event maps to item/commandExecution/requestApproval notification" do
    state =
      Protocol.new(
        backend_opts: [
          events: [
            RuntimeEvent.new(:turn_started, %{input: "test"}),
            RuntimeEvent.new(:approval_requested, %{
              id: "appr-1",
              reason: "write to /etc",
              tool_call_id: "tool-xyz"
            }),
            RuntimeEvent.new(:turn_cancelled, %{reason: "user cancelled"})
          ]
        ]
      )

    {state, [thread_line]} =
      Protocol.handle_json_line(
        state,
        ~s({"jsonrpc":"2.0","id":1,"method":"thread/start","params":{"cwd":"/tmp"}})
      )

    thread_id = get_in(decode!(thread_line), ["result", "thread", "id"])

    {_state, output_lines} =
      Protocol.handle_json_line(
        state,
        ~s({"jsonrpc":"2.0","id":2,"method":"turn/start","params":{"threadId":"#{thread_id}","input":[]}})
      )

    decoded = Enum.map(output_lines, &decode!/1)

    approval =
      Enum.find(decoded, &(&1["method"] == "item/commandExecution/requestApproval"))

    assert %{
             "method" => "item/commandExecution/requestApproval",
             "params" => %{
               "threadId" => ^thread_id,
               "itemId" => "appr-1",
               "reason" => "write to /etc",
               "toolCallId" => "tool-xyz"
             }
           } = approval
  end

  test "unknown events still fall back to sari/event" do
    state =
      Protocol.new(
        backend_opts: [
          events: [
            RuntimeEvent.new(:turn_started, %{input: "test"}),
            RuntimeEvent.new(:reasoning_delta, %{text: "thinking..."}),
            RuntimeEvent.new(:turn_completed, %{result: "ok"})
          ]
        ]
      )

    {state, [thread_line]} =
      Protocol.handle_json_line(
        state,
        ~s({"jsonrpc":"2.0","id":1,"method":"thread/start","params":{"cwd":"/tmp"}})
      )

    thread_id = get_in(decode!(thread_line), ["result", "thread", "id"])

    {_state, output_lines} =
      Protocol.handle_json_line(
        state,
        ~s({"jsonrpc":"2.0","id":2,"method":"turn/start","params":{"threadId":"#{thread_id}","input":[]}})
      )

    decoded = Enum.map(output_lines, &decode!/1)
    sari_event = Enum.find(decoded, &(&1["method"] == "sari/event"))

    assert %{
             "method" => "sari/event",
             "params" => %{"type" => "reasoning_delta"}
           } = sari_event
  end

  defp decode!(line) do
    assert {:ok, decoded} = Json.decode(line)
    decoded
  end
end
