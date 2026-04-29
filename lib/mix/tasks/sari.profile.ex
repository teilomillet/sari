defmodule Mix.Tasks.Sari.Profile do
  @moduledoc """
  Profiles Sari runtime paths.

      mix sari.profile
      mix sari.profile --concurrency 1,2,4 --iterations 250
      mix sari.profile --scenario opencode_probe --prompt "hello"
      mix sari.profile --scenario claude_code_probe --prompt "hello"
      mix sari.profile --format json

  The default scenario is `app_server_fake`, which measures the bounded
  app-server protocol facade backed by the deterministic fake backend.
  """

  use Mix.Task

  alias Sari.Profile

  @shortdoc "Profile Sari runtime paths"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          scenario: :string,
          concurrency: :string,
          iterations: :integer,
          warmup: :integer,
          port: :integer,
          prompt: :string,
          cwd: :string,
          ready_timeout: :integer,
          turn_timeout: :integer,
          model: :string,
          permission_mode: :string,
          tools: :string,
          allowed_tools: :string,
          bare: :boolean,
          dangerously_skip_permissions: :boolean,
          format: :string
        ]
      )

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    report =
      Profile.run(
        scenario: parse_scenario(Keyword.get(opts, :scenario, "app_server_fake")),
        concurrency_levels: parse_concurrency(Keyword.get(opts, :concurrency, "1,2,4,8,16")),
        iterations: Keyword.get(opts, :iterations, 100),
        warmup_iterations: Keyword.get(opts, :warmup, 5),
        port: Keyword.get(opts, :port),
        prompt: Keyword.get(opts, :prompt),
        cwd: Keyword.get(opts, :cwd, File.cwd!()),
        ready_timeout_ms: Keyword.get(opts, :ready_timeout, 5_000),
        turn_timeout_ms: Keyword.get(opts, :turn_timeout, 300_000),
        model: Keyword.get(opts, :model),
        permission_mode: Keyword.get(opts, :permission_mode),
        tools: Keyword.get(opts, :tools),
        allowed_tools: Keyword.get(opts, :allowed_tools),
        bare: Keyword.get(opts, :bare, false),
        dangerously_skip_permissions: Keyword.get(opts, :dangerously_skip_permissions, false)
      )

    case Keyword.get(opts, :format, "markdown") do
      "json" -> Mix.shell().info(Profile.format_json(report))
      "markdown" -> Mix.shell().info(Profile.format_markdown(report))
      other -> Mix.raise("unsupported format: #{other}")
    end
  end

  defp parse_scenario("app_server_fake"), do: :app_server_fake
  defp parse_scenario("opencode_probe"), do: :opencode_probe
  defp parse_scenario("claude_code_probe"), do: :claude_code_probe
  defp parse_scenario(other), do: Mix.raise("unsupported scenario: #{other}")

  defp parse_concurrency(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(fn part ->
      case Integer.parse(String.trim(part)) do
        {integer, ""} when integer > 0 -> integer
        _ -> Mix.raise("invalid concurrency level: #{part}")
      end
    end)
  end
end
