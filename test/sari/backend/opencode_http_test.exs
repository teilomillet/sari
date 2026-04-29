defmodule Sari.Backend.OpenCodeHttpTest do
  use ExUnit.Case, async: true

  alias Sari.Backend.OpenCodeHttp
  alias Sari.{Json, Runtime}

  setup do
    {:ok, server} = __MODULE__.FakeOpenCodeServer.start(default_events())
    on_exit(fn -> __MODULE__.FakeOpenCodeServer.stop(server) end)

    {:ok, server: server}
  end

  test "starts and resumes sessions through OpenCode HTTP", %{server: server} do
    assert {:ok, session} =
             Runtime.start_session(OpenCodeHttp, %{title: "Sari test", cwd: "/tmp/sari"},
               base_url: server.base_url
             )

    assert session.id == "ses_test"
    assert session.backend == :opencode_http
    assert session.cwd == "/tmp/sari-opencode"
    assert session.metadata.base_url == server.base_url
    assert session.metadata.opencode["version"] == "1.14.29"

    assert_receive {:fake_opencode_request, "POST", "/session", %{"title" => "Sari test"}}

    assert {:ok, resumed} =
             Runtime.resume_session(OpenCodeHttp, "ses_test", base_url: server.base_url)

    assert resumed.id == "ses_test"
    assert resumed.metadata.resumed
    assert_receive {:fake_opencode_request, "GET", "/session/ses_test", ""}
  end

  test "streams assistant deltas, token usage, and terminal session.status from SSE", %{
    server: server
  } do
    {:ok, session} =
      Runtime.start_session(OpenCodeHttp, %{title: "Sari stream"}, base_url: server.base_url)

    assert {:ok, result} =
             Runtime.collect_turn(OpenCodeHttp, session, "say hi",
               base_url: server.base_url,
               turn_id: "turn-1",
               event_timeout_ms: 1_000
             )

    assert Enum.map(result.events, & &1.type) == [
             :turn_started,
             :assistant_delta,
             :token_usage,
             :turn_completed
           ]

    assert Enum.at(result.events, 1).payload.text == "hello from opencode"
    assert Enum.at(result.events, 2).payload["total"] == 12
    assert result.terminal.payload.reason == :session_idle
    assert Enum.all?(result.events, &(&1.session_id == "ses_test"))
    assert Enum.all?(result.events, &(&1.turn_id == "turn-1"))

    assert_receive {:fake_opencode_request, "POST", "/session/ses_test/prompt_async",
                    %{
                      "noReply" => false,
                      "parts" => [%{"type" => "text", "text" => "say hi"}]
                    }}
  end

  test "supports noReply smoke turns without waiting on SSE terminal events", %{server: server} do
    {:ok, session} =
      Runtime.start_session(OpenCodeHttp, %{title: "Sari no reply"}, base_url: server.base_url)

    assert {:ok, result} =
             Runtime.collect_turn(OpenCodeHttp, session, "record only",
               base_url: server.base_url,
               turn_id: "turn-no-reply",
               no_reply: true
             )

    assert Enum.map(result.events, & &1.type) == [:turn_started, :turn_completed]
    assert result.terminal.payload.mode == :no_reply

    assert_receive {:fake_opencode_request, "POST", "/session/ses_test/prompt_async",
                    %{
                      "noReply" => true,
                      "parts" => [%{"type" => "text", "text" => "record only"}]
                    }}
  end

  test "interrupt maps to OpenCode abort endpoint", %{server: server} do
    {:ok, session} =
      Runtime.start_session(OpenCodeHttp, %{title: "Sari abort"}, base_url: server.base_url)

    assert :ok = Runtime.interrupt(OpenCodeHttp, session, "turn-1", base_url: server.base_url)
    assert_receive {:fake_opencode_request, "POST", "/session/ses_test/abort", %{}}
  end

  defp default_events do
    [
      %{"payload" => %{"type" => "server.connected", "properties" => %{}}},
      %{
        "payload" => %{
          "type" => "message.updated",
          "properties" => %{
            "sessionID" => "ses_test",
            "info" => %{
              "id" => "msg_assistant",
              "role" => "assistant",
              "sessionID" => "ses_test"
            }
          }
        }
      },
      %{
        "payload" => %{
          "type" => "message.part.updated",
          "properties" => %{
            "sessionID" => "ses_test",
            "part" => %{
              "type" => "text",
              "text" => "hello from opencode",
              "messageID" => "msg_assistant",
              "sessionID" => "ses_test"
            }
          }
        }
      },
      %{
        "payload" => %{
          "type" => "message.part.updated",
          "properties" => %{
            "sessionID" => "ses_test",
            "part" => %{
              "type" => "step-finish",
              "messageID" => "msg_assistant",
              "sessionID" => "ses_test",
              "tokens" => %{
                "input" => 10,
                "output" => 2,
                "total" => 12
              }
            }
          }
        }
      },
      %{
        "payload" => %{
          "type" => "session.status",
          "properties" => %{
            "sessionID" => "ses_test",
            "status" => %{"type" => "idle"}
          }
        }
      }
    ]
  end

  defmodule FakeOpenCodeServer do
    defstruct [:base_url, :listener, :pid]

    def start(events) do
      {:ok, listener} =
        :gen_tcp.listen(0, [
          :binary,
          packet: :raw,
          active: false,
          reuseaddr: true,
          ip: {127, 0, 0, 1}
        ])

      {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
      parent = self()
      pid = spawn_link(fn -> accept_loop(listener, parent, events) end)

      {:ok, %__MODULE__{base_url: "http://127.0.0.1:#{port}", listener: listener, pid: pid}}
    end

    def stop(%__MODULE__{listener: listener, pid: pid}) do
      :gen_tcp.close(listener)

      if Process.alive?(pid) do
        Process.exit(pid, :shutdown)
      end
    end

    defp accept_loop(listener, parent, events) do
      case :gen_tcp.accept(listener) do
        {:ok, socket} ->
          spawn_link(fn -> handle_socket(socket, parent, events) end)
          accept_loop(listener, parent, events)

        {:error, :closed} ->
          :ok
      end
    end

    defp handle_socket(socket, parent, events) do
      case read_request(socket) do
        {:ok, method, path, body} ->
          decoded = decode_body(body)
          send(parent, {:fake_opencode_request, method, path, decoded})
          respond(socket, method, path, events)

        {:error, reason} ->
          send(parent, {:fake_opencode_error, reason})
      end
    after
      :gen_tcp.close(socket)
    end

    defp respond(socket, "POST", "/session", _events) do
      json(socket, 200, %{
        "id" => "ses_test",
        "version" => "1.14.29",
        "directory" => "/tmp/sari-opencode",
        "time" => %{"created" => 1, "updated" => 1}
      })
    end

    defp respond(socket, "GET", "/session/ses_test", _events) do
      json(socket, 200, %{
        "id" => "ses_test",
        "version" => "1.14.29",
        "directory" => "/tmp/sari-opencode",
        "time" => %{"created" => 1, "updated" => 2}
      })
    end

    defp respond(socket, "POST", "/session/ses_test/prompt_async", _events) do
      no_content(socket)
    end

    defp respond(socket, "POST", "/session/ses_test/abort", _events) do
      no_content(socket)
    end

    defp respond(socket, "GET", "/global/event", events) do
      :ok =
        :gen_tcp.send(socket, [
          "HTTP/1.1 200 OK\r\n",
          "content-type: text/event-stream\r\n",
          "transfer-encoding: chunked\r\n",
          "connection: close\r\n\r\n"
        ])

      for event <- events do
        chunk = "data: #{Json.encode!(event)}\n\n"
        size = chunk |> byte_size() |> Integer.to_string(16)
        :ok = :gen_tcp.send(socket, [size, "\r\n", chunk, "\r\n"])
      end

      :gen_tcp.send(socket, "0\r\n\r\n")
    end

    defp respond(socket, _method, _path, _events) do
      json(socket, 404, %{"error" => "not_found"})
    end

    defp json(socket, status, body) do
      encoded = Json.encode!(body)

      :gen_tcp.send(socket, [
        "HTTP/1.1 ",
        Integer.to_string(status),
        " OK\r\n",
        "content-type: application/json\r\n",
        "content-length: ",
        Integer.to_string(byte_size(encoded)),
        "\r\n",
        "connection: close\r\n\r\n",
        encoded
      ])
    end

    defp no_content(socket) do
      :gen_tcp.send(
        socket,
        "HTTP/1.1 204 No Content\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
      )
    end

    defp read_request(socket) do
      with {:ok, headers, rest} <- read_headers(socket, ""),
           [request_line | header_lines] <- String.split(headers, "\r\n"),
           [method, path, _version] <- String.split(request_line, " ", parts: 3) do
        length = content_length(header_lines)
        {:ok, body} = read_body(socket, rest, length)
        {:ok, method, path, body}
      else
        other -> {:error, other}
      end
    end

    defp read_headers(socket, acc) do
      case String.split(acc, "\r\n\r\n", parts: 2) do
        [headers, rest] ->
          {:ok, headers, rest}

        [_partial] ->
          case :gen_tcp.recv(socket, 0, 1_000) do
            {:ok, bytes} -> read_headers(socket, acc <> bytes)
            {:error, reason} -> {:error, reason}
          end
      end
    end

    defp read_body(_socket, rest, length) when byte_size(rest) >= length do
      <<body::binary-size(length), _extra::binary>> = rest
      {:ok, body}
    end

    defp read_body(socket, rest, length) do
      case :gen_tcp.recv(socket, length - byte_size(rest), 1_000) do
        {:ok, bytes} -> read_body(socket, rest <> bytes, length)
        {:error, reason} -> {:error, reason}
      end
    end

    defp content_length(headers) do
      headers
      |> Enum.find_value("0", fn line ->
        case String.split(line, ":", parts: 2) do
          [name, value] ->
            if String.downcase(name) == "content-length", do: String.trim(value)

          _ ->
            nil
        end
      end)
      |> String.to_integer()
    end

    defp decode_body(""), do: ""

    defp decode_body(body) do
      case Json.decode(body) do
        {:ok, decoded} -> decoded
        {:error, _reason} -> body
      end
    end
  end
end
