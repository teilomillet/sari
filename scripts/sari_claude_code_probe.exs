alias Sari.Backend.ClaudeCodeStreamJson
alias Sari.{Json, Runtime}

prompt = System.get_env("SARI_CLAUDE_PROMPT") || "Reply exactly: sari-claude-ok"
timeout_ms =
  System.get_env("SARI_CLAUDE_TURN_TIMEOUT_MS", "300000")
  |> String.to_integer()

opts =
  []
  |> then(fn opts ->
    case System.get_env("SARI_CLAUDE_EXECUTABLE") do
      nil -> opts
      "" -> opts
      executable -> Keyword.put(opts, :executable, executable)
    end
  end)
  |> then(fn opts ->
    case System.get_env("SARI_CLAUDE_MODEL") do
      nil -> opts
      "" -> opts
      model -> Keyword.put(opts, :model, model)
    end
  end)
  |> then(fn opts ->
    case System.get_env("SARI_CLAUDE_PERMISSION_MODE") do
      nil -> opts
      "" -> opts
      mode -> Keyword.put(opts, :permission_mode, mode)
    end
  end)
  |> then(fn opts ->
    case System.get_env("SARI_CLAUDE_TOOLS") do
      nil -> opts
      tools -> Keyword.put(opts, :tools, tools)
    end
  end)
  |> Keyword.put(:turn_timeout_ms, timeout_ms)

started_at = System.monotonic_time(:millisecond)

with {:ok, session} <-
       Runtime.start_session(ClaudeCodeStreamJson, %{title: "Sari Claude Code real", cwd: File.cwd!()}, opts),
     {:ok, run} <-
       Runtime.collect_turn(
         ClaudeCodeStreamJson,
         session,
         prompt,
         Keyword.put(opts, :turn_id, "claude-code-real")
       ) do
  elapsed_ms = System.monotonic_time(:millisecond) - started_at

  %{
    ok: run.terminal.type == :turn_completed,
    session_id: session.id,
    elapsed_ms: elapsed_ms,
    terminal: run.terminal.type,
    assistant_text:
      run.events
      |> Enum.filter(&(&1.type == :assistant_delta))
      |> Enum.map_join("", &(Map.get(&1.payload, :text) || Map.get(&1.payload, "text") || "")),
    token_usage:
      run.events
      |> Enum.filter(&(&1.type == :token_usage))
      |> List.last()
      |> case do
        nil -> nil
        event -> event.payload
      end,
    events:
      Enum.map(run.events, fn event ->
        %{
          type: event.type,
          payload: event.payload
        }
      end)
  }
  |> Json.encode!()
  |> IO.puts()
else
  {:error, reason} ->
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    %{
      ok: false,
      elapsed_ms: elapsed_ms,
      error: inspect(reason)
    }
    |> Json.encode!()
    |> IO.puts()

    System.halt(1)
end
