defmodule Sari.Profile do
  @moduledoc """
  Lightweight profiling harness for Sari runtime paths.

  The first scenario measures the bounded app-server protocol facade backed by
  the deterministic fake backend. It is intentionally dependency-free and emits
  USL-ready measurements across concurrency levels.
  """

  alias Sari.AppServer.Protocol
  alias Sari.Json
  alias Sari.Probe.ClaudeCode
  alias Sari.Probe.OpenCode
  alias Sari.Profile.Sweep

  @default_concurrency_levels [1, 2, 4, 8, 16]
  @default_iterations 100
  @default_warmup_iterations 5

  @type scenario :: :app_server_fake | :opencode_probe | :claude_code_probe | :backend_sweep

  @type measurement :: %{
          scenario: scenario(),
          concurrency: pos_integer(),
          iterations_per_worker: pos_integer(),
          operations: non_neg_integer(),
          successes: non_neg_integer(),
          errors: non_neg_integer(),
          output_messages: non_neg_integer(),
          duration_us: non_neg_integer(),
          throughput_ops_per_sec: float(),
          latency_us: map(),
          reductions: map(),
          memory_bytes: map(),
          mailbox: map()
        }

  @type report :: %{
          scenario: scenario(),
          generated_at: DateTime.t(),
          measurements: [measurement()]
        }

  @spec run(keyword()) :: report()
  def run(opts \\ []) do
    scenario = Keyword.get(opts, :scenario, :app_server_fake)

    run_scenario(scenario, opts)
  end

  defp run_scenario(:app_server_fake = scenario, opts) do
    %{
      scenario: scenario,
      generated_at: DateTime.utc_now(),
      measurements:
        Enum.map(
          Keyword.get(opts, :concurrency_levels, @default_concurrency_levels),
          fn concurrency ->
            measure(
              scenario,
              concurrency,
              Keyword.get(opts, :iterations, @default_iterations),
              Keyword.get(opts, :warmup_iterations, @default_warmup_iterations)
            )
          end
        )
    }
  end

  defp run_scenario(:opencode_probe = scenario, opts) do
    %{
      scenario: scenario,
      generated_at: DateTime.utc_now(),
      measurements: [
        OpenCode.run(
          port: Keyword.get(opts, :port, nil) || random_probe_port(),
          ready_timeout_ms: Keyword.get(opts, :ready_timeout_ms, 5_000),
          prompt: Keyword.get(opts, :prompt)
        )
      ]
    }
  end

  defp run_scenario(:claude_code_probe = scenario, opts) do
    %{
      scenario: scenario,
      generated_at: DateTime.utc_now(),
      measurements: [
        ClaudeCode.run(
          prompt: Keyword.get(opts, :prompt),
          cwd: Keyword.get(opts, :cwd, File.cwd!()),
          turn_timeout_ms: Keyword.get(opts, :turn_timeout_ms, 300_000),
          model: Keyword.get(opts, :model),
          permission_mode: Keyword.get(opts, :permission_mode),
          tools: Keyword.get(opts, :tools),
          allowed_tools: Keyword.get(opts, :allowed_tools),
          bare: Keyword.get(opts, :bare, false),
          dangerously_skip_permissions: Keyword.get(opts, :dangerously_skip_permissions, false)
        )
      ]
    }
  end

  defp run_scenario(:backend_sweep, opts) do
    Sweep.run(
      backend: Keyword.get(opts, :backend, :fake),
      concurrency_levels: Keyword.get(opts, :concurrency_levels, @default_concurrency_levels),
      iterations: Keyword.get(opts, :iterations, @default_iterations),
      warmup_iterations: Keyword.get(opts, :warmup_iterations, @default_warmup_iterations),
      prompt: Keyword.get(opts, :prompt, "Reply exactly: sari-profile-ok"),
      backend_opts: Keyword.get(opts, :backend_opts, [])
    )
  end

  @spec format_markdown(report()) :: String.t()
  def format_markdown(%{scenario: :backend_sweep} = report), do: Sweep.format_markdown(report)

  def format_markdown(%{scenario: scenario, measurements: measurements}) do
    case scenario do
      :opencode_probe -> format_opencode_markdown(scenario, measurements)
      :claude_code_probe -> format_claude_code_markdown(scenario, measurements)
      _ -> format_app_server_markdown(scenario, measurements)
    end
  end

  defp format_app_server_markdown(scenario, measurements) do
    rows =
      Enum.map(measurements, fn measurement ->
        [
          measurement.concurrency,
          measurement.operations,
          measurement.successes,
          measurement.errors,
          format_float(measurement.throughput_ops_per_sec, 2),
          measurement.latency_us.p50,
          measurement.latency_us.p95,
          measurement.reductions.per_op,
          measurement.memory_bytes.delta,
          measurement.output_messages
        ]
        |> Enum.join(" | ")
      end)

    """
    # Sari profile: #{scenario}

    | N | ops | ok | errors | ops/s | p50 us | p95 us | reductions/op | memory delta bytes | output messages |
    |---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
    #{Enum.map_join(rows, "\n", &("| " <> &1 <> " |"))}
    """
    |> String.trim()
  end

  defp format_opencode_markdown(scenario, [measurement | _]) do
    endpoint_rows =
      measurement.endpoint_measurements
      |> Enum.map(fn endpoint ->
        [
          endpoint.method,
          endpoint.path,
          endpoint.status || "",
          endpoint.ok,
          endpoint.duration_us,
          endpoint.bytes,
          endpoint.error || ""
        ]
        |> Enum.join(" | ")
      end)

    sse = measurement.sse_measurement
    lifecycle = measurement.session_lifecycle

    lifecycle_rows =
      [
        {"create", lifecycle.create},
        {"messages", lifecycle.messages},
        {"server_status", lifecycle.server_status},
        {"prompt_async", lifecycle.prompt_async},
        {"delete", lifecycle.delete}
      ]
      |> Enum.map(fn {step, endpoint} ->
        [
          step,
          endpoint.method,
          endpoint.path,
          endpoint.status || "",
          endpoint.ok,
          endpoint.duration_us,
          endpoint.bytes,
          endpoint.error || ""
        ]
        |> Enum.join(" | ")
      end)

    stdout =
      measurement.stdout_sample
      |> Enum.reject(&(&1 == ""))
      |> Enum.map_join("\n", &("- " <> &1))

    """
    # Sari profile: #{scenario}

    - command: `#{Enum.join(measurement.command, " ")}`
    - version: `#{measurement.version || ""}`
    - started: `#{measurement.started}`
    - ready: `#{measurement.ready}`
    - cold_start_us: `#{measurement.cold_start_us || ""}`
    - error: `#{measurement.error || ""}`

    | method | path | status | ok | duration us | bytes | error |
    |---|---|---:|---:|---:|---:|---|
    #{Enum.map_join(endpoint_rows, "\n", &("| " <> &1 <> " |"))}

    ## SSE

    - path: `#{sse.path}`
    - status: `#{sse.status || ""}`
    - ok: `#{sse.ok}`
    - duration_us: `#{sse.duration_us}`
    - bytes: `#{sse.bytes}`
    - first_event: `#{sse.first_event || ""}`
    - error: `#{sse.error || ""}`

    ## session lifecycle

    - created: `#{lifecycle.created}`
    - session_id: `#{lifecycle.session_id || ""}`
    - error: `#{lifecycle.error || ""}`

    | step | method | path | status | ok | duration us | bytes | error |
    |---|---|---|---:|---:|---:|---:|---|
    #{Enum.map_join(lifecycle_rows, "\n", &("| " <> &1 <> " |"))}

    ## stdout sample

    #{if stdout == "", do: "- <empty>", else: stdout}
    """
    |> String.trim()
  end

  defp format_claude_code_markdown(scenario, [measurement | _]) do
    turn = measurement.turn
    usage = turn.token_usage || %{}

    """
    # Sari profile: #{scenario}

    - command: `#{Enum.join(measurement.command, " ")}`
    - cwd: `#{measurement.cwd}`
    - version: `#{measurement.version || ""}`
    - ready: `#{measurement.ready}`
    - prompt_provided: `#{measurement.prompt_provided}`
    - error: `#{measurement.error || ""}`

    ## version

    - ok: `#{measurement.version_measurement.ok}`
    - duration_us: `#{measurement.version_measurement.duration_us}`
    - output: `#{measurement.version_measurement.output || ""}`
    - error: `#{measurement.version_measurement.error || ""}`

    ## turn

    - attempted: `#{turn.attempted}`
    - ok: `#{turn.ok}`
    - session_id: `#{turn.session_id || ""}`
    - session_duration_us: `#{turn.session_duration_us}`
    - duration_us: `#{turn.duration_us}`
    - event_count: `#{turn.event_count}`
    - terminal: `#{turn.terminal || ""}`
    - input_tokens: `#{usage["input_tokens"] || ""}`
    - output_tokens: `#{usage["output_tokens"] || ""}`
    - total_tokens: `#{usage["total_tokens"] || ""}`
    - cost_usd: `#{usage["cost_usd"] || ""}`
    - assistant_text: `#{turn.assistant_text}`
    - error: `#{turn.error || ""}`
    """
    |> String.trim()
  end

  @spec format_json(report()) :: String.t()
  def format_json(report), do: Json.encode!(report)

  defp measure(:app_server_fake = scenario, concurrency, iterations, warmup_iterations)
       when is_integer(concurrency) and concurrency > 0 and is_integer(iterations) and
              iterations > 0 do
    if warmup_iterations > 0 do
      run_worker(0, warmup_iterations)
    end

    before_memory = :erlang.memory(:total)
    before_reductions = total_reductions()
    before_mailbox = mailbox_len(self())
    started_at = now_us()

    task_results =
      1..concurrency
      |> Task.async_stream(
        fn worker_id -> run_worker(worker_id, iterations) end,
        max_concurrency: concurrency,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.to_list()

    finished_at = now_us()
    after_mailbox = mailbox_len(self())
    after_reductions = total_reductions()
    after_memory = :erlang.memory(:total)

    worker_results = collect_worker_results(task_results)
    latencies = Enum.flat_map(worker_results, & &1.latencies_us)
    worker_errors = Enum.flat_map(worker_results, & &1.errors)
    task_errors = collect_task_errors(task_results)
    output_messages = Enum.sum(Enum.map(worker_results, & &1.output_messages))
    operations = concurrency * iterations
    errors = length(worker_errors) + length(task_errors)
    successes = operations - errors
    duration_us = max(finished_at - started_at, 1)
    reductions = after_reductions - before_reductions

    %{
      scenario: scenario,
      concurrency: concurrency,
      iterations_per_worker: iterations,
      operations: operations,
      successes: successes,
      errors: errors,
      output_messages: output_messages,
      duration_us: duration_us,
      throughput_ops_per_sec: successes / (duration_us / 1_000_000),
      latency_us: latency_summary(latencies),
      reductions: %{
        total: reductions,
        per_op: div(reductions, max(successes, 1))
      },
      memory_bytes: %{
        before: before_memory,
        after: after_memory,
        delta: after_memory - before_memory
      },
      mailbox: %{
        before: before_mailbox,
        after: after_mailbox,
        delta: after_mailbox - before_mailbox
      }
    }
  end

  defp run_worker(worker_id, iterations) do
    {state, _outputs} =
      Protocol.handle_json_line(
        Protocol.new(),
        Json.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}})
      )

    1..iterations
    |> Enum.reduce(
      %{state: state, latencies_us: [], errors: [], output_messages: 0},
      fn iteration, acc ->
        started_at = now_us()

        case run_protocol_turn(acc.state, worker_id, iteration) do
          {:ok, next_state, output_count} ->
            latency_us = now_us() - started_at

            %{
              acc
              | state: next_state,
                latencies_us: [latency_us | acc.latencies_us],
                output_messages: acc.output_messages + output_count
            }

          {:error, next_state, reason} ->
            %{
              acc
              | state: next_state,
                errors: [
                  %{worker_id: worker_id, iteration: iteration, reason: reason} | acc.errors
                ]
            }
        end
      end
    )
    |> Map.update!(:latencies_us, &Enum.reverse/1)
  end

  defp run_protocol_turn(state, worker_id, iteration) do
    request_id = worker_id * 1_000_000 + iteration * 10
    cwd = "/tmp/sari-profile/#{worker_id}/#{iteration}"

    thread_request =
      Json.encode!(%{
        "jsonrpc" => "2.0",
        "id" => request_id,
        "method" => "thread/start",
        "params" => %{"cwd" => cwd}
      })

    {state, thread_outputs} = Protocol.handle_json_line(state, thread_request)

    with [thread_line] <- thread_outputs,
         {:ok, %{"result" => %{"thread" => %{"id" => thread_id}}}} <- Json.decode(thread_line) do
      turn_request =
        Json.encode!(%{
          "jsonrpc" => "2.0",
          "id" => request_id + 1,
          "method" => "turn/start",
          "params" => %{
            "threadId" => thread_id,
            "input" => [%{"type" => "text", "text" => "profile #{iteration}"}]
          }
        })

      {state, turn_outputs} = Protocol.handle_json_line(state, turn_request)

      if valid_turn_outputs?(turn_outputs) do
        {:ok, state, length(thread_outputs) + length(turn_outputs)}
      else
        {:error, state, {:invalid_turn_outputs, turn_outputs}}
      end
    else
      other -> {:error, state, {:invalid_thread_outputs, other}}
    end
  end

  defp valid_turn_outputs?([response | notifications]) do
    with {:ok, %{"result" => %{"turn" => %{"status" => "running"}}}} <- Json.decode(response) do
      terminal_count =
        notifications
        |> Enum.map(&Json.decode/1)
        |> Enum.count(fn
          {:ok, %{"method" => method}} ->
            method in ["turn/completed", "turn/failed", "turn/cancelled"]

          _ ->
            false
        end)

      terminal_count == 1
    else
      _ -> false
    end
  end

  defp valid_turn_outputs?(_outputs), do: false

  defp collect_worker_results(task_results) do
    Enum.flat_map(task_results, fn
      {:ok, result} -> [result]
      {:exit, _reason} -> []
    end)
  end

  defp collect_task_errors(task_results) do
    Enum.flat_map(task_results, fn
      {:ok, _result} -> []
      {:exit, reason} -> [%{task_exit: reason}]
    end)
  end

  defp latency_summary([]) do
    %{min: nil, p50: nil, p95: nil, max: nil, avg: nil}
  end

  defp latency_summary(latencies) do
    sorted = Enum.sort(latencies)
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

  defp total_reductions do
    :erlang.statistics(:reductions) |> elem(0)
  end

  defp mailbox_len(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, value} -> value
      nil -> 0
    end
  end

  defp now_us, do: System.monotonic_time(:microsecond)

  defp format_float(value, decimals) when is_float(value) do
    :erlang.float_to_binary(value, decimals: decimals)
  end

  defp random_probe_port do
    43_000 + :rand.uniform(5_000)
  end
end
