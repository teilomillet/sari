defmodule Sari.Probe.OpenCode do
  @moduledoc """
  Black-box probe for `opencode serve`.

  The probe measures the local server path Sari will use before implementing a
  full adapter. It intentionally records failures as data so capability gaps and
  sandbox/auth issues are visible instead of hidden.
  """

  alias Sari.Json

  @default_host "127.0.0.1"
  @default_ready_timeout_ms 5_000
  @poll_interval_ms 50
  @line_bytes 1_000_000
  @default_endpoints ["/global/health", "/doc", "/session"]
  @sse_timeout_ms 1_000
  @request_timeout_ms 2_000

  @type endpoint_measurement :: %{
          path: String.t(),
          method: atom(),
          status: non_neg_integer() | nil,
          duration_us: non_neg_integer(),
          bytes: non_neg_integer(),
          ok: boolean(),
          error: String.t() | nil
        }

  @type sse_measurement :: %{
          path: String.t(),
          status: non_neg_integer() | nil,
          duration_us: non_neg_integer(),
          bytes: non_neg_integer(),
          ok: boolean(),
          first_event: String.t() | nil,
          error: String.t() | nil
        }

  @type session_lifecycle :: %{
          created: boolean(),
          session_id: String.t() | nil,
          create: endpoint_measurement(),
          messages: endpoint_measurement(),
          server_status: endpoint_measurement(),
          prompt_async: endpoint_measurement(),
          delete: endpoint_measurement(),
          error: String.t() | nil
        }

  @type result :: %{
          scenario: :opencode_probe,
          command: [String.t()],
          host: String.t(),
          port: pos_integer(),
          version: String.t() | nil,
          started: boolean(),
          ready: boolean(),
          cold_start_us: non_neg_integer() | nil,
          endpoint_measurements: [endpoint_measurement()],
          sse_measurement: sse_measurement(),
          session_lifecycle: session_lifecycle(),
          stdout_sample: [String.t()],
          error: String.t() | nil
        }

  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    host = Keyword.get(opts, :host, @default_host)
    port = Keyword.get(opts, :port, random_port())
    executable = Keyword.get(opts, :executable, System.find_executable("opencode"))
    ready_timeout_ms = Keyword.get(opts, :ready_timeout_ms, @default_ready_timeout_ms)
    endpoints = Keyword.get(opts, :endpoints, @default_endpoints)
    prompt = Keyword.get(opts, :prompt)

    cond do
      is_nil(executable) ->
        base_result(host, port, nil, nil, endpoints, "opencode executable not found")

      true ->
        do_run(executable, host, port, ready_timeout_ms, endpoints, prompt)
    end
  end

  defp do_run(executable, host, port, ready_timeout_ms, endpoints, prompt) do
    command = [executable, "serve", "--hostname", host, "--port", Integer.to_string(port)]
    started_at = now_us()

    case start_port(executable, host, port) do
      {:ok, opencode_port} ->
        try do
          readiness = wait_until_ready(host, port, ready_timeout_ms, [])
          stdout_sample = drain_port_lines(opencode_port, [])

          case readiness do
            {:ok, cold_start_us, version} ->
              %{
                scenario: :opencode_probe,
                command: command,
                host: host,
                port: port,
                version: version,
                started: true,
                ready: true,
                cold_start_us: cold_start_us,
                endpoint_measurements: Enum.map(endpoints, &measure_endpoint(host, port, &1)),
                sse_measurement: measure_sse_first_event(host, port, "/global/event"),
                session_lifecycle: measure_session_lifecycle(host, port, prompt),
                stdout_sample: stdout_sample,
                error: nil
              }

            {:error, reason} ->
              %{
                scenario: :opencode_probe,
                command: command,
                host: host,
                port: port,
                version: nil,
                started: true,
                ready: false,
                cold_start_us: now_us() - started_at,
                endpoint_measurements: [],
                sse_measurement: empty_sse("/global/event"),
                session_lifecycle: empty_session_lifecycle(),
                stdout_sample: stdout_sample,
                error: inspect(reason)
              }
          end
        after
          stop_port(opencode_port)
        end

      {:error, reason} ->
        base_result(host, port, command, now_us() - started_at, endpoints, inspect(reason))
    end
  end

  defp base_result(host, port, command, cold_start_us, endpoints, error) do
    %{
      scenario: :opencode_probe,
      command: command || [],
      host: host,
      port: port,
      version: nil,
      started: false,
      ready: false,
      cold_start_us: cold_start_us,
      endpoint_measurements: Enum.map(endpoints, &empty_endpoint(&1)),
      sse_measurement: empty_sse("/global/event"),
      session_lifecycle: empty_session_lifecycle(),
      stdout_sample: [],
      error: error
    }
  end

  defp start_port(executable, host, port) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["serve", "--hostname", host, "--port", Integer.to_string(port)],
          line: @line_bytes
        ]
      )

    {:ok, port}
  rescue
    error -> {:error, error}
  end

  defp wait_until_ready(host, port, timeout_ms, _stdout) do
    started_at_ms = System.monotonic_time(:millisecond)
    started_at_us = now_us()
    wait_until_ready(host, port, started_at_ms, started_at_us, timeout_ms)
  end

  defp wait_until_ready(host, port, started_at_ms, started_at_us, timeout_ms) do
    case http_get(host, port, "/global/health") do
      {:ok, 200, body} ->
        {:ok, now_us() - started_at_us, version_from_health(body)}

      {:ok, status, body} ->
        if timed_out?(started_at_ms, timeout_ms) do
          {:error, {:not_ready, status, String.slice(body, 0, 200)}}
        else
          sleep_and_retry(host, port, started_at_ms, started_at_us, timeout_ms)
        end

      {:error, reason} ->
        if timed_out?(started_at_ms, timeout_ms) do
          {:error, {:ready_timeout, reason}}
        else
          sleep_and_retry(host, port, started_at_ms, started_at_us, timeout_ms)
        end
    end
  end

  defp sleep_and_retry(host, port, started_at_ms, started_at_us, timeout_ms) do
    Process.sleep(@poll_interval_ms)
    wait_until_ready(host, port, started_at_ms, started_at_us, timeout_ms)
  end

  defp timed_out?(started_at_ms, timeout_ms) do
    System.monotonic_time(:millisecond) - started_at_ms >= timeout_ms
  end

  defp measure_endpoint(host, port, path) do
    {measurement, _body} = timed_http_request(:get, host, port, path)
    measurement
  end

  defp timed_http_request(method, host, port, path, body \\ nil) do
    started_at = now_us()

    case http_request(method, host, port, path, body) do
      {:ok, status, body} ->
        measurement =
          %{
            path: path,
            method: method,
            status: status,
            duration_us: now_us() - started_at,
            bytes: byte_size(body),
            ok: status >= 200 and status < 300,
            error: nil
          }

        {measurement, body}

      {:error, reason} ->
        measurement =
          %{
            path: path,
            method: method,
            status: nil,
            duration_us: now_us() - started_at,
            bytes: 0,
            ok: false,
            error: inspect(reason)
          }

        {measurement, ""}
    end
  end

  defp measure_session_lifecycle(host, port, prompt) do
    title = "Sari probe #{System.unique_integer([:positive])}"
    {create, body} = timed_http_request(:post, host, port, "/session", %{"title" => title})

    with true <- create.ok,
         {:ok, session_id} <- session_id_from_body(body) do
      session_path = "/session/#{URI.encode(session_id, &URI.char_unreserved?/1)}"
      {messages, _} = timed_http_request(:get, host, port, session_path <> "/message")
      {server_status, _} = timed_http_request(:get, host, port, "/session/status")
      prompt_async = maybe_measure_prompt_async(host, port, session_path, prompt)
      {delete, _} = timed_http_request(:delete, host, port, session_path)

      %{
        created: true,
        session_id: session_id,
        create: create,
        messages: messages,
        server_status: server_status,
        prompt_async: prompt_async,
        delete: delete,
        error: nil
      }
    else
      false ->
        %{
          empty_session_lifecycle()
          | create: create,
            error: "session create returned non-2xx status"
        }

      {:error, reason} ->
        %{
          empty_session_lifecycle()
          | create: create,
            error: reason
        }
    end
  end

  defp maybe_measure_prompt_async(_host, _port, _session_path, prompt)
       when prompt in [nil, ""] do
    empty_endpoint("/session/{sessionID}/prompt_async", :post)
  end

  defp maybe_measure_prompt_async(host, port, session_path, prompt) when is_binary(prompt) do
    body = %{
      "noReply" => true,
      "parts" => [
        %{
          "type" => "text",
          "text" => prompt
        }
      ]
    }

    {measurement, _body} =
      timed_http_request(:post, host, port, session_path <> "/prompt_async", body)

    measurement
  end

  defp session_id_from_body(body) do
    with {:ok, %{"id" => session_id}} when is_binary(session_id) <- Json.decode(body) do
      {:ok, session_id}
    else
      {:ok, decoded} ->
        {:error, "session create response did not include id: #{inspect(decoded)}"}

      {:error, reason} ->
        {:error, "session create response was not JSON: #{inspect(reason)}"}
    end
  end

  defp measure_sse_first_event(host, port, path) do
    started_at = now_us()

    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        try do
          request = [
            "GET ",
            path,
            " HTTP/1.1\r\n",
            "Host: ",
            host,
            ":",
            Integer.to_string(port),
            "\r\n",
            "Accept: text/event-stream\r\n",
            "Connection: close\r\n\r\n"
          ]

          case :gen_tcp.send(socket, request) do
            :ok ->
              sse_result(started_at, path, recv_until_sse_event(socket, "", @sse_timeout_ms))

            {:error, reason} ->
              sse_error(started_at, path, reason)
          end
        after
          :gen_tcp.close(socket)
        end

      {:error, reason} ->
        sse_error(started_at, path, reason)
    end
  end

  defp recv_until_sse_event(_socket, acc, remaining_ms) when remaining_ms <= 0 do
    if acc == "" do
      {:error, :timeout}
    else
      {:ok, acc}
    end
  end

  defp recv_until_sse_event(socket, acc, remaining_ms) do
    started_at_ms = System.monotonic_time(:millisecond)

    case :gen_tcp.recv(socket, 0, remaining_ms) do
      {:ok, chunk} ->
        acc = acc <> chunk

        if String.contains?(acc, "data:") do
          {:ok, acc}
        else
          elapsed_ms = System.monotonic_time(:millisecond) - started_at_ms
          recv_until_sse_event(socket, acc, remaining_ms - elapsed_ms)
        end

      {:error, :closed} when acc != "" ->
        {:ok, acc}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sse_result(started_at, path, {:ok, raw}) do
    status = raw_http_status(raw)
    first_event = first_sse_event(raw)

    %{
      path: path,
      status: status,
      duration_us: now_us() - started_at,
      bytes: byte_size(raw),
      ok: status == 200 and not is_nil(first_event),
      first_event: first_event,
      error: nil
    }
  end

  defp sse_result(started_at, path, {:error, reason}) do
    sse_error(started_at, path, reason)
  end

  defp sse_error(started_at, path, reason) do
    %{
      path: path,
      status: nil,
      duration_us: now_us() - started_at,
      bytes: 0,
      ok: false,
      first_event: nil,
      error: inspect(reason)
    }
  end

  defp raw_http_status(raw) do
    raw
    |> String.split("\r\n", parts: 2)
    |> List.first()
    |> case do
      nil ->
        nil

      line ->
        case Regex.run(~r/^HTTP\/\d(?:\.\d)?\s+(\d{3})/, line) do
          [_, status] -> String.to_integer(status)
          _ -> nil
        end
    end
  end

  defp first_sse_event(raw) do
    case String.split(raw, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        body =
          if String.contains?(String.downcase(headers), "transfer-encoding: chunked") do
            decode_chunked_body(body)
          else
            body
          end

        body
        |> String.split("\n\n", parts: 2)
        |> List.first()
        |> String.trim()
        |> case do
          "" -> nil
          event -> String.slice(event, 0, 500)
        end

      _ ->
        nil
    end
  end

  defp decode_chunked_body(body) do
    body
    |> do_decode_chunked_body("")
    |> case do
      "" -> body
      decoded -> decoded
    end
  end

  defp do_decode_chunked_body("", acc), do: acc

  defp do_decode_chunked_body(body, acc) do
    with [size_line, rest] <- String.split(body, "\r\n", parts: 2),
         {size, ""} <- Integer.parse(size_line, 16),
         true <- byte_size(rest) >= size + 2 do
      <<chunk::binary-size(size), "\r\n", next::binary>> = rest

      if size == 0 do
        acc
      else
        do_decode_chunked_body(next, acc <> chunk)
      end
    else
      _ -> acc
    end
  end

  defp empty_session_lifecycle do
    %{
      created: false,
      session_id: nil,
      create: empty_endpoint("/session", :post),
      messages: empty_endpoint("/session/{sessionID}/message"),
      server_status: empty_endpoint("/session/status"),
      prompt_async: empty_endpoint("/session/{sessionID}/prompt_async", :post),
      delete: empty_endpoint("/session/{sessionID}", :delete),
      error: "not_attempted"
    }
  end

  defp empty_sse(path) do
    %{
      path: path,
      status: nil,
      duration_us: 0,
      bytes: 0,
      ok: false,
      first_event: nil,
      error: "not_attempted"
    }
  end

  defp empty_endpoint(path, method \\ :get) do
    %{
      path: path,
      method: method,
      status: nil,
      duration_us: 0,
      bytes: 0,
      ok: false,
      error: "not_attempted"
    }
  end

  defp http_get(host, port, path) do
    http_request(:get, host, port, path, nil)
  end

  defp http_request(method, host, port, path, body) do
    :inets.start()

    url = ~c"http://#{host}:#{port}#{path}"
    request = http_request_tuple(method, url, body)

    case :httpc.request(method, request, [timeout: @request_timeout_ms, connect_timeout: 1_000],
           body_format: :binary
         ) do
      {:ok, {{_version, status, _reason}, _headers, body}} -> {:ok, status, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp http_request_tuple(method, url, _body) when method in [:get, :delete] do
    {url, []}
  end

  defp http_request_tuple(:post, url, body) when is_map(body) do
    {url, [], ~c"application/json", Json.encode!(body)}
  end

  defp version_from_health(body) do
    with {:ok, %{"version" => version}} when is_binary(version) <- Json.decode(body) do
      version
    else
      _ -> nil
    end
  end

  defp drain_port_lines(port, acc) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        drain_port_lines(port, [sanitize_line(line) | acc])

      {^port, {:data, {:noeol, line}}} ->
        drain_port_lines(port, [sanitize_line(line) | acc])

      {^port, {:exit_status, status}} ->
        drain_port_lines(port, ["exit_status=#{status}" | acc])
    after
      0 ->
        acc
        |> Enum.reverse()
        |> Enum.take(20)
    end
  end

  defp sanitize_line(line) do
    line
    |> to_string()
    |> String.replace(~r/\e\[[0-9;]*m/, "")
    |> String.trim()
    |> String.slice(0, 500)
  end

  defp stop_port(port) do
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} when is_integer(pid) -> pid
        _ -> nil
      end

    if Port.info(port) do
      Port.close(port)
    end

    if is_integer(os_pid) do
      # `opencode serve` can survive a closed BEAM port; terminate the OS
      # process so profiling runs do not leak local servers.
      Process.sleep(25)
      terminate_os_process(os_pid)
    end
  rescue
    ArgumentError -> :ok
  end

  defp terminate_os_process(os_pid) do
    case System.find_executable("kill") do
      nil ->
        :ok

      kill ->
        System.cmd(kill, [Integer.to_string(os_pid)], stderr_to_stdout: true)
        :ok
    end
  rescue
    _ -> :ok
  end

  defp random_port do
    # Keep clear of well-known ports while reducing collision risk.
    42_000 + :rand.uniform(10_000)
  end

  defp now_us, do: System.monotonic_time(:microsecond)
end
