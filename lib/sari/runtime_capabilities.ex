defmodule Sari.RuntimeCapabilities do
  @moduledoc """
  Declares what a runtime backend can and cannot do.

  Capability declarations are intentionally explicit. A backend should mark
  unsupported or degraded behavior instead of silently omitting it.
  """

  @type capability ::
          :sessions
          | :resume
          | :streaming_events
          | :approvals
          | :dynamic_tools
          | :filesystem
          | :command_execution
          | :cancellation
          | :token_usage
          | :tool_calls
          | :approval_requests
          | :cost
          | :cancel
          | :workspace_mode
          | :context_limit

  @type support_value :: boolean() | :degraded

  @type t :: %__MODULE__{
          backend: atom(),
          name: String.t(),
          version: String.t() | nil,
          transport: atom(),
          supports: %{optional(capability()) => support_value()},
          unsupported: %{optional(capability()) => term()},
          metadata: map()
        }

  defstruct backend: nil,
            name: "",
            version: nil,
            transport: nil,
            supports: %{},
            unsupported: %{},
            metadata: %{}

  @required [:sessions, :streaming_events]

  @spec required_capabilities() :: [capability()]
  def required_capabilities, do: @required

  @spec supports?(t(), capability()) :: boolean()
  def supports?(%__MODULE__{supports: supports}, capability) do
    Map.get(supports, capability) in [true, :degraded]
  end

  @spec fully_supports?(t(), capability()) :: boolean()
  def fully_supports?(%__MODULE__{supports: supports}, capability) do
    Map.get(supports, capability) == true
  end

  @spec unsupported_reason(t(), capability()) :: term() | nil
  def unsupported_reason(%__MODULE__{unsupported: unsupported}, capability) do
    Map.get(unsupported, capability)
  end

  @spec validate_required(t(), [capability()]) ::
          :ok | {:error, {:missing_capabilities, [capability()]}}
  def validate_required(%__MODULE__{} = capabilities, required \\ @required) do
    missing = Enum.reject(required, &supports?(capabilities, &1))

    case missing do
      [] -> :ok
      _ -> {:error, {:missing_capabilities, missing}}
    end
  end
end
