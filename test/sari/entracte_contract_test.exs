defmodule Sari.EntracteContractTest do
  use ExUnit.Case, async: true

  alias Sari.EntracteContract

  test "captures the current bounded Entr'acte app-server client surface" do
    contract = %{
      client_requests: EntracteContract.required_client_requests(),
      terminal_notifications: EntracteContract.terminal_notifications(),
      server_requests: EntracteContract.server_requests()
    }

    assert "initialize" in contract.client_requests
    assert "initialized" in contract.client_requests
    assert "thread/start" in contract.client_requests
    assert "turn/start" in contract.client_requests
    assert "turn/completed" in contract.terminal_notifications
    assert "turn/failed" in contract.terminal_notifications
    assert "turn/cancelled" in contract.terminal_notifications
    assert "item/tool/call" in contract.server_requests
  end
end
