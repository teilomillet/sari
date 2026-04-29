defmodule Sari.Profile.Sweep do
  @moduledoc """
  Repeatable runtime sweep profiler.

  Each operation starts a session, streams one turn, records startup latency,
  first assistant token latency, full-turn latency, event count, memory deltas,
  and failure rate. Real backends are opt-in because they can spend model tokens.
  """

  alias Sari.Backend.{ClaudeCodeStreamJson, Fake, OpenCodeHttp}
  alias Sari.{Runtime, RuntimeEvent}

  @default_prompt "Reply exactly: sari-profile-ok"

  @spec backend_module(atom() | String.t() | module()) :: {:ok, module()} | {:error, term()}
  def backend_module(module) when is_atom(module) do
    if function_exported?(module, :capabilities, 1) do
      {:ok, module}
    else
      module |> Atom.to_string() |> backend_module()
    end
  end

  def backend_module(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "fake" -> {:ok, Fake}
      "opencode" -> {:ok, OpenCodeHttp}
      "opencode_http" -> {:ok, OpenCodeHttp}
      "claude" -> {:ok, ClaudeCodeStreamJson}
      "claude_code" -> {:ok, ClaudeCodeStreamJson}
      "claude_code_stream_json" -> {:ok, ClaudeCodeStreamJson}
      other -> {:error, {:unsupported_backend, other}}
    end
  end

  @spec run(keyword()) :: map()
  def run(opts) do
    {:ok, backend} = backend_module(Keyword.get(opts, :backend, :fake))

    %{
      scenario: :backend_sweep,
      backend: backend_name(backend),
      generated_at: DateTime.utc_now(),
      measurements:
        Enum.map(Keyword.fetch!(opts, :concurrency_levels), fn concurrency ->
          measure_backend(backend, concurrency, opts)
        end)
    }
  end

  @spec format_markdown(map()) :: String.t()
  def format_markdown(%{backend: backend, measurements: measurements}) do
    rows =
      Enum.map(measurements, fn measurement ->
        [
          measurement.concurrency,
          measurement.operations,
          measurement.successes,
          measurement.errors,
          format_float(measurement.failure_rate, 4),
          format_float(measurement.throughput_ops_per_sec, 2),
          measurement.startup_us.p50 || "",
          measurement.first_token_us.p50 || "",
          measurement.full_turn_us.p50 || "",
          measurement.full_turn_us.p95 || "",
          measurement.memory_bytes.delta,
          measurement.events_per_op
        ]
        |> Enum.join(" | ")
      end)

    """
    # Sari backend sweep: #{backend}

    | N | ops | ok | errors | failure rate | ops/s | startup p50 us | first-token p50 us | full-turn p50 us | full-turn p95 us | memory delta bytes | events/op |
    |---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
    #{Enum.map_join(rows, "\n", &("| " <> &1 <> " |"))}
    """
    |> String.trim()
  end

  defp measure_backend(backend, concurrency, opts) do
    iterations = Keyword.fetch!(opts, :iterations)
    warmup_iterations = Keyword.get(opts, :warmup_iterations, 0)
    backend_opts = Keyword.get(opts, :backend_opts, [])
    prompt = Keyword.get(opts, :prompt, @default_prompt)

    if warmup_iterations > 0 do
      run_worker(backend, 0, warmup_iterations, prompt, backend_opts)
    end

    before_memory = :erlang.memory(:total)
    before_reductions = total_reductions()
    started_at = now_us()

    task_results =
      1..concurrency
      |> Task.async_stream(
        fn worker_id -> run_worker(backend, worker_id, iterations, prompt, backend_opts) end,
        max_concurrency: concurrency,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.to_list()

    finished_at = now_us()
    after_memory = :erlang.memory(:total)
    reductions = total_reductions() - before_reductions
    duration_us = max(finished_at - started_at, 1)
    worker_results = collect_worker_results(task_results)
    task_errors = collect_task_errors(task_results)
    operation_results = Enum.flat_map(worker_results, & &1.operations)
    operations = concurrency * iterations
    successes = Enum.count(operation_results, & &1.ok?)
    errors = operations - successes + length(task_errors)
    event_count = operation_results |> Enum.map(& &1.event_count) |> Enum.sum()

    %{
      scenario: :backend_sweep,
      backend: backend_name(backend),
      concurrency: concurrency,
      iterations_per_worker: iterations,
      operations: operations,
      successes: successes,
      errors: errors,
      failure_rate: errors / max(operations, 1),
      throughput_ops_per_sec: successes / (duration_us / 1_000_000),
      duration_us: duration_us,
      startup_us: latency_summary(Enum.map(operation_results, & &1.startup_us)),
      first_token_us:
        latency_summary(
          operation_results
          |> Enum.map(& &1.first_token_us)
          |> Enum.reject(&is_nil/1)
        ),
      full_turn_us: latency_summary(Enum.map(operation_results, & &1.full_turn_us)),
      events_per_op: div(event_count, max(length(operation_results), 1)),
      reductions: %{total: reductions, per_op: div(reductions, max(successes, 1))},
      memory_bytes: %{
        before: before_memory,
        after: after_memory,
        delta: after_memory - before_memory
      },
      errors_sample: Enum.take(Enum.flat_map(worker_results, & &1.errors) ++ task_errors, 5)
    }
  end

  defp run_worker(backend, worker_id, iterations, prompt, backend_opts) do
    operations =
      Enum.map(1..iterations, fn iteration ->
        run_operation(backend, worker_id, iteration, prompt, backend_opts)
      end)

    %{operations: operations, errors: Enum.reject(operations, & &1.ok?)}
  end

  defp run_operation(backend, worker_id, iteration, prompt, backend_opts) do
    started_at = now_us()
    session_id = "sari-profile-#{worker_id}-#{iteration}"

    case Runtime.start_session(
           backend,
           %{"cwd" => File.cwd!(), "title" => session_id},
           Keyword.put(backend_opts, :session_id, session_id)
         ) do
      {:ok, session} ->
        startup_us = now_us() - started_at
        turn_started_at = now_us()

        case Runtime.stream_turn(
               backend,
               session,
               prompt,
               Keyword.put(backend_opts, :turn_id, "turn-#{worker_id}-#{iteration}")
             ) do
          {:ok, stream} ->
            result = collect_stream(stream, turn_started_at)

            %{
              ok?: result.terminal == :turn_completed,
              startup_us: startup_us,
              first_token_us: result.first_token_us,
              full_turn_us: result.full_turn_us,
              event_count: result.event_count,
              terminal: result.terminal,
              reason: result.reason
            }

          {:error, reason} ->
            %{
              ok?: false,
              startup_us: startup_us,
              first_token_us: nil,
              full_turn_us: now_us() - turn_started_at,
              event_count: 0,
              terminal: nil,
              reason: inspect(reason)
            }
        end

      {:error, reason} ->
        %{
          ok?: false,
          startup_us: now_us() - started_at,
          first_token_us: nil,
          full_turn_us: 0,
          event_count: 0,
          terminal: nil,
          reason: inspect(reason)
        }
    end
  end

  defp collect_stream(stream, turn_started_at) do
    Enum.reduce_while(
      stream,
      %{first_token_us: nil, event_count: 0, terminal: nil, reason: nil},
      fn event, acc ->
        acc = %{
          acc
          | event_count: acc.event_count + 1,
            first_token_us: first_token_latency(acc.first_token_us, event, turn_started_at)
        }

        if RuntimeEvent.terminal?(event) do
          {:halt, %{acc | terminal: event.type, reason: event.payload}}
        else
          {:cont, acc}
        end
      end
    )
    |> Map.put(:full_turn_us, now_us() - turn_started_at)
  end

  defp first_token_latency(nil, %RuntimeEvent{type: :assistant_delta}, turn_started_at),
    do: now_us() - turn_started_at

  defp first_token_latency(existing, _event, _turn_started_at), do: existing

  defp collect_worker_results(task_results) do
    Enum.flat_map(task_results, fn
      {:ok, result} -> [result]
      {:exit, _reason} -> []
    end)
  end

  defp collect_task_errors(task_results) do
    Enum.flat_map(task_results, fn
      {:ok, _result} -> []
      {:exit, reason} -> [%{task_exit: inspect(reason)}]
    end)
  end

  defp latency_summary([]), do: %{min: nil, p50: nil, p95: nil, max: nil, avg: nil}

  defp latency_summary(values) do
    sorted = Enum.sort(values)
    count = length(sorted)

    %{
      min: List.first(sorted),
      p50: percentile(sorted, 50),
      p95: percentile(sorted, 95),
      max: List.last(sorted),
      avg: div(Enum.sum(sorted), count)
    }
  end

  defp percentile(sorted, percentile) do
    index =
      sorted
      |> length()
      |> Kernel.*(percentile / 100)
      |> Float.ceil()
      |> trunc()
      |> Kernel.-(1)
      |> max(0)

    Enum.at(sorted, index)
  end

  defp total_reductions, do: :erlang.statistics(:reductions) |> elem(0)
  defp now_us, do: System.monotonic_time(:microsecond)

  defp backend_name(backend) do
    backend |> Module.split() |> List.last() |> Macro.underscore()
  end

  defp format_float(value, decimals) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: decimals)

  defp format_float(value, _decimals), do: to_string(value)
end
