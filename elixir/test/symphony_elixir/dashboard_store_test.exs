defmodule SymphonyElixir.DashboardStoreTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{DashboardClock, DashboardStore}

  setup do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({DashboardStore, name: name})
    %{name: name}
  end

  test "a failed refresh preserves a successful snapshot and marks it stale", %{name: name} do
    assert :ok = DashboardStore.put_snapshot(:linear, [%{identifier: "EXM-1"}], "one", name)
    assert :ok = DashboardStore.record_failure(:linear, {:http, 429}, nil, name)

    assert %{sources: %{linear: %{data: [%{identifier: "EXM-1"}], status: status}}} = DashboardStore.snapshot(name)
    assert status.availability == :available
    assert status.freshness == :stale
    assert status.refresh == :backing_off
    assert status.last_error =~ "429"
  end

  test "first failure is unavailable rather than an empty successful result", %{name: name} do
    assert :ok = DashboardStore.record_failure(:github, :forbidden, nil, name)
    assert %{sources: %{github: %{data: nil, status: status}}} = DashboardStore.snapshot(name)
    assert status.availability == :unavailable
    assert status.freshness == :stale
  end

  test "a bad Gatekeeper replacement retains the last readable snapshot but marks it stale", %{name: name} do
    accepted = %{
      "instance_id" => "instance-1",
      "sequence" => 4,
      :health => %{heartbeat: :fresh, scan: :fresh, heartbeat_age_ms: 10, scan_limit_ms: 120_000}
    }

    assert :ok = DashboardStore.put_snapshot(:gatekeeper, accepted, "scope-one", name)
    assert :ok = DashboardStore.record_failure(:gatekeeper, :invalid_snapshot, nil, name)

    assert %{sources: %{gatekeeper: %{data: ^accepted, status: status}}} = DashboardStore.snapshot(name)
    assert status.availability == :available
    assert status.freshness == :stale
    assert status.last_error =~ "invalid_snapshot"
  end

  test "aggregation remains disabled unless explicitly configured" do
    assert {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "linear"}, "observability" => %{}})
    refute settings.observability.dashboard_aggregation_enabled
    assert settings.observability.dashboard_aggregation_refresh_ms == 60_000
  end

  test "Gatekeeper snapshot scope uses the short project slug ID" do
    name = Module.concat(__MODULE__, "GatekeeperScope#{System.unique_integer([:positive])}")
    path = Path.join(System.tmp_dir!(), "gatekeeper-store-#{System.unique_integer([:positive])}.json")
    {:ok, boot_id} = DashboardClock.boot_id()
    {:ok, now_ms} = DashboardClock.boottime_ms()

    File.write!(
      path,
      Jason.encode!(%{
        "schema_version" => 1,
        "profile" => "github",
        "project" => "1234abcd5678",
        "pid" => 42,
        "instance_id" => "instance",
        "boot_id" => boot_id,
        "clock_id" => "linux:CLOCK_BOOTTIME:ms",
        "sequence" => 1,
        "heartbeat_boottime_ms" => now_ms,
        "heartbeat_at" => "2026-10-21T00:00:00Z",
        "last_scan_at" => "2026-10-21T00:00:00Z",
        "last_scan_success_boottime_ms" => now_ms,
        "scan_interval_seconds" => 15,
        "last_result" => %{"kind" => "scan_complete"},
        "last_error" => nil
      })
    )

    config = %{
      profile: "github",
      project_slug: "example-linear-project-1234abcd5678",
      project_slug_id: "1234abcd5678",
      repository: "example-org/example-repo",
      target_branch: "feature/asyncself/example-target",
      aggregation_enabled?: true,
      refresh_ms: 60_000,
      gatekeeper_observation_path: path
    }

    {:ok, store_pid} =
      DashboardStore.start_link(
        name: name,
        config_fun: fn -> {:ok, config} end,
        linear_fetcher: fn -> {:ok, []} end
      )

    on_exit(fn ->
      if Process.alive?(store_pid), do: GenServer.stop(store_pid)
      File.rm(path)
    end)

    assert :ok = DashboardStore.subscribe(self(), name)

    assert %{sources: %{gatekeeper: %{status: %{availability: :available}, data: data}}} =
             DashboardStore.snapshot(name)

    assert data["project"] == "1234abcd5678"
  end

  test "details reuse fresh data, refresh after sixty seconds, and keep SHA cache keys separate", %{name: name} do
    key = {:github_files, "example-org/example-repo", 7, "head-one", 1}
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    assert :ok = DashboardStore.put_detail_snapshot_for_test(key, %{head_sha: "head-one"}, now, name)
    assert :cached = DashboardStore.request_detail(key, fn -> {:ok, :unexpected} end, name)

    old = DateTime.add(now, -61, :second)
    assert :ok = DashboardStore.put_detail_snapshot_for_test(key, %{head_sha: "head-one"}, old, name)
    test_pid = self()

    assert :started =
             DashboardStore.request_detail(
               key,
               fn ->
                 send(test_pid, {:detail_fetch_started, self()})
                 receive do: (:release_detail_fetch -> {:ok, %{head_sha: "head-one"}})
               end,
               name
             )

    assert_receive {:detail_fetch_started, task_pid}
    assert :merged = DashboardStore.request_detail(key, fn -> {:ok, %{head_sha: "head-one"}} end, name)
    send(task_pid, :release_detail_fetch)

    refute DashboardStore.detail_snapshot({:github_files, "example-org/example-repo", 7, "head-two", 1}, name)
  end

  test "detail older than 120 seconds becomes stale without losing its successful value", %{name: name} do
    key = {:linear_issue, "issue-1"}
    old = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-121, :second)
    assert :ok = DashboardStore.put_detail_snapshot_for_test(key, %{description: "kept"}, old, name)

    assert %{data: %{description: "kept"}, status: %{availability: :available, freshness: :stale}} =
             DashboardStore.detail_snapshot(key, name)
  end

  test "late responses from a prior configuration generation are discarded", %{name: name} do
    state =
      DashboardStore.empty_snapshot()
      |> Map.put(:generation, "current-generation")
      |> Map.put(:external_in_flight, 1)

    assert {:noreply, updated} =
             DashboardStore.handle_info(
               {:dashboard_refresh_result, :linear, "prior-generation", {:ok, [%{identifier: "EXM-old"}]}},
               state
             )

    assert updated.sources == %{}
    assert updated.external_in_flight == 0
    assert DashboardStore.snapshot(name).sources == %{}
  end

  test "at most two external detail tasks run and excess work backs off", %{name: name} do
    test_pid = self()

    for suffix <- ["one", "two"] do
      assert :started =
               DashboardStore.request_detail(
                 {:linear_issue, suffix},
                 fn ->
                   send(test_pid, {:detail_started, suffix, self()})
                   receive do: (:release -> {:ok, %{suffix: suffix}})
                 end,
                 name
               )
    end

    assert_receive {:detail_started, "one", first}
    assert_receive {:detail_started, "two", second}

    assert :backing_off =
             DashboardStore.request_detail({:linear_issue, "three"}, fn -> {:ok, %{suffix: "three"}} end, name)

    assert %{status: %{refresh: :backing_off, last_error: error}} =
             DashboardStore.detail_snapshot({:linear_issue, "three"}, name)

    assert error =~ "dashboard_budget_or_concurrency_limit"
    send(first, :release)
    send(second, :release)
  end

  test "manual dashboard refresh remains disabled without an enabled subscribed aggregation", %{name: name} do
    assert :disabled = DashboardStore.manual_refresh(name)
    assert false == :sys.get_state(name).polling?
  end

  test "subscribers resume one read, ten-second manual refreshes coalesce, and the last unsubscribe pauses polling" do
    name = Module.concat(__MODULE__, "SubscribedStore#{System.unique_integer([:positive])}")
    test_pid = self()

    config = %{
      profile: "github",
      project_slug: "fixture-project",
      repository: "example-org/example-repo",
      target_branch: "fixture-base",
      aggregation_enabled?: true,
      refresh_ms: 60_000,
      gatekeeper_observation_path: nil
    }

    fetcher = fn ->
      send(test_pid, {:subscribed_linear_fetch, self()})
      receive do: (:release_subscribed_fetch -> {:ok, []})
    end

    {:ok, store_pid} =
      DashboardStore.start_link(name: name, config_fun: fn -> {:ok, config} end, linear_fetcher: fetcher)

    on_exit(fn -> if Process.alive?(store_pid), do: GenServer.stop(store_pid) end)

    assert :ok = DashboardStore.subscribe(self(), name)
    assert_receive {:subscribed_linear_fetch, task_pid}
    assert :merged = DashboardStore.manual_refresh(name)
    assert :cooldown = DashboardStore.manual_refresh(name)
    assert true == :sys.get_state(name).polling?

    assert :ok = DashboardStore.unsubscribe(self(), name)
    assert false == :sys.get_state(name).polling?
    send(task_pid, :release_subscribed_fetch)
  end

  test "one cache coalesces five same-round source refreshes into one platform read", %{name: name} do
    test_pid = self()

    fetcher = fn ->
      send(test_pid, {:linear_refresh_started, self()})
      receive do: (:release_linear_refresh -> {:ok, []})
    end

    assert :started = DashboardStore.refresh(:linear, fetcher, name)
    assert_receive {:linear_refresh_started, task_pid}

    for _ <- 1..4 do
      assert :merged = DashboardStore.refresh(:linear, fetcher, name)
    end

    refute_receive {:linear_refresh_started, _}, 20
    send(task_pid, :release_linear_refresh)
  end

  test "the source budget stops a later nonessential refresh" do
    name = Module.concat(__MODULE__, "BudgetStore#{System.unique_integer([:positive])}")
    {:ok, store_pid} = DashboardStore.start_link(name: name, budget_limits: %{linear: 1, github: 1})
    on_exit(fn -> if Process.alive?(store_pid), do: GenServer.stop(store_pid) end)
    test_pid = self()

    assert :started =
             DashboardStore.refresh(
               :linear,
               fn ->
                 send(test_pid, {:budget_fetch_started, self()})
                 receive do: (:release_budget_fetch -> {:ok, []})
               end,
               name
             )

    assert_receive {:budget_fetch_started, task_pid}
    send(task_pid, :release_budget_fetch)
    Process.sleep(10)

    assert :merged = DashboardStore.refresh(:linear, fn -> {:ok, :unexpected} end, name)
    assert %{sources: %{linear: %{status: %{refresh: :backing_off, last_error: error}}}} = DashboardStore.snapshot(name)
    assert error =~ "dashboard_budget_or_concurrency_limit"
  end

  test "source errors redact authorization-like values", %{name: name} do
    assert :ok = DashboardStore.record_failure(:github, "authorization: Bearer fixture-secret", nil, name)
    assert %{sources: %{github: %{status: %{last_error: error}}}} = DashboardStore.snapshot(name)
    refute error =~ "fixture-secret"
    assert error =~ "authorization=[REDACTED]"
  end
end
