defmodule Sari.EntracteContract do
  @moduledoc """
  The bounded app-server compatibility surface Sari must satisfy for Entr'acte.

  This is not a full Codex protocol model. It captures the subset verified in
  Entr'acte's current app-server client so Sari can later be plugged in behind
  the existing workflow command slot.
  """

  @required_client_requests [
    "initialize",
    "initialized",
    "thread/start",
    "turn/start"
  ]

  @terminal_notifications [
    "turn/completed",
    "turn/failed",
    "turn/cancelled"
  ]

  @server_requests [
    "item/commandExecution/requestApproval",
    "item/fileChange/requestApproval",
    "item/tool/call",
    "execCommandApproval",
    "applyPatchApproval"
  ]

  @spec required_client_requests() :: [String.t()]
  def required_client_requests, do: @required_client_requests

  @spec terminal_notifications() :: [String.t()]
  def terminal_notifications, do: @terminal_notifications

  @spec server_requests() :: [String.t()]
  def server_requests, do: @server_requests
end
