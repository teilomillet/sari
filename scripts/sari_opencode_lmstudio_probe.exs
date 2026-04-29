alias Sari.Backend.OpenCodeHttp
alias Sari.{Json, Runtime}

base_url = System.get_env("SARI_OPENCODE_BASE_URL") || "http://127.0.0.1:41887"
prompt = System.get_env("SARI_OPENCODE_PROMPT") || "Reply exactly: sari-adapter-ok"
timeout_ms =
  System.get_env("SARI_OPENCODE_EVENT_TIMEOUT_MS", "120000")
  |> String.to_integer()

started_at = System.monotonic_time(:millisecond)

with {:ok, session} <-
       Runtime.start_session(OpenCodeHttp, %{title: "Sari LM Studio real", cwd: File.cwd!()},
         base_url: base_url
       ),
     {:ok, run} <-
       Runtime.collect_turn(OpenCodeHttp, session, prompt,
         base_url: base_url,
         turn_id: "lmstudio-real",
         event_timeout_ms: timeout_ms
       ) do
  elapsed_ms = System.monotonic_time(:millisecond) - started_at

  %{
    ok: true,
    session_id: session.id,
    elapsed_ms: elapsed_ms,
    terminal: run.terminal.type,
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
