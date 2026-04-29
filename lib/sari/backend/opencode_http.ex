defmodule Sari.Backend.OpenCodeHttp do
  @moduledoc """
  OpenCode HTTP/SSE runtime adapter.

  Verified upstream surface:

    * `opencode serve` starts a headless HTTP server.
    * `/doc` exposes an OpenAPI specification.
    * `/global/event` exposes server-sent events.
    * `POST /session` creates sessions.
    * `GET /session/:id` resumes/fetches sessions.
    * `POST /session/:id/prompt_async` accepts prompt parts.
    * `POST /session/:id/abort` cancels in-flight work.

  The adapter intentionally implements only the measured compatibility subset.
  Unknown OpenCode event types are ignored unless they map to a Sari primitive.
  """

  @behaviour Sari.RuntimeBackend

  alias Sari.{Json, RuntimeCapabilities, RuntimeError, RuntimeEvent, Session}

  @default_base_url "http://127.0.0.1:4096"
  @default_event_path "/global/event"
  @default_connect_timeout_ms 1_000
  @default_request_timeout_ms 5_000
  @default_event_timeout_ms 30_000
  @default_turn_timeout_ms 300_000
  @default_max_events 1_000

  @impl true
  def capabilities(opts \\ []) do
    %RuntimeCapabilities{
      backend: :opencode_http,
      name: "OpenCode HTTP/SSE",
      transport: :http_sse,
      supports: %{
        sessions: true,
        resume: true,
        streaming_events: true,
        approvals: true,
        dynamic_tools: :degraded,
        filesystem: true,
        command_execution: true,
        cancellation: true,
        token_usage: :degraded,
        tool_calls: true,
        approval_requests: :degraded,
        cost: false,
        cancel: true,
        workspace_mode: true,
        context_limit: :degraded
      },
      unsupported: %{
        dynamic_tools: :requires_mapping_to_opencode_tools_or_mcp,
        token_usage: :live_token_usage_needs_black_box_verification,
        approval_requests: :permission_request_mapping_needs_real_backend_verification,
        cost: :not_reported_by_verified_lm_studio_probe,
        context_limit: :configured_by_model_server_or_sari_context_limit_tokens
      },
      metadata: %{
        command: "opencode serve",
        docs: [
          "https://opencode.ai/docs/cli/",
          "https://dev.opencode.ai/docs/server/",
          "https://opencode.ai/docs/acp/"
        ],
        context_limit_tokens: Keyword.get(opts, :context_limit_tokens),
        endpoints: %{
          docs: "/doc",
          events: @default_event_path,
          create_session: "/session",
          prompt_async: "/session/:id/prompt_async",
          abort: "/session/:id/abort"
        }
      }
    }
  end

  @impl true
  def start_session(params, opts \\ []) when is_map(params) do
    base_url = base_url(opts)

    case request(:post, base_url, "/session", create_session_body(params), opts) do
      {:ok, status, body} when status in 200..299 ->
        session_from_response(body, params, base_url, resumed?: false)

      {:ok, status, body} ->
        {:error, {:opencode_http_error, :start_session, status, body_excerpt(body)}}

      {:error, reason} ->
        {:error, {:opencode_transport_error, :start_session, reason}}
    end
  end

  @impl true
  def resume_session(session_id, opts \\ []) when is_binary(session_id) do
    base_url = base_url(opts)
    path = "/session/#{url_path_segment(session_id)}"

    case request(:get, base_url, path, nil, opts) do
      {:ok, status, body} when status in 200..299 ->
        session_from_response(body, %{}, base_url, resumed?: true)

      {:ok, status, body} ->
        {:error, {:opencode_http_error, :resume_session, status, body_excerpt(body)}}

      {:error, reason} ->
        {:error, {:opencode_transport_error, :resume_session, reason}}
    end
  end

  @impl true
  def start_turn(%Session{} = session, input, opts \\ []) do
    base_url = base_url(opts, session)
    turn_id = Keyword.get(opts, :turn_id, "opencode-turn-#{System.unique_integer([:positive])}")

    {:ok, turn_stream(session, input, base_url, turn_id, opts)}
  end

  @impl true
  def interrupt(%Session{} = session, turn_id, opts \\ []) when is_binary(turn_id) do
    base_url = base_url(opts, session)
    path = "/session/#{url_path_segment(session.id)}/abort"

    case request(:post, base_url, path, %{}, opts) do
      {:ok, status, _body} when status in 200..299 ->
        :ok

      {:ok, status, body} ->
        {:error, {:opencode_http_error, :interrupt, status, body_excerpt(body)}}

      {:error, reason} ->
        {:error, {:opencode_transport_error, :interrupt, reason}}
    end
  end

  defp create_session_body(params) do
    %{
      "parentID" => map_get(params, :parent_id, "parentID"),
      "title" =>
        map_get(params, :title, "title") || map_get(params, :cwd, "cwd") || "Sari session",
      "permission" => map_get(params, :permission, "permission"),
      "workspaceID" => map_get(params, :workspace_id, "workspaceID")
    }
    |> reject_nil_values()
  end

  defp session_from_response(body, params, base_url, opts) do
    with {:ok, decoded} when is_map(decoded) <- Json.decode(body),
         id when is_binary(id) <- decoded["id"] do
      cwd = decoded["directory"] || map_get(params, :cwd, "cwd")

      {:ok,
       Session.new(id, :opencode_http,
         cwd: cwd,
         metadata: %{
           backend: :opencode_http,
           base_url: base_url,
           opencode: decoded,
           resumed: Keyword.fetch!(opts, :resumed?)
         }
       )}
    else
      {:ok, decoded} ->
        {:error, {:invalid_opencode_session_response, decoded}}

      {:error, reason} ->
        {:error, {:invalid_opencode_session_json, reason}}

      nil ->
        {:error, {:invalid_opencode_session_response, body_excerpt(body)}}
    end
  end

  defp turn_stream(%Session{} = session, input, base_url, turn_id, opts) do
    Stream.resource(
      fn ->
        %{
          phase: :init,
          base_url: base_url,
          event_path: Keyword.get(opts, :event_path, @default_event_path),
          event_timeout_ms: Keyword.get(opts, :event_timeout_ms, @default_event_timeout_ms),
          turn_timeout_ms: Keyword.get(opts, :turn_timeout_ms, @default_turn_timeout_ms),
          deadline_ms:
            System.monotonic_time(:millisecond) +
              Keyword.get(opts, :turn_timeout_ms, @default_turn_timeout_ms),
          max_events: Keyword.get(opts, :max_events, @default_max_events),
          request_opts: opts,
          session: session,
          turn_id: turn_id,
          input: input,
          prompt_body: prompt_body(input, opts),
          no_reply?: Keyword.get(opts, :no_reply, false),
          stream?: Keyword.get(opts, :stream, true),
          event_count: 0,
          message_roles: %{},
          sse: nil
        }
      end,
      &next_turn_events/1,
      &cleanup_turn_stream/1
    )
  end

  defp next_turn_events(%{phase: :done} = state), do: {:halt, state}

  defp next_turn_events(%{phase: :init, stream?: false} = state) do
    started = turn_started_event(state)

    case post_prompt(state) do
      {:ok, _status, _body} ->
        {[started, turn_completed_event(state, %{mode: :non_streaming})], %{state | phase: :done}}

      {:error, reason} ->
        {[started, turn_failed_event(state, reason)], %{state | phase: :done}}
    end
  end

  defp next_turn_events(%{phase: :init, no_reply?: true} = state) do
    started = turn_started_event(state)

    case post_prompt(state) do
      {:ok, _status, _body} ->
        {[started, turn_completed_event(state, %{mode: :no_reply})], %{state | phase: :done}}

      {:error, reason} ->
        {[started, turn_failed_event(state, reason)], %{state | phase: :done}}
    end
  end

  defp next_turn_events(%{phase: :init} = state) do
    started = turn_started_event(state)

    with {:ok, sse} <- connect_sse(state.base_url, state.event_path, state.request_opts),
         {:ok, _status, _body} <- post_prompt(state) do
      {[started], %{state | phase: :events, sse: sse}}
    else
      {:error, reason} ->
        {[started, turn_failed_event(state, reason)], %{state | phase: :done}}
    end
  end

  defp next_turn_events(%{phase: :events, event_count: count, max_events: max_events} = state)
       when count >= max_events do
    failed = turn_failed_event(state, {:max_events_exceeded, max_events})
    {[failed], %{state | phase: :done}}
  end

  defp next_turn_events(%{phase: :events} = state) do
    remaining_ms = state.deadline_ms - System.monotonic_time(:millisecond)

    cond do
      remaining_ms <= 0 ->
        _ = interrupt(state.session, state.turn_id, state.request_opts)
        failed = turn_failed_event(state, :turn_timeout)
        {[failed], %{state | phase: :done}}

      true ->
        read_timeout_ms = min(state.event_timeout_ms, remaining_ms)

        case read_sse_event(state.sse, read_timeout_ms) do
          {:ok, raw_event, sse} ->
            {events, state} =
              map_sse_event(raw_event, %{state | sse: sse, event_count: state.event_count + 1})

            cond do
              events == [] ->
                {[], state}

              Enum.any?(events, &RuntimeEvent.terminal?/1) ->
                {events, %{state | phase: :done}}

              true ->
                {events, state}
            end

          {:error, reason, sse} ->
            failed = turn_failed_event(%{state | sse: sse}, reason)
            {[failed], %{state | phase: :done, sse: sse}}
        end
    end
  end

  defp post_prompt(state) do
    path = "/session/#{url_path_segment(state.session.id)}/prompt_async"

    case request(:post, state.base_url, path, state.prompt_body, state.request_opts) do
      {:ok, status, body} when status in 200..299 ->
        {:ok, status, body}

      {:ok, status, body} ->
        {:error, {:opencode_http_error, :start_turn, status, body_excerpt(body)}}

      {:error, reason} ->
        {:error, {:opencode_transport_error, :start_turn, reason}}
    end
  end

  defp prompt_body(input, opts) do
    %{
      "messageID" => Keyword.get(opts, :message_id),
      "model" => Keyword.get(opts, :model),
      "agent" => Keyword.get(opts, :agent),
      "noReply" => Keyword.get(opts, :no_reply, false),
      "tools" => Keyword.get(opts, :tools),
      "format" => Keyword.get(opts, :format),
      "system" => Keyword.get(opts, :system),
      "variant" => Keyword.get(opts, :variant),
      "parts" => prompt_parts(input)
    }
    |> reject_nil_values()
  end

  defp prompt_parts(input) when is_binary(input) do
    [%{"type" => "text", "text" => input}]
  end

  defp prompt_parts(%{"parts" => parts}) when is_list(parts),
    do: Enum.map(parts, &normalize_part/1)

  defp prompt_parts(%{parts: parts}) when is_list(parts), do: Enum.map(parts, &normalize_part/1)
  defp prompt_parts(parts) when is_list(parts), do: Enum.map(parts, &normalize_part/1)

  defp prompt_parts(other) do
    [%{"type" => "text", "text" => inspect(other)}]
  end

  defp normalize_part(part) when is_map(part) do
    part
    |> Map.new(fn {key, value} -> {normalize_json_key(key), value} end)
    |> Map.put_new("type", "text")
  end

  defp normalize_part(part) when is_binary(part), do: %{"type" => "text", "text" => part}
  defp normalize_part(part), do: %{"type" => "text", "text" => inspect(part)}

  defp turn_started_event(state) do
    RuntimeEvent.new(:turn_started, %{input: state.input},
      session_id: state.session.id,
      turn_id: state.turn_id,
      metadata: %{backend: :opencode_http}
    )
  end

  defp turn_completed_event(state, payload) do
    RuntimeEvent.new(:turn_completed, payload,
      session_id: state.session.id,
      turn_id: state.turn_id,
      metadata: %{backend: :opencode_http}
    )
  end

  defp turn_failed_event(state, reason) do
    error = RuntimeError.normalize(reason, backend: :opencode_http, stage: :turn)

    RuntimeEvent.new(:turn_failed, RuntimeError.to_payload(error),
      session_id: state.session.id,
      turn_id: state.turn_id,
      metadata: %{backend: :opencode_http}
    )
  end

  defp map_sse_event(raw_event, state) do
    with {:ok, decoded} <- decode_sse_data(raw_event),
         true <- event_for_session?(decoded, state.session.id) do
      map_opencode_event(decoded, state)
    else
      false ->
        {[], state}

      {:error, reason} ->
        event =
          RuntimeEvent.new(:error, %{reason: {:invalid_sse_event, reason}},
            session_id: state.session.id,
            turn_id: state.turn_id,
            raw: raw_event,
            metadata: %{backend: :opencode_http}
          )

        {[event], state}
    end
  end

  defp map_opencode_event(decoded, state) do
    payload = Map.get(decoded, "payload", %{})
    type = Map.get(payload, "type")
    properties = Map.get(payload, "properties", %{})

    case type do
      "message.updated" ->
        message = Map.get(properties, "info", %{})
        message_id = Map.get(message, "id")
        role = Map.get(message, "role")

        state =
          if is_binary(message_id) and is_binary(role) do
            put_in(state.message_roles[message_id], role)
          else
            state
          end

        {[], state}

      "message.part.updated" ->
        part = Map.get(properties, "part", %{})
        message_id = Map.get(part, "messageID")
        role = Map.get(state.message_roles, message_id)
        part_type = Map.get(part, "type")
        text = Map.get(part, "text")

        cond do
          role == "assistant" and part_type == "text" and is_binary(text) and text != "" ->
            event =
              RuntimeEvent.new(:assistant_delta, %{text: text, part: part},
                session_id: state.session.id,
                turn_id: state.turn_id,
                raw: decoded,
                metadata: %{backend: :opencode_http, opencode_event: type}
              )

            {[event], state}

          part_type == "step-finish" and is_map(part["tokens"]) ->
            event =
              RuntimeEvent.new(:token_usage, part["tokens"],
                session_id: state.session.id,
                turn_id: state.turn_id,
                raw: decoded,
                metadata: %{backend: :opencode_http, opencode_event: type}
              )

            {[event], state}

          true ->
            {[], state}
        end

      "session.status" ->
        status = get_in(properties, ["status", "type"])

        case status do
          "idle" ->
            event =
              turn_completed_event(state, %{
                reason: :session_idle,
                opencode_event: type
              })

            {[%RuntimeEvent{event | raw: decoded}], state}

          "error" ->
            event =
              RuntimeEvent.new(:turn_failed, properties,
                session_id: state.session.id,
                turn_id: state.turn_id,
                raw: decoded,
                metadata: %{backend: :opencode_http, opencode_event: type}
              )

            {[event], state}

          _other ->
            {[], state}
        end

      "message.part.delta" ->
        part = Map.get(properties, "part", %{})
        message_id = Map.get(part, "messageID")
        role = Map.get(state.message_roles, message_id)
        text = Map.get(properties, "text") || Map.get(part, "text")

        if role == "assistant" and is_binary(text) and text != "" do
          event =
            RuntimeEvent.new(:assistant_delta, %{text: text, part: part},
              session_id: state.session.id,
              turn_id: state.turn_id,
              raw: decoded,
              metadata: %{backend: :opencode_http, opencode_event: type}
            )

          {[event], state}
        else
          {[], state}
        end

      "tool.call" ->
        event =
          RuntimeEvent.new(:tool_started, properties,
            session_id: state.session.id,
            turn_id: state.turn_id,
            raw: decoded,
            metadata: %{backend: :opencode_http, opencode_event: type}
          )

        {[event], state}

      "permission.replied" ->
        event =
          RuntimeEvent.new(:approval_requested, properties,
            session_id: state.session.id,
            turn_id: state.turn_id,
            raw: decoded,
            metadata: %{backend: :opencode_http, opencode_event: type}
          )

        {[event], state}

      "session.compacted" ->
        event =
          RuntimeEvent.new(:plan_update, properties,
            session_id: state.session.id,
            turn_id: state.turn_id,
            raw: decoded,
            metadata: %{backend: :opencode_http, opencode_event: type}
          )

        {[event], state}

      "session.idle" ->
        event =
          turn_completed_event(state, %{
            reason: :session_idle,
            opencode_event: type
          })

        {[%RuntimeEvent{event | raw: decoded}], state}

      "session.error" ->
        event =
          RuntimeEvent.new(:turn_failed, properties,
            session_id: state.session.id,
            turn_id: state.turn_id,
            raw: decoded,
            metadata: %{backend: :opencode_http, opencode_event: type}
          )

        {[event], state}

      _ignored ->
        {[], state}
    end
  end

  defp event_for_session?(decoded, session_id) do
    case event_session_id(decoded) do
      nil -> false
      ^session_id -> true
      _other -> false
    end
  end

  defp event_session_id(%{"payload" => %{"properties" => %{"sessionID" => session_id}}})
       when is_binary(session_id),
       do: session_id

  defp event_session_id(%{
         "payload" => %{"properties" => %{"info" => %{"sessionID" => session_id}}}
       })
       when is_binary(session_id),
       do: session_id

  defp event_session_id(%{
         "payload" => %{"properties" => %{"part" => %{"sessionID" => session_id}}}
       })
       when is_binary(session_id),
       do: session_id

  defp event_session_id(%{
         "payload" => %{"syncEvent" => %{"data" => %{"sessionID" => session_id}}}
       })
       when is_binary(session_id),
       do: session_id

  defp event_session_id(%{"payload" => %{"syncEvent" => %{"aggregateID" => session_id}}})
       when is_binary(session_id),
       do: session_id

  defp event_session_id(_decoded), do: nil

  defp decode_sse_data(raw_event) do
    data =
      raw_event
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case String.trim_leading(line) do
          "data:" <> value -> [String.trim_leading(value)]
          _ -> []
        end
      end)
      |> Enum.join("\n")

    Json.decode(data)
  end

  defp connect_sse(base_url, path, opts) do
    with {:ok, uri} <- parse_http_base_url(base_url),
         {:ok, socket} <-
           :gen_tcp.connect(
             String.to_charlist(uri.host),
             uri.port,
             [:binary, active: false],
             Keyword.get(opts, :connect_timeout_ms, @default_connect_timeout_ms)
           ),
         :ok <- send_sse_request(socket, uri, path),
         {:ok, headers, body_remainder} <-
           read_http_headers(
             socket,
             Keyword.get(opts, :request_timeout_ms, @default_request_timeout_ms)
           ),
         {:ok, status} <- parse_sse_status(headers),
         true <- status in 200..299 || {:error, {:sse_http_error, status, body_remainder}} do
      chunked? = String.contains?(String.downcase(headers), "transfer-encoding: chunked")
      sse = %{socket: socket, chunked?: chunked?, raw_buffer: "", body_buffer: "", closed?: false}
      {:ok, append_sse_bytes(sse, body_remainder)}
    else
      {:error, reason} ->
        {:error, reason}

      {:ok, socket} ->
        :gen_tcp.close(socket)
        {:error, :invalid_sse_response}
    end
  end

  defp send_sse_request(socket, uri, path) do
    request_path = normalize_request_path(uri, path)

    :gen_tcp.send(socket, [
      "GET ",
      request_path,
      " HTTP/1.1\r\n",
      "Host: ",
      uri.host,
      ":",
      Integer.to_string(uri.port),
      "\r\n",
      "Accept: text/event-stream\r\n",
      "Connection: close\r\n\r\n"
    ])
  end

  defp read_sse_event(sse, timeout_ms) do
    do_read_sse_event(sse, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp do_read_sse_event(sse, deadline_ms) do
    case take_sse_event(sse) do
      {:ok, event, sse} ->
        {:ok, event, sse}

      :none ->
        remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

        cond do
          remaining_ms <= 0 ->
            {:error, :event_timeout, sse}

          sse.closed? ->
            {:error, :event_stream_closed, sse}

          true ->
            case :gen_tcp.recv(sse.socket, 0, remaining_ms) do
              {:ok, bytes} ->
                sse |> append_sse_bytes(bytes) |> do_read_sse_event(deadline_ms)

              {:error, :closed} ->
                %{sse | closed?: true} |> do_read_sse_event(deadline_ms)

              {:error, reason} ->
                {:error, reason, sse}
            end
        end
    end
  end

  defp take_sse_event(%{body_buffer: body_buffer} = sse) do
    case :binary.match(body_buffer, "\n\n") do
      {index, 2} ->
        <<event::binary-size(index), "\n\n", rest::binary>> = body_buffer
        {:ok, event, %{sse | body_buffer: rest}}

      :nomatch ->
        :none
    end
  end

  defp append_sse_bytes(%{chunked?: false} = sse, bytes) do
    %{sse | body_buffer: sse.body_buffer <> normalize_sse_body(bytes)}
  end

  defp append_sse_bytes(%{chunked?: true} = sse, bytes) do
    {decoded, raw_buffer, closed?} = decode_http_chunks(sse.raw_buffer <> bytes, "")

    %{
      sse
      | raw_buffer: raw_buffer,
        body_buffer: sse.body_buffer <> normalize_sse_body(decoded),
        closed?: sse.closed? or closed?
    }
  end

  defp decode_http_chunks("", acc), do: {acc, "", false}

  defp decode_http_chunks(buffer, acc) do
    with [size_line, rest] <- String.split(buffer, "\r\n", parts: 2),
         {size, ""} <- size_line |> String.split(";", parts: 2) |> hd() |> Integer.parse(16),
         true <- byte_size(rest) >= size + 2 do
      <<chunk::binary-size(size), "\r\n", next::binary>> = rest

      if size == 0 do
        {acc, next, true}
      else
        decode_http_chunks(next, acc <> chunk)
      end
    else
      _ -> {acc, buffer, false}
    end
  end

  defp normalize_sse_body(body), do: String.replace(body, "\r\n", "\n")

  defp cleanup_turn_stream(%{sse: %{socket: socket}}), do: :gen_tcp.close(socket)
  defp cleanup_turn_stream(_state), do: :ok

  defp request(method, base_url, path, body, opts) do
    :inets.start()

    url = request_url(base_url, path)
    request = request_tuple(method, url, body)

    case :httpc.request(
           method,
           request,
           [
             timeout: Keyword.get(opts, :request_timeout_ms, @default_request_timeout_ms),
             connect_timeout: Keyword.get(opts, :connect_timeout_ms, @default_connect_timeout_ms)
           ],
           body_format: :binary
         ) do
      {:ok, {{_version, status, _reason}, _headers, body}} -> {:ok, status, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_tuple(method, url, _body) when method in [:get, :delete], do: {url, []}

  defp request_tuple(:post, url, body),
    do: {url, [], ~c"application/json", Json.encode!(body || %{})}

  defp request_url(base_url, path) do
    base_url
    |> String.trim_trailing("/")
    |> Kernel.<>(path)
    |> String.to_charlist()
  end

  defp read_http_headers(socket, timeout_ms) do
    read_http_headers(socket, "", System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp read_http_headers(socket, acc, deadline_ms) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        {:ok, headers, body}

      [_partial] ->
        remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

        if remaining_ms <= 0 do
          {:error, :header_timeout}
        else
          case :gen_tcp.recv(socket, 0, remaining_ms) do
            {:ok, bytes} -> read_http_headers(socket, acc <> bytes, deadline_ms)
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  defp parse_sse_status(headers) do
    headers
    |> String.split("\r\n", parts: 2)
    |> List.first()
    |> case do
      nil ->
        {:error, :missing_http_status}

      line ->
        case Regex.run(~r/^HTTP\/\d(?:\.\d)?\s+(\d{3})/, line) do
          [_, status] -> {:ok, String.to_integer(status)}
          _ -> {:error, {:invalid_http_status, line}}
        end
    end
  end

  defp parse_http_base_url(base_url) do
    uri = URI.parse(base_url)

    cond do
      uri.scheme != "http" ->
        {:error, {:unsupported_opencode_scheme, uri.scheme}}

      is_nil(uri.host) ->
        {:error, {:invalid_base_url, base_url}}

      true ->
        {:ok, %{uri | port: uri.port || 80}}
    end
  end

  defp normalize_request_path(uri, path) do
    uri_path =
      case uri.path do
        nil -> ""
        "/" -> ""
        value -> String.trim_trailing(value, "/")
      end

    uri_path <> path
  end

  defp base_url(opts) do
    opts
    |> Keyword.get(:base_url, @default_base_url)
    |> String.trim_trailing("/")
  end

  defp base_url(opts, %Session{} = session) do
    opts[:base_url] || session.metadata[:base_url] || @default_base_url
  end

  defp map_get(map, atom_key, string_key) do
    Map.get(map, atom_key) || Map.get(map, string_key)
  end

  defp normalize_json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_json_key(key) when is_binary(key), do: key
  defp normalize_json_key(key), do: to_string(key)

  defp reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp url_path_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp body_excerpt(body) when is_binary(body), do: String.slice(body, 0, 500)
  defp body_excerpt(body), do: inspect(body)
end
