defmodule Sari.Backend.ClaudeCodeStreamJson do
  @moduledoc """
  Claude Code stream-json runtime adapter.

  Verified upstream surface:

    * `claude -p` runs non-interactively.
    * `--output-format stream-json` emits machine-readable streaming output.
    * `--include-partial-messages` emits raw streaming deltas.
    * `--include-hook-events` and hooks expose lifecycle information.
    * `--permission-prompt-tool` can route non-interactive permission prompts
      through MCP.
    * `--session-id` and `--resume` provide session identity.

  This first adapter uses a one-shot Claude Code process per turn. That is an
  intentional fit for Sari's current backend behaviour, which does not yet have
  a `stop_session` callback for cleaning up resident backend processes.
  """

  @behaviour Sari.RuntimeBackend

  import Bitwise, only: [band: 2, bor: 2]

  alias Sari.{Json, RuntimeCapabilities, RuntimeError, RuntimeEvent, Session}

  @default_turn_timeout_ms 300_000
  @default_max_events 2_000
  @active_turns_table __MODULE__.ActiveTurns

  @impl true
  def capabilities(opts \\ []) do
    %RuntimeCapabilities{
      backend: :claude_code_stream_json,
      name: "Claude Code stream-json",
      transport: :stdio_jsonl,
      supports: %{
        sessions: true,
        resume: :degraded,
        streaming_events: true,
        approvals: :degraded,
        dynamic_tools: :degraded,
        filesystem: true,
        command_execution: true,
        cancellation: :degraded,
        token_usage: true,
        tool_calls: true,
        approval_requests: :degraded,
        cost: true,
        cancel: :degraded,
        workspace_mode: true,
        context_limit: :degraded
      },
      unsupported: %{
        approvals: :requires_permission_prompt_tool_or_hooks,
        dynamic_tools: :requires_mcp_mapping,
        resident_process: :requires_sari_stop_session_callback,
        approval_requests: :requires_permission_prompt_tool_or_hooks,
        context_limit: :configured_by_model_or_sari_context_limit_tokens
      },
      metadata: %{
        command: "claude -p --output-format stream-json",
        context_limit_tokens: Keyword.get(opts, :context_limit_tokens),
        docs: [
          "https://code.claude.com/docs/en/cli-reference",
          "https://code.claude.com/docs/en/agent-sdk/streaming-output",
          "https://code.claude.com/docs/en/hooks"
        ],
        required_flags: [
          "--print",
          "--output-format stream-json",
          "--verbose"
        ],
        optional_flags: [
          "--input-format stream-json",
          "--include-hook-events",
          "--include-partial-messages",
          "--permission-prompt-tool"
        ]
      }
    }
  end

  @impl true
  def start_session(params, opts \\ []) when is_map(params) do
    with {:ok, executable} <- executable(opts),
         {:ok, cwd} <- session_cwd(params, opts) do
      session_id =
        opts
        |> Keyword.get(:session_id)
        |> claude_session_id()

      {:ok,
       Session.new(session_id, :claude_code_stream_json,
         cwd: cwd,
         metadata: %{
           backend: :claude_code_stream_json,
           command: executable,
           claude_session_id: session_id,
           mode: "one_shot_stream_json",
           resumed: false
         }
       )}
    end
  end

  @impl true
  def resume_session(session_id, opts \\ []) when is_binary(session_id) do
    with {:ok, executable} <- executable(opts),
         {:ok, cwd} <- session_cwd(%{}, opts) do
      {:ok,
       Session.new(session_id, :claude_code_stream_json,
         cwd: cwd,
         metadata: %{
           backend: :claude_code_stream_json,
           command: executable,
           claude_session_id: session_id,
           mode: "one_shot_stream_json",
           resumed: true
         }
       )}
    end
  end

  @impl true
  def start_turn(%Session{} = session, input, opts \\ []) do
    turn_id = Keyword.get(opts, :turn_id, "claude-turn-#{System.unique_integer([:positive])}")

    {:ok, turn_stream(session, input_text(input), turn_id, opts)}
  end

  @impl true
  def interrupt(%Session{} = session, turn_id, _opts \\ []) when is_binary(turn_id) do
    key = {session.id, turn_id}

    case :ets.lookup(active_turns_table(), key) do
      [{^key, port}] when is_port(port) ->
        close_port(port)
        :ets.delete(active_turns_table(), key)
        :ok

      [] ->
        {:error, {:turn_not_active, turn_id}}
    end
  end

  defp turn_stream(%Session{} = session, prompt, turn_id, opts) do
    Stream.resource(
      fn ->
        %{
          phase: :start,
          session: session,
          prompt: prompt,
          turn_id: turn_id,
          opts: opts,
          port: nil,
          stderr_path: stderr_path(session, turn_id),
          pending_line: "",
          event_count: 0,
          max_events: Keyword.get(opts, :max_events, @default_max_events),
          timeout_ms: Keyword.get(opts, :turn_timeout_ms, @default_turn_timeout_ms),
          text_delta_seen?: false,
          tool_input: %{}
        }
      end,
      &next_turn_events/1,
      &cleanup_turn_stream/1
    )
  end

  defp next_turn_events(%{phase: :done} = state), do: {:halt, state}

  defp next_turn_events(%{phase: :start} = state) do
    started = turn_started_event(state)

    case start_port(state) do
      {:ok, port} ->
        :ets.insert(active_turns_table(), {{state.session.id, state.turn_id}, port})
        {[started], %{state | phase: :events, port: port}}

      {:error, reason} ->
        failed = turn_failed_event(state, reason)
        {[started, failed], %{state | phase: :done}}
    end
  end

  defp next_turn_events(%{phase: :events, event_count: count, max_events: max_events} = state)
       when count >= max_events do
    failed = turn_failed_event(state, {:max_events_exceeded, max_events})
    {[failed], %{state | phase: :done}}
  end

  defp next_turn_events(%{phase: :events, port: port, timeout_ms: timeout_ms} = state) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = state.pending_line <> to_string(chunk)

        {events, state} =
          map_output_line(line, %{state | pending_line: "", event_count: state.event_count + 1})

        if Enum.any?(events, &RuntimeEvent.terminal?/1) do
          cleanup_turn_stream(state)
          {events, %{state | phase: :done, port: nil}}
        else
          {events, state}
        end

      {^port, {:data, {:noeol, chunk}}} ->
        {[], %{state | pending_line: state.pending_line <> to_string(chunk)}}

      {^port, {:exit_status, status}} ->
        state = flush_pending_line(state)
        stderr = stderr_excerpt(state)
        cleanup_active_turn(state)

        event =
          if status == 0 do
            turn_completed_event(state, %{reason: :process_exit, exit_status: status})
          else
            turn_failed_event(state, {:process_exit, status, stderr})
          end

        {[event], %{state | phase: :done, port: nil}}
    after
      timeout_ms ->
        stderr = stderr_excerpt(state)
        close_port(port)
        cleanup_active_turn(state)
        failed = turn_failed_event(state, {:turn_timeout, timeout_ms, stderr})
        {[failed], %{state | phase: :done, port: nil}}
    end
  end

  defp start_port(state) do
    with {:ok, executable} <- executable(state.opts),
         {:ok, shell} <- shell_executable(),
         :ok <- validate_cwd(state.session.cwd) do
      try do
        command = shell_command([executable | command_args(state)], state.stderr_path)

        port =
          Port.open(
            {:spawn_executable, String.to_charlist(shell)},
            [
              :binary,
              :exit_status,
              args: [~c"-lc", String.to_charlist(command)],
              cd: String.to_charlist(state.session.cwd || File.cwd!()),
              line: 1_048_576
            ]
          )

        {:ok, port}
      rescue
        error in ArgumentError -> {:error, {:claude_port_open_failed, Exception.message(error)}}
      end
    end
  end

  defp command_args(state) do
    ["-p", "--output-format", "stream-json"]
    |> maybe_append_flag(
      "--include-partial-messages",
      Keyword.get(state.opts, :partial_messages, true)
    )
    |> maybe_append_flag("--include-hook-events", Keyword.get(state.opts, :hook_events, true))
    |> maybe_append_flag("--bare", Keyword.get(state.opts, :bare, false))
    |> maybe_append_flag("--verbose", true)
    |> maybe_append_flag(
      "--dangerously-skip-permissions",
      Keyword.get(state.opts, :dangerously_skip_permissions, false)
    )
    |> maybe_append_pair("--model", Keyword.get(state.opts, :model))
    |> maybe_append_pair("--permission-mode", Keyword.get(state.opts, :permission_mode))
    |> maybe_append_pair("--tools", Keyword.get(state.opts, :tools))
    |> maybe_append_pair("--allowedTools", Keyword.get(state.opts, :allowed_tools))
    |> maybe_append_pair("--disallowedTools", Keyword.get(state.opts, :disallowed_tools))
    |> maybe_append_pair("--system-prompt", Keyword.get(state.opts, :system_prompt))
    |> maybe_append_pair("--append-system-prompt", Keyword.get(state.opts, :append_system_prompt))
    |> maybe_append_pair(
      "--permission-prompt-tool",
      Keyword.get(state.opts, :permission_prompt_tool)
    )
    |> append_session_args(state.session)
    |> Kernel.++([state.prompt])
  end

  defp maybe_append_flag(args, _flag, false), do: args
  defp maybe_append_flag(args, _flag, nil), do: args
  defp maybe_append_flag(args, flag, true), do: args ++ [flag]

  defp maybe_append_pair(args, _flag, nil), do: args
  defp maybe_append_pair(args, _flag, ""), do: args
  defp maybe_append_pair(args, flag, value), do: args ++ [flag, to_string(value)]

  defp append_session_args(args, %Session{} = session) do
    if Map.get(session.metadata, :resumed) == true or Map.get(session.metadata, "resumed") == true do
      args ++ ["--resume", session.id]
    else
      args ++ ["--session-id", claude_session_id(session.id)]
    end
  end

  defp map_output_line(line, state) do
    case Json.decode(line) do
      {:ok, decoded} when is_map(decoded) ->
        map_claude_message(decoded, state)

      {:ok, decoded} ->
        event =
          RuntimeEvent.new(:unsupported, %{reason: :non_object_json, value: decoded},
            session_id: state.session.id,
            turn_id: state.turn_id,
            raw: line,
            metadata: %{backend: :claude_code_stream_json}
          )

        {[event], state}

      {:error, reason} ->
        event =
          RuntimeEvent.new(:error, %{reason: %{type: "invalid_jsonl", error: inspect(reason)}},
            session_id: state.session.id,
            turn_id: state.turn_id,
            raw: line,
            metadata: %{backend: :claude_code_stream_json}
          )

        {[event], state}
    end
  end

  defp map_claude_message(%{"type" => "stream_event", "event" => event} = decoded, state)
       when is_map(event) do
    map_stream_event(event, decoded, state)
  end

  defp map_claude_message(%{"type" => "assistant"} = decoded, %{text_delta_seen?: false} = state) do
    text = assistant_message_text(decoded)

    if text == "" do
      {[], state}
    else
      event =
        RuntimeEvent.new(:assistant_delta, %{text: text},
          session_id: state.session.id,
          turn_id: state.turn_id,
          raw: decoded,
          metadata: %{backend: :claude_code_stream_json, claude_event: "assistant"}
        )

      {[event], state}
    end
  end

  defp map_claude_message(%{"type" => "assistant"}, state), do: {[], state}

  defp map_claude_message(%{"type" => "result"} = decoded, state) do
    events =
      decoded
      |> usage_event(state)
      |> List.wrap()
      |> Enum.reject(&is_nil/1)

    terminal =
      if result_error?(decoded) do
        RuntimeEvent.new(:turn_failed, result_payload(decoded),
          session_id: state.session.id,
          turn_id: state.turn_id,
          raw: decoded,
          metadata: %{backend: :claude_code_stream_json, claude_event: "result"}
        )
      else
        turn_completed_event(state, result_payload(decoded))
        |> Map.put(:raw, decoded)
      end

    {events ++ [terminal], state}
  end

  defp map_claude_message(%{"type" => "system", "subtype" => "init"} = decoded, state) do
    event =
      RuntimeEvent.new(
        :plan_update,
        %{
          event: :session_init,
          claude_session_id: decoded["session_id"],
          tools: decoded["tools"],
          model: decoded["model"]
        },
        session_id: state.session.id,
        turn_id: state.turn_id,
        raw: decoded,
        metadata: %{backend: :claude_code_stream_json, claude_event: "system.init"}
      )

    {[event], state}
  end

  defp map_claude_message(%{"type" => type} = decoded, state) do
    event =
      RuntimeEvent.new(:unsupported, %{type: type, event: decoded},
        session_id: state.session.id,
        turn_id: state.turn_id,
        raw: decoded,
        metadata: %{backend: :claude_code_stream_json, claude_event: type}
      )

    {[event], state}
  end

  defp map_stream_event(
         %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => text}} =
           event,
         decoded,
         state
       )
       when is_binary(text) and text != "" do
    runtime_event =
      RuntimeEvent.new(:assistant_delta, %{text: text},
        session_id: state.session.id,
        turn_id: state.turn_id,
        raw: decoded,
        metadata: %{backend: :claude_code_stream_json, claude_event: event["type"]}
      )

    {[runtime_event], %{state | text_delta_seen?: true}}
  end

  defp map_stream_event(
         %{"type" => "content_block_start", "content_block" => %{"type" => "tool_use"} = block} =
           event,
         decoded,
         state
       ) do
    runtime_event =
      RuntimeEvent.new(:tool_started, block,
        session_id: state.session.id,
        turn_id: state.turn_id,
        raw: decoded,
        metadata: %{backend: :claude_code_stream_json, claude_event: event["type"]}
      )

    {[runtime_event], state}
  end

  defp map_stream_event(
         %{"type" => "content_block_delta", "delta" => %{"type" => "input_json_delta"} = delta} =
           event,
         decoded,
         state
       ) do
    runtime_event =
      RuntimeEvent.new(:tool_output, delta,
        session_id: state.session.id,
        turn_id: state.turn_id,
        raw: decoded,
        metadata: %{backend: :claude_code_stream_json, claude_event: event["type"]}
      )

    {[runtime_event], state}
  end

  defp map_stream_event(%{"type" => "message_delta"} = event, decoded, state) do
    case usage_from_payload(event) do
      nil ->
        {[], state}

      usage ->
        runtime_event =
          RuntimeEvent.new(:token_usage, usage,
            session_id: state.session.id,
            turn_id: state.turn_id,
            raw: decoded,
            metadata: %{backend: :claude_code_stream_json, claude_event: event["type"]}
          )

        {[runtime_event], state}
    end
  end

  defp map_stream_event(event, decoded, state) do
    runtime_event =
      RuntimeEvent.new(:unsupported, %{event: event},
        session_id: state.session.id,
        turn_id: state.turn_id,
        raw: decoded,
        metadata: %{backend: :claude_code_stream_json, claude_event: event["type"]}
      )

    {[runtime_event], state}
  end

  defp usage_event(decoded, state) do
    case usage_from_payload(decoded) do
      nil ->
        nil

      usage ->
        RuntimeEvent.new(:token_usage, usage,
          session_id: state.session.id,
          turn_id: state.turn_id,
          raw: decoded,
          metadata: %{backend: :claude_code_stream_json, claude_event: "result"}
        )
    end
  end

  defp usage_from_payload(payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || get_in(payload, ["message", "usage"])

    cond do
      is_map(usage) ->
        usage
        |> normalize_usage()
        |> maybe_put_cost(payload)

      is_map(Map.get(payload, "modelUsage")) ->
        %{"modelUsage" => Map.get(payload, "modelUsage")}
        |> maybe_put_cost(payload)

      true ->
        nil
    end
  end

  defp usage_from_payload(_payload), do: nil

  defp normalize_usage(usage) do
    input = integer_value(usage, ["input_tokens", "inputTokens", "prompt_tokens", "promptTokens"])

    output =
      integer_value(usage, [
        "output_tokens",
        "outputTokens",
        "completion_tokens",
        "completionTokens"
      ])

    total = integer_value(usage, ["total_tokens", "totalTokens", "total"])

    usage
    |> maybe_put("input_tokens", input)
    |> maybe_put("output_tokens", output)
    |> maybe_put("total_tokens", total || sum_if_present(input, output))
  end

  defp maybe_put_cost(usage, payload) do
    case Map.get(payload, "total_cost_usd") || Map.get(payload, "totalCostUSD") do
      cost when is_number(cost) -> Map.put(usage, "cost_usd", cost)
      _ -> usage
    end
  end

  defp integer_value(map, fields) do
    Enum.find_value(fields, fn field ->
      case Map.get(map, field) do
        value when is_integer(value) and value >= 0 -> value
        value when is_binary(value) -> parse_non_negative_integer(value)
        _ -> nil
      end
    end)
  end

  defp parse_non_negative_integer(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp sum_if_present(input, output) when is_integer(input) and is_integer(output),
    do: input + output

  defp sum_if_present(_input, _output), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp result_error?(decoded) do
    decoded["is_error"] == true or
      decoded["subtype"] in ["error", "failed", "failure", "max_turns"]
  end

  defp result_payload(decoded) do
    %{
      subtype: decoded["subtype"],
      is_error: decoded["is_error"] == true,
      result: decoded["result"],
      session_id: decoded["session_id"],
      duration_ms: decoded["duration_ms"],
      duration_api_ms: decoded["duration_api_ms"],
      num_turns: decoded["num_turns"],
      total_cost_usd: decoded["total_cost_usd"]
    }
    |> reject_nil_values()
  end

  defp assistant_message_text(decoded) do
    decoded
    |> get_in(["message", "content"])
    |> content_text()
  end

  defp content_text(content) when is_binary(content), do: content

  defp content_text(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      %{"text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("")
  end

  defp content_text(_content), do: ""

  defp turn_started_event(state) do
    RuntimeEvent.new(:turn_started, %{input: state.prompt},
      session_id: state.session.id,
      turn_id: state.turn_id,
      metadata: %{backend: :claude_code_stream_json}
    )
  end

  defp turn_completed_event(state, payload) do
    RuntimeEvent.new(:turn_completed, payload,
      session_id: state.session.id,
      turn_id: state.turn_id,
      metadata: %{backend: :claude_code_stream_json}
    )
  end

  defp turn_failed_event(state, reason) do
    error = RuntimeError.normalize(reason, backend: :claude_code_stream_json, stage: :turn)

    RuntimeEvent.new(:turn_failed, RuntimeError.to_payload(error),
      session_id: state.session.id,
      turn_id: state.turn_id,
      metadata: %{backend: :claude_code_stream_json}
    )
  end

  defp flush_pending_line(%{pending_line: ""} = state), do: state

  defp flush_pending_line(%{pending_line: line} = state) do
    {_events, state} = map_output_line(line, %{state | pending_line: ""})
    state
  end

  defp cleanup_turn_stream(%{port: port} = state) when is_port(port) do
    cleanup_active_turn(state)
    close_port(port)
    cleanup_stderr(state)
  end

  defp cleanup_turn_stream(%{stderr_path: _path} = state), do: cleanup_stderr(state)
  defp cleanup_turn_stream(_state), do: :ok

  defp cleanup_active_turn(state) do
    :ets.delete(active_turns_table(), {state.session.id, state.turn_id})
    :ok
  end

  defp close_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end

  defp executable(opts) do
    executable = Keyword.get(opts, :executable) || System.find_executable("claude")

    cond do
      is_binary(executable) and executable != "" and File.exists?(executable) ->
        {:ok, executable}

      is_binary(executable) and executable != "" and Path.basename(executable) == executable ->
        case System.find_executable(executable) do
          nil -> {:error, :claude_executable_not_found}
          found -> {:ok, found}
        end

      true ->
        {:error, :claude_executable_not_found}
    end
  end

  defp shell_executable do
    case System.find_executable("bash") do
      nil -> {:error, :bash_not_found}
      executable -> {:ok, executable}
    end
  end

  defp session_cwd(params, opts) do
    cwd =
      Keyword.get(opts, :cwd) ||
        map_get(params, :cwd, "cwd") ||
        File.cwd!()

    case validate_cwd(cwd) do
      :ok -> {:ok, Path.expand(cwd)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_cwd(nil), do: :ok

  defp validate_cwd(cwd) when is_binary(cwd) do
    if File.dir?(cwd), do: :ok, else: {:error, {:invalid_cwd, cwd}}
  end

  defp validate_cwd(cwd), do: {:error, {:invalid_cwd, cwd}}

  defp input_text(input) when is_binary(input), do: input

  defp input_text(%{"input" => input}), do: input_text(input)
  defp input_text(%{input: input}), do: input_text(input)

  defp input_text(input) when is_list(input) do
    input
    |> Enum.map(&input_part_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp input_text(other), do: inspect(other)

  defp input_part_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp input_part_text(%{type: "text", text: text}) when is_binary(text), do: text
  defp input_part_text(%{"text" => text}) when is_binary(text), do: text
  defp input_part_text(%{text: text}) when is_binary(text), do: text
  defp input_part_text(text) when is_binary(text), do: text
  defp input_part_text(_part), do: ""

  defp map_get(map, atom_key, string_key) when is_map(map) do
    Map.get(map, atom_key) || Map.get(map, string_key)
  end

  defp reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp shell_command(argv, stderr_path) do
    command = Enum.map_join(argv, " ", &shell_escape/1)
    command <> " < /dev/null 2> " <> shell_escape(stderr_path)
  end

  defp shell_escape(value) do
    value = to_string(value)
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp stderr_path(%Session{} = session, turn_id) do
    safe_session = session.id |> to_string() |> String.replace(~r/[^A-Za-z0-9_.-]+/, "_")
    safe_turn = turn_id |> to_string() |> String.replace(~r/[^A-Za-z0-9_.-]+/, "_")

    Path.join(
      System.tmp_dir!(),
      "sari-claude-#{safe_session}-#{safe_turn}-#{System.unique_integer([:positive])}.stderr"
    )
  end

  defp stderr_excerpt(%{stderr_path: path}) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> content |> String.trim() |> String.slice(0, 2_000)
      {:error, _reason} -> nil
    end
  end

  defp stderr_excerpt(_state), do: nil

  defp cleanup_stderr(%{stderr_path: path}) when is_binary(path) do
    _ = File.rm(path)
    :ok
  end

  defp cleanup_stderr(_state), do: :ok

  defp claude_session_id(value) when is_binary(value) do
    if uuid?(value), do: value, else: uuid_v4()
  end

  defp claude_session_id(_value), do: uuid_v4()

  defp uuid?(
         <<a::binary-size(8), "-", b::binary-size(4), "-", c::binary-size(4), "-",
           d::binary-size(4), "-", e::binary-size(12)>>
       ) do
    Enum.all?([a, b, c, d, e], &hex?/1)
  end

  defp uuid?(_value), do: false

  defp hex?(value), do: String.match?(value, ~r/\A[0-9a-fA-F]+\z/)

  defp uuid_v4 do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = bor(band(c, 0x0FFF), 0x4000)
    d = bor(band(d, 0x3FFF), 0x8000)

    [a, b, c, d, e]
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map_join("-", fn {integer, width} ->
      integer
      |> Integer.to_string(16)
      |> String.downcase()
      |> String.pad_leading(width, "0")
    end)
  end

  defp active_turns_table do
    case :ets.whereis(@active_turns_table) do
      :undefined ->
        :ets.new(@active_turns_table, [:named_table, :public, read_concurrency: true])

      table ->
        table
    end
  rescue
    ArgumentError ->
      :ets.whereis(@active_turns_table)
  end
end
