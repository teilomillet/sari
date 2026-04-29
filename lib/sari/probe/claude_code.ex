defmodule Sari.Probe.ClaudeCode do
  @moduledoc """
  Black-box probe for the Claude Code stream-json adapter.

  By default the probe verifies the local `claude` executable and version
  without making a model call. Pass `--prompt` through `mix sari.profile` to run
  a real turn through `Sari.Backend.ClaudeCodeStreamJson`.
  """

  alias Sari.Backend.ClaudeCodeStreamJson
  alias Sari.Runtime

  @default_turn_timeout_ms 300_000

  @spec run(keyword()) :: map()
  def run(opts \\ []) do
    executable = Keyword.get(opts, :executable, System.find_executable("claude"))
    prompt = Keyword.get(opts, :prompt)
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    if missing_executable?(executable) do
      base_result(nil, nil, prompt, cwd, "claude executable not found")
    else
      {version, version_measurement} = measure_version(executable)
      base = base_result(executable, version, prompt, cwd, nil)

      turn =
        if is_binary(prompt) and String.trim(prompt) != "" do
          measure_turn(executable, cwd, prompt, opts)
        else
          not_attempted_turn("prompt not provided")
        end

      base
      |> Map.put(:version_measurement, version_measurement)
      |> Map.put(:turn, turn)
      |> Map.put(:ready, version_measurement.ok)
      |> Map.put(:error, version_measurement.error)
    end
  end

  defp base_result(executable, version, prompt, cwd, error) do
    %{
      scenario: :claude_code_probe,
      command: command_summary(executable),
      cwd: cwd,
      version: version,
      ready: false,
      prompt_provided: is_binary(prompt) and String.trim(prompt) != "",
      version_measurement: not_attempted_measurement(:version),
      turn: not_attempted_turn("not_attempted"),
      error: error
    }
  end

  defp command_summary(nil), do: ["claude", "--version"]
  defp command_summary(executable), do: [executable, "-p", "--output-format", "stream-json"]

  defp measure_version(executable) do
    {duration_us, result} =
      timed(fn ->
        System.cmd(executable, ["--version"], stderr_to_stdout: true)
      end)

    case result do
      {output, 0} ->
        version = output |> String.trim() |> String.split("\n") |> List.first()

        {version,
         %{
           step: :version,
           ok: true,
           duration_us: duration_us,
           output: version,
           error: nil
         }}

      {output, status} ->
        {nil,
         %{
           step: :version,
           ok: false,
           duration_us: duration_us,
           output: String.slice(String.trim(output), 0, 1_000),
           error: "exit #{status}"
         }}
    end
  rescue
    error ->
      {nil,
       %{
         step: :version,
         ok: false,
         duration_us: 0,
         output: nil,
         error: Exception.message(error)
       }}
  end

  defp measure_turn(executable, cwd, prompt, opts) do
    turn_opts =
      [
        executable: executable,
        turn_timeout_ms: Keyword.get(opts, :turn_timeout_ms, @default_turn_timeout_ms),
        model: Keyword.get(opts, :model),
        permission_mode: Keyword.get(opts, :permission_mode),
        tools: Keyword.get(opts, :tools),
        allowed_tools: Keyword.get(opts, :allowed_tools),
        bare: Keyword.get(opts, :bare, false),
        dangerously_skip_permissions: Keyword.get(opts, :dangerously_skip_permissions, false)
      ]
      |> reject_nil_values()

    {session_duration_us, session_result} =
      timed(fn ->
        Runtime.start_session(ClaudeCodeStreamJson, %{"cwd" => cwd}, turn_opts)
      end)

    case session_result do
      {:ok, session} ->
        {turn_duration_us, turn_result} =
          timed(fn ->
            Runtime.collect_turn(
              ClaudeCodeStreamJson,
              session,
              prompt,
              Keyword.put(turn_opts, :turn_id, "claude-probe-turn")
            )
          end)

        turn_measurement(session, session_duration_us, turn_duration_us, turn_result)

      {:error, reason} ->
        %{
          attempted: true,
          ok: false,
          session_id: nil,
          session_duration_us: session_duration_us,
          duration_us: 0,
          event_count: 0,
          assistant_text: "",
          terminal: nil,
          token_usage: nil,
          error: inspect(reason)
        }
    end
  end

  defp turn_measurement(session, session_duration_us, turn_duration_us, {:ok, result}) do
    %{
      attempted: true,
      ok: result.terminal.type == :turn_completed,
      session_id: session.id,
      session_duration_us: session_duration_us,
      duration_us: turn_duration_us,
      event_count: length(result.events),
      assistant_text: assistant_text(result.events),
      terminal: result.terminal.type,
      token_usage: last_payload(result.events, :token_usage),
      error: nil
    }
  end

  defp turn_measurement(session, session_duration_us, turn_duration_us, {:error, reason}) do
    %{
      attempted: true,
      ok: false,
      session_id: session.id,
      session_duration_us: session_duration_us,
      duration_us: turn_duration_us,
      event_count: 0,
      assistant_text: "",
      terminal: nil,
      token_usage: nil,
      error: inspect(reason)
    }
  end

  defp assistant_text(events) do
    events
    |> Enum.filter(&(&1.type == :assistant_delta))
    |> Enum.map_join("", &(Map.get(&1.payload, :text) || Map.get(&1.payload, "text") || ""))
  end

  defp last_payload(events, type) do
    events
    |> Enum.filter(&(&1.type == type))
    |> List.last()
    |> case do
      nil -> nil
      event -> event.payload
    end
  end

  defp not_attempted_measurement(step) do
    %{step: step, ok: false, duration_us: 0, output: nil, error: "not_attempted"}
  end

  defp not_attempted_turn(reason) do
    %{
      attempted: false,
      ok: false,
      session_id: nil,
      session_duration_us: 0,
      duration_us: 0,
      event_count: 0,
      assistant_text: "",
      terminal: nil,
      token_usage: nil,
      error: reason
    }
  end

  defp timed(fun) when is_function(fun, 0) do
    started = System.monotonic_time(:microsecond)
    result = fun.()
    {System.monotonic_time(:microsecond) - started, result}
  end

  defp reject_nil_values(opts) do
    Enum.reject(opts, fn {_key, value} -> is_nil(value) end)
  end

  defp missing_executable?(nil), do: true
  defp missing_executable?(""), do: true
  defp missing_executable?(executable), do: !File.exists?(executable)
end
