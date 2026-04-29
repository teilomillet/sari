defmodule Sari.Probe.OpenCodeTest do
  use ExUnit.Case, async: true

  alias Sari.Probe.OpenCode

  test "records missing opencode executable as probe data" do
    result = OpenCode.run(executable: nil, port: 45_555)

    assert result.scenario == :opencode_probe
    refute result.started
    refute result.ready
    assert result.error == "opencode executable not found"
    assert is_nil(result.version)
    refute result.sse_measurement.ok
    assert result.sse_measurement.error == "not_attempted"
    refute result.session_lifecycle.created
    assert result.session_lifecycle.error == "not_attempted"

    assert Enum.map(result.endpoint_measurements, & &1.path) == [
             "/global/health",
             "/doc",
             "/session"
           ]
  end
end
