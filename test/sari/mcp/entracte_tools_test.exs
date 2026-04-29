defmodule Sari.Mcp.EntracteToolsTest do
  use ExUnit.Case, async: true

  alias Sari.{Json, Mcp.EntracteTools}

  test "handles MCP initialize and lists Entr'acte tools" do
    [initialize_line] =
      EntracteTools.handle_json_line(
        ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
      )

    assert %{
             "id" => 1,
             "result" => %{
               "serverInfo" => %{"name" => "sari-entracte-tools"},
               "capabilities" => %{"tools" => %{"listChanged" => false}}
             }
           } = decode!(initialize_line)

    [tools_line] =
      EntracteTools.handle_json_line(~s({"jsonrpc":"2.0","id":2,"method":"tools/list"}))

    tool_names =
      tools_line
      |> decode!()
      |> get_in(["result", "tools"])
      |> Enum.map(& &1["name"])

    assert "linear_graphql" in tool_names
    assert "gitlab_coverage" in tool_names
  end

  test "executes Linear GraphQL through injected request function" do
    request_fun = fn url, headers, body ->
      assert url == "https://api.linear.app/graphql"
      assert {"Authorization", "linear-token"} in headers

      assert body == %{
               "query" => "query Test { viewer { id } }",
               "variables" => %{}
             }

      {:ok, 200, %{"data" => %{"viewer" => %{"id" => "viewer-id"}}}}
    end

    with_env("LINEAR_API_KEY", "linear-token", fn ->
      [line] =
        EntracteTools.handle_json_line(
          Json.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 3,
            "method" => "tools/call",
            "params" => %{
              "name" => "linear_graphql",
              "arguments" => %{"query" => "query Test { viewer { id } }"}
            }
          }),
          request_fun: request_fun
        )

      result = decode!(line)["result"]
      assert result["isError"] == false

      assert %{"status" => 200, "body" => %{"data" => %{"viewer" => %{"id" => "viewer-id"}}}} =
               result |> get_in(["content", Access.at(0), "text"]) |> decode!()
    end)
  end

  test "marks GraphQL errors as MCP tool errors" do
    request_fun = fn _url, _headers, _body ->
      {:ok, 200, %{"errors" => [%{"message" => "bad query"}]}}
    end

    with_env("LINEAR_API_KEY", "linear-token", fn ->
      [line] =
        EntracteTools.handle_json_line(
          Json.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 4,
            "method" => "tools/call",
            "params" => %{
              "name" => "linear_graphql",
              "arguments" => %{"query" => "query Bad { nope }"}
            }
          }),
          request_fun: request_fun
        )

      assert decode!(line)["result"]["isError"] == true
    end)
  end

  defp decode!(line) do
    assert {:ok, decoded} = Json.decode(line)
    decoded
  end

  defp with_env(name, value, fun) do
    previous = System.get_env(name)
    System.put_env(name, value)

    try do
      fun.()
    after
      if is_nil(previous), do: System.delete_env(name), else: System.put_env(name, previous)
    end
  end
end
