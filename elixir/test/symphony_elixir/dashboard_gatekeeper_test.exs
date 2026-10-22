defmodule SymphonyElixir.DashboardGatekeeperTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.{DashboardClock, DashboardGatekeeper}

  test "validates BOOTTIME freshness, scan health, and the exact TTL boundary" do
    value = snapshot(%{"heartbeat_boottime_ms" => 40_000, "last_scan_success_boottime_ms" => 1})

    assert {:ok, %{health: %{heartbeat: :fresh, heartbeat_age_ms: 60_000, scan: :fresh}}} =
             DashboardGatekeeper.validate(value, "github", "project", "boot", 100_000)

    assert {:ok, %{health: %{heartbeat: :suspected_offline}}} =
             DashboardGatekeeper.validate(value, "github", "project", "boot", 100_001)

    assert {:ok, %{health: %{scan: :overdue, scan_limit_ms: 120_000}}} =
             DashboardGatekeeper.validate(value, "github", "project", "boot", 120_002)
  end

  test "rejects boot, clock, future, scope, schema, and sequence regressions" do
    value = snapshot()

    assert {:error, :incompatible_snapshot} = DashboardGatekeeper.validate(value, "github", "project", "other", 10_000)
    assert {:error, :scope_mismatch} = DashboardGatekeeper.validate(value, "github", "other-project", "boot", 10_000)
    assert {:error, :unsupported_schema} = DashboardGatekeeper.validate(Map.put(value, "schema_version", 2), "github", "project", "boot", 10_000)
    assert {:error, :future_heartbeat} = DashboardGatekeeper.validate(Map.put(value, "heartbeat_boottime_ms", 11_001), "github", "project", "boot", 10_000)

    previous = Map.put(value, "sequence", 3)
    assert {:error, :sequence_regression} = DashboardGatekeeper.validate(Map.put(value, "sequence", 2), "github", "project", "boot", 10_000, previous)

    assert {:ok, _} = DashboardGatekeeper.validate(Map.merge(value, %{"instance_id" => "replacement", "sequence" => 0}), "github", "project", "boot", 10_000, previous)
  end

  test "missing, corrupt, and wall-clock-looking fields do not become healthy" do
    path = Path.join(System.tmp_dir!(), "gatekeeper-observation-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)

    assert {:error, :missing_snapshot} = DashboardGatekeeper.read(path, "github", "project")
    File.write!(path, "{")
    assert {:error, :invalid_snapshot} = DashboardGatekeeper.read(path, "github", "project")

    assert {:ok, boot} = DashboardClock.boot_id()
    assert {:ok, now} = DashboardClock.boottime_ms()

    File.write!(
      path,
      Jason.encode!(snapshot(%{"boot_id" => boot, "heartbeat_boottime_ms" => now, "heartbeat_at" => "1900-01-01T00:00:00Z"}))
    )

    # heartbeat_at is deliberately ignored for health: this is a wall-clock jump fixture.
    assert {:ok, %{health: %{heartbeat: :fresh}}} = DashboardGatekeeper.read(path, "github", "project")
  end

  defp snapshot(overrides \\ %{}) do
    Map.merge(
      %{
        "schema_version" => 1,
        "profile" => "github",
        "project" => "project",
        "pid" => 42,
        "instance_id" => "instance",
        "boot_id" => "boot",
        "clock_id" => "linux:CLOCK_BOOTTIME:ms",
        "sequence" => 2,
        "heartbeat_boottime_ms" => 10_000,
        "heartbeat_at" => "2026-10-19T00:00:00Z",
        "last_scan_at" => nil,
        "last_scan_success_boottime_ms" => nil,
        "scan_interval_seconds" => 15,
        "last_result" => %{"kind" => "scan_complete"},
        "last_error" => nil
      },
      overrides
    )
  end
end
