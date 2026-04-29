defmodule Sari.EntractePr2Smoke do
  alias Sari.Json

  def run do
    backend = System.get_env("SARI_BACKEND") || "opencode_http"
    base_url = System.get_env("SARI_OPENCODE_BASE_URL") || "http://127.0.0.1:41887"
    workspace = System.get_env("SARI_ENTRACTE_WORKSPACE") || File.cwd!()
    prompt = System.get_env("SARI_ENTRACTE_PROMPT") || "Reply exactly: sari-app-server-ok"
    timeout_ms = System.get_env("SARI_ENTRACTE_TIMEOUT_MS", "180000") |> String.to_integer()
    code_path = Mix.Project.compile_path()
    elixir = System.find_executable("elixir") || raise "elixir executable not found"

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(elixir)},
        [
          :binary,
          :exit_status,
          args: [
            "-pa",
            code_path,
            "-e",
            """
            args = [
              "app-server",
              "--backend", #{inspect(backend)},
              "--event-timeout-ms", #{inspect(Integer.to_string(timeout_ms))},
              "--turn-timeout-ms", #{inspect(Integer.to_string(timeout_ms))}
            ]

            args =
              if #{inspect(backend)} in ["opencode", "opencode_http"] do
                args ++ ["--base-url", #{inspect(base_url)}]
              else
                args
              end

            Sari.CLI.main(args)
            """
          ],
          line: 1_000_000
        ]
      )

    started_at = System.monotonic_time(:millisecond)

    try do
      initialize = %{
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
      }

      send_json(port, initialize)
      initialize_response = recv_json!(port, timeout_ms)

      send_json(port, %{"jsonrpc" => "2.0", "method" => "initialized", "params" => %{}})

      send_json(port, %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "thread/start",
        "params" => %{
          "approvalPolicy" => "never",
          "sandbox" => "danger-full-access",
          "cwd" => workspace,
          "dynamicTools" => []
        }
      })

      thread_response = recv_json!(port, timeout_ms)
      thread_id = get_in(thread_response, ["result", "thread", "id"])

      send_json(port, %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "turn/start",
        "params" => %{
          "threadId" => thread_id,
          "input" => [%{"type" => "text", "text" => prompt}],
          "cwd" => workspace,
          "title" => "TEI-9: Sari Entr'acte PR2 smoke",
          "approvalPolicy" => "never",
          "sandboxPolicy" => %{"mode" => "danger-full-access"}
        }
      })

      turn_messages = collect_until_terminal!(port, timeout_ms, [])
      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      %{
        ok: terminal_ok?(turn_messages),
        elapsed_ms: elapsed_ms,
        initialize_backend: get_in(initialize_response, ["result", "capabilities", "backend"]),
        thread_id: thread_id,
        methods: Enum.map(turn_messages, &(&1["method"] || "response")),
        assistant_text: assistant_text(turn_messages),
        token_usage: token_usage(turn_messages),
        terminal: terminal_method(turn_messages)
      }
      |> Json.encode!()
      |> IO.puts()
    after
      if Port.info(port) do
        Port.close(port)
      end
    end
  end

  defp send_json(port, payload) do
    Port.command(port, Json.encode!(payload) <> "\n")
  end

  defp recv_json!(port, timeout_ms) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Json.decode(line) do
          {:ok, decoded} ->
            decoded

          {:error, reason} ->
            raise "invalid JSON from app-server: #{inspect(reason)} line=#{inspect(line)}"
        end

      {^port, {:data, {:noeol, line}}} ->
        raise "unexpected partial app-server line: #{inspect(line)}"

      {^port, {:exit_status, status}} ->
        raise "app-server exited early: #{status}"
    after
      timeout_ms -> raise "timeout waiting for app-server line"
    end
  end

  defp collect_until_terminal!(port, timeout_ms, acc) do
    message = recv_json!(port, timeout_ms)
    acc = [message | acc]

    if terminal_message?(message) do
      Enum.reverse(acc)
    else
      collect_until_terminal!(port, timeout_ms, acc)
    end
  end

  defp terminal_message?(%{"method" => method}) do
    method in ["turn/completed", "turn/failed", "turn/cancelled"]
  end

  defp terminal_message?(_message), do: false

  defp terminal_ok?(messages), do: terminal_method(messages) == "turn/completed"

  defp terminal_method(messages) do
    messages
    |> Enum.find_value(fn
      %{"method" => method} when method in ["turn/completed", "turn/failed", "turn/cancelled"] ->
        method

      _ ->
        nil
    end)
  end

  defp assistant_text(messages) do
    messages
    |> Enum.filter(&(&1["method"] == "item/agentMessage/delta"))
    |> Enum.map_join("", &get_in(&1, ["params", "delta"]))
  end

  defp token_usage(messages) do
    Enum.find_value(messages, fn
      %{"method" => "thread/tokenUsage/updated"} = message -> get_in(message, ["params", "usage"])
      _ -> nil
    end)
  end
end

Sari.EntractePr2Smoke.run()
