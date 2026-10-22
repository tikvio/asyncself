defmodule SymphonyElixir.DashboardClockTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.{DashboardClock, DashboardGatekeeper}

  test "BEAM reads the declared Linux BOOTTIME clock in integer milliseconds" do
    assert {:ok, before} = DashboardClock.boottime_ms()
    assert {:ok, after_value} = DashboardClock.boottime_ms()
    assert before <= after_value
    assert DashboardClock.clock_id() == "linux:CLOCK_BOOTTIME:ms"
  end

  test "only matching clock and boot identifiers are comparable" do
    assert DashboardClock.comparable?(%{"clock_id" => DashboardClock.clock_id(), "boot_id" => "boot", "heartbeat_boottime_ms" => 1}, "boot")
    refute DashboardClock.comparable?(%{"clock_id" => "monotonic", "boot_id" => "boot", "heartbeat_boottime_ms" => 1}, "boot")
  end

  test "a Python writer value is bracketed by BEAM BOOTTIME reads in one boot" do
    path = Path.join(System.tmp_dir!(), "gatekeeper-cross-clock-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    tools_path = Path.expand("../local-tools", File.cwd!())

    script = """
    import json, sys
    from pathlib import Path
    sys.path.insert(0, sys.argv[1])
    from symphony_gatekeeper_observation import snapshot
    value = snapshot('github', 'project', 'cross-process', 1, scan_interval_seconds=15, last_result={'kind': 'fixture'})
    Path(sys.argv[2]).write_text(json.dumps(value), encoding='utf-8')
    """

    assert {:ok, before} = DashboardClock.boottime_ms()
    assert {"", 0} = System.cmd("python3", ["-c", script, tools_path, path], stderr_to_stdout: true)
    assert {:ok, after_value} = DashboardClock.boottime_ms()
    assert {:ok, value} = Jason.decode(File.read!(path))

    # Integer-millisecond truncation has no negative slack: Python runs after
    # the first BEAM sample and before the second one. The protocol separately
    # permits 1,000ms only for a reader scheduled just before a fresh replace.
    assert before <= value["heartbeat_boottime_ms"]
    assert value["heartbeat_boottime_ms"] <= after_value
    assert value["clock_id"] == DashboardClock.clock_id()
    assert {:ok, %{health: %{heartbeat: :fresh}}} = DashboardGatekeeper.read(path, "github", "project")
  end
end
