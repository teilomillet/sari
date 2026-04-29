defmodule Sari.Mcp.EntracteTools do
  @moduledoc """
  MCP server for Entr'acte-compatible dynamic tools.

  Claude Code consumes MCP tools, while Entr'acte sends Codex app-server-style
  dynamic tool declarations during `thread/start`. This server exposes the
  current Entr'acte tool surface through a local stdio MCP process so Sari can
  keep the app-server facade backend-neutral.
  """

  alias Sari.Json

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using the runner's configured auth.

  Linear's Comment type exposes `resolvedAt` for resolved comments; do not query
  a non-existent `resolved` field.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @gitlab_coverage_tool "gitlab_coverage"
  @gitlab_coverage_description """
  Retrieve normalized GitLab pipeline coverage and status using the runner's configured GitLab auth.
  """
  @gitlab_coverage_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{
      "project_id" => %{
        "type" => ["string", "integer"],
        "description" =>
          "Optional GitLab project ID or namespace/project path. Defaults to GITLAB_PROJECT_ID."
      },
      "pipeline_id" => %{
        "type" => ["integer", "string"],
        "description" =>
          "Optional GitLab pipeline ID. When omitted, the latest pipeline endpoint is used."
      },
      "ref" => %{
        "type" => "string",
        "description" => "Optional branch or tag ref for the latest pipeline lookup."
      }
    }
  }

  @type request_result :: {:ok, non_neg_integer(), term()} | {:error, term()}

  @spec run(keyword()) :: :ok
  def run(opts \\ []) when is_list(opts) do
    loop(opts)
  end

  @spec handle_json_line(String.t(), keyword()) :: [String.t()]
  def handle_json_line(line, opts \\ []) when is_binary(line) and is_list(opts) do
    case Json.decode(line) do
      {:ok, %{"method" => method} = message} ->
        handle_message(method, message, opts)

      {:ok, _message} ->
        []

      {:error, reason} ->
        [Json.encode!(error_response(nil, -32700, "parse error: #{inspect(reason)}"))]
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      },
      %{
        "name" => @gitlab_coverage_tool,
        "description" => @gitlab_coverage_description,
        "inputSchema" => @gitlab_coverage_input_schema
      }
    ]
  end

  defp loop(opts) do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, _reason} ->
        :ok

      line ->
        line
        |> handle_json_line(opts)
        |> Enum.each(&IO.puts/1)

        loop(opts)
    end
  end

  defp handle_message("initialize", %{"id" => id}, _opts) do
    [
      result_response(id, %{
        "protocolVersion" => "2024-11-05",
        "serverInfo" => %{"name" => "sari-entracte-tools", "version" => "0.1.0"},
        "capabilities" => %{"tools" => %{"listChanged" => false}}
      })
      |> Json.encode!()
    ]
  end

  defp handle_message("notifications/initialized", _message, _opts), do: []

  defp handle_message("tools/list", %{"id" => id}, _opts) do
    [Json.encode!(result_response(id, %{"tools" => tool_specs()}))]
  end

  defp handle_message("tools/call", %{"id" => id, "params" => params}, opts)
       when is_map(params) do
    name = Map.get(params, "name")
    arguments = Map.get(params, "arguments") || %{}

    result =
      case name do
        @linear_graphql_tool -> call_linear_graphql(arguments, opts)
        @gitlab_coverage_tool -> call_gitlab_coverage(arguments, opts)
        _ -> tool_error(%{"error" => "unsupported tool", "tool" => name})
      end

    [Json.encode!(result_response(id, result))]
  end

  defp handle_message("tools/call", %{"id" => id}, _opts) do
    [Json.encode!(result_response(id, tool_error(%{"error" => "invalid tools/call params"})))]
  end

  defp handle_message(_method, %{"id" => id}, _opts) do
    [Json.encode!(error_response(id, -32601, "method not found"))]
  end

  defp handle_message(_method, _message, _opts), do: []

  defp call_linear_graphql(arguments, opts) do
    request_fun = Keyword.get(opts, :request_fun, &post_json/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, token} <- env_value("LINEAR_API_KEY"),
         {:ok, status, body} <-
           request_fun.(
             "https://api.linear.app/graphql",
             [
               {"Authorization", token},
               {"Content-Type", "application/json"}
             ],
             %{"query" => query, "variables" => variables}
           ) do
      success = status in 200..299 and not graphql_errors?(body)

      tool_result(success, %{
        "status" => status,
        "body" => body
      })
    else
      {:error, reason} -> tool_error(%{"error" => inspect(reason)})
    end
  end

  defp call_gitlab_coverage(arguments, opts) do
    request_fun = Keyword.get(opts, :request_fun, &get_json/2)

    with {:ok, endpoint} <- env_value("GITLAB_API_ENDPOINT"),
         {:ok, token} <- env_value("GITLAB_API_TOKEN"),
         {:ok, project_id} <- gitlab_project_id(arguments),
         {:ok, url} <- gitlab_coverage_url(endpoint, project_id, arguments),
         {:ok, status, body} <- request_fun.(url, [{"PRIVATE-TOKEN", token}]) do
      success = status in 200..299

      tool_result(success, %{
        "status" => status,
        "body" => if(success, do: normalize_gitlab_pipeline(body, project_id), else: body)
      })
    else
      {:error, reason} -> tool_error(%{"error" => inspect(reason)})
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    query = Map.get(arguments, "query") || Map.get(arguments, :query)
    variables = Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{}

    cond do
      not is_binary(query) or String.trim(query) == "" -> {:error, :missing_query}
      not is_map(variables) -> {:error, :invalid_variables}
      true -> {:ok, String.trim(query), variables}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp gitlab_project_id(arguments) when is_map(arguments) do
    case normalize_non_empty_string(
           Map.get(arguments, "project_id") || Map.get(arguments, :project_id)
         ) ||
           normalize_non_empty_string(System.get_env("GITLAB_PROJECT_ID")) do
      nil -> {:error, :missing_gitlab_project_id}
      project_id -> {:ok, project_id}
    end
  end

  defp gitlab_project_id(_arguments), do: gitlab_project_id(%{})

  defp gitlab_coverage_url(endpoint, project_id, arguments)
       when is_binary(endpoint) and is_binary(project_id) do
    endpoint = String.trim_trailing(endpoint, "/")
    encoded_project_id = URI.encode_www_form(project_id)

    case Map.get(arguments, "pipeline_id") || Map.get(arguments, :pipeline_id) do
      nil ->
        ref = normalize_non_empty_string(Map.get(arguments, "ref") || Map.get(arguments, :ref))
        query = if ref, do: "?ref=#{URI.encode_www_form(ref)}", else: ""
        {:ok, "#{endpoint}/projects/#{encoded_project_id}/pipelines/latest#{query}"}

      pipeline_id ->
        {:ok, "#{endpoint}/projects/#{encoded_project_id}/pipelines/#{pipeline_id}"}
    end
  end

  defp normalize_gitlab_pipeline(body, project_id) when is_map(body) do
    %{
      "project_id" => body["project_id"] || project_id,
      "pipeline_id" => body["id"],
      "pipeline_iid" => body["iid"],
      "status" => body["status"],
      "ref" => body["ref"],
      "sha" => body["sha"],
      "coverage" => body["coverage"],
      "source" => body["source"],
      "web_url" => body["web_url"],
      "created_at" => body["created_at"],
      "updated_at" => body["updated_at"]
    }
  end

  defp normalize_gitlab_pipeline(body, _project_id), do: body

  defp graphql_errors?(%{"errors" => errors}) when is_list(errors) and errors != [], do: true
  defp graphql_errors?(_body), do: false

  defp post_json(url, headers, payload) do
    body = Json.encode!(payload)
    request(:post, url, headers, body)
  end

  defp get_json(url, headers), do: request(:get, url, headers, nil)

  defp request(method, url, headers, body) do
    :ok = ensure_http_started()

    request =
      case method do
        :post -> {String.to_charlist(url), http_headers(headers), ~c"application/json", body}
        :get -> {String.to_charlist(url), http_headers(headers)}
      end

    case :httpc.request(method, request, [{:timeout, 30_000}], body_format: :binary) do
      {:ok, {{_http, status, _reason}, _headers, response_body}} ->
        {:ok, status, decode_response_body(response_body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_http_started do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    :ok
  end

  defp http_headers(headers) do
    Enum.map(headers, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  defp decode_response_body(body) when is_binary(body) do
    case Json.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp env_value(name) do
    case normalize_non_empty_string(System.get_env(name)) do
      nil -> {:error, {:missing_env, name}}
      value -> {:ok, value}
    end
  end

  defp normalize_non_empty_string(value) when is_integer(value), do: Integer.to_string(value)

  defp normalize_non_empty_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_non_empty_string(_value), do: nil

  defp tool_result(success, payload) when is_boolean(success) do
    %{
      "content" => [%{"type" => "text", "text" => Json.encode!(payload)}],
      "isError" => not success
    }
  end

  defp tool_error(payload), do: tool_result(false, payload)

  defp result_response(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp error_response(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end
end
