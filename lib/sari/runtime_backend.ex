defmodule Sari.RuntimeBackend do
  @moduledoc """
  Behaviour implemented by Sari runtime adapters.

  A backend adapter owns the backend-specific process, protocol, stream, and
  capability mapping. The core runtime only consumes normalized Sari structs and
  events.
  """

  alias Sari.{RuntimeCapabilities, Session}

  @type params :: map()
  @type backend_opts :: keyword()

  @callback capabilities(backend_opts()) :: RuntimeCapabilities.t()
  @callback start_session(params(), backend_opts()) :: {:ok, Session.t()} | {:error, term()}
  @callback resume_session(String.t(), backend_opts()) :: {:ok, Session.t()} | {:error, term()}
  @callback start_turn(Session.t(), term(), backend_opts()) ::
              {:ok, Enumerable.t()} | {:error, term()}
  @callback interrupt(Session.t(), String.t(), backend_opts()) :: :ok | {:error, term()}
end
