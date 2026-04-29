defmodule Sari.AppServer.CliTest do
  use ExUnit.Case, async: false

  alias Sari.Json

  @line_bytes 1_000_000

  test "sari app-server speaks line-buffered JSON-RPC over stdio" do
    port = start_cli_port()

    try do
      send_json(port, %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}})
      assert %{"id" => 1, "result" => %{"serverInfo" => %{"name" => "sari"}}} = recv_json(port)

      send_json(port, %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "thread/start",
        "params" => %{"cwd" => "/tmp/sari-cli-test"}
      })

      assert %{"id" => 2, "result" => %{"thread" => %{"id" => thread_id}}} = recv_json(port)

      send_json(port, %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "turn/start",
        "params" => %{
          "threadId" => thread_id,
          "input" => [%{"type" => "text", "text" => "hello"}]
        }
      })

      assert %{"id" => 3, "result" => %{"turn" => %{"id" => turn_id}}} = recv_json(port)

      methods =
        for _ <- 1..4 do
          recv_json(port)["method"]
        end

      assert methods == [
               "turn/started",
               "item/agentMessage/delta",
               "thread/tokenUsage/updated",
               "turn/completed"
             ]

      assert is_binary(turn_id)
    after
      close_port(port)
    end
  end

  test "sari app-server accepts explicit fake backend selection" do
    port = start_cli_port(["--backend", "fake"])

    try do
      send_json(port, %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}})

      assert %{
               "id" => 1,
               "result" => %{"capabilities" => %{"backend" => "fake"}}
             } = recv_json(port)
    after
      close_port(port)
    end
  end

  test "sari app-server accepts explicit Claude Code backend selection" do
    port = start_cli_port(["--backend", "claude_code_stream_json"])

    try do
      send_json(port, %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}})

      assert %{
               "id" => 1,
               "result" => %{"capabilities" => %{"backend" => "claude_code_stream_json"}}
             } = recv_json(port)
    after
      close_port(port)
    end
  end

  defp start_cli_port(args \\ []) do
    executable = System.find_executable("elixir") || flunk("elixir executable not found")
    code_path = Mix.Project.compile_path()
    cli_args = ["app-server" | args]

    Port.open(
      {:spawn_executable, String.to_charlist(executable)},
      [
        :binary,
        :exit_status,
        args: [
          "-pa",
          code_path,
          "-e",
          "Sari.CLI.main(#{inspect(cli_args)})"
        ],
        line: @line_bytes
      ]
    )
  end

  defp send_json(port, payload) do
    Port.command(port, Json.encode!(payload) <> "\n")
  end

  defp recv_json(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        assert {:ok, decoded} = Json.decode(line)
        decoded

      {^port, {:data, {:noeol, line}}} ->
        flunk("unexpected partial line from cli: #{inspect(line)}")

      {^port, {:exit_status, status}} ->
        flunk("cli exited before expected JSON response: #{status}")
    after
      2_000 -> flunk("timed out waiting for cli JSON response")
    end
  end

  defp close_port(port) do
    if Port.info(port) do
      Port.close(port)
    end
  rescue
    ArgumentError -> :ok
  end
end
