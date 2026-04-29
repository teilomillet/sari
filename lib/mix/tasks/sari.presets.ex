defmodule Mix.Tasks.Sari.Presets do
  @moduledoc """
  Prints Entr'acte-facing Sari runtime presets.

      mix sari.presets
      mix sari.presets --format json
      mix sari.presets --preset opencode_lmstudio --format workflow
  """

  use Mix.Task

  alias Sari.{Json, RuntimePreset}

  @shortdoc "Print Entr'acte runtime presets"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [format: :string, preset: :string, repo_root: :string]
      )

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    format = Keyword.get(opts, :format, "markdown")
    preset = Keyword.get(opts, :preset)
    preset_opts = preset_opts(opts)

    case format do
      "markdown" ->
        Mix.shell().info(format_markdown(RuntimePreset.all(preset_opts)))

      "json" ->
        Mix.shell().info(Json.encode!(RuntimePreset.all(preset_opts)))

      "workflow" ->
        preset_id = preset || Mix.raise("--preset is required with --format workflow")

        case RuntimePreset.format_workflow_yaml(preset_id, preset_opts) do
          {:ok, yaml} -> Mix.shell().info(yaml)
          {:error, reason} -> Mix.raise("invalid preset: #{inspect(reason)}")
        end

      other ->
        Mix.raise("unsupported format: #{other}")
    end
  end

  defp preset_opts(opts) do
    []
    |> put_opt(:repo_root, Keyword.get(opts, :repo_root))
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp format_markdown(presets) do
    rows =
      presets
      |> Enum.map(fn preset ->
        runnable = Map.fetch!(preset, :runnable?)

        "| #{preset.id} | #{preset.runner} | #{preset.compatibility_slot} | #{runnable} | `#{preset.command}` |"
      end)
      |> Enum.join("\n")

    """
    # Sari Runtime Presets

    | preset | runner | Entr'acte slot | runnable by Sari | command |
    | --- | --- | --- | --- | --- |
    #{rows}
    """
    |> String.trim()
  end
end
