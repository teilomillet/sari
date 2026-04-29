defmodule Mix.Tasks.Sari.Capabilities do
  @moduledoc """
  Prints the Sari backend capability matrix.

      mix sari.capabilities
      mix sari.capabilities --format json
  """

  use Mix.Task

  alias Sari.{CapabilityMatrix, Json}

  @shortdoc "Print Sari backend capability matrix"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: [format: :string])

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    report = CapabilityMatrix.report()

    case Keyword.get(opts, :format, "markdown") do
      "markdown" -> Mix.shell().info(CapabilityMatrix.format_markdown(report))
      "json" -> Mix.shell().info(Json.encode!(report))
      other -> Mix.raise("unsupported format: #{other}")
    end
  end
end
