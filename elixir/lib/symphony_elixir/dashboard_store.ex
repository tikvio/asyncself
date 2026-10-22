defmodule SymphonyElixir.DashboardStore do
  @moduledoc """
  Shared, read-only cache for dashboard aggregation data.

  The store deliberately owns only normalized snapshots and their independent
  source status.  Platform clients run outside LiveViews and may replace a
  source atomically through `put_snapshot/4`; a failed refresh never erases a
  previous successful snapshot.
  """

  use GenServer

  alias SymphonyElixir.{DashboardConfig, DashboardGatekeeper, DashboardGitHub, DashboardLinear}
  alias SymphonyElixirWeb.ObservabilityPubSub

  @type source :: :linear | :github | :gatekeeper
  @type source_status :: %{
          availability: :empty | :available | :unavailable,
          freshness: :fresh | :stale | :unknown,
          refresh: :idle | :loading | :backing_off,
          last_error: String.t() | nil,
          last_attempt_at: DateTime.t() | nil,
          last_success_at: DateTime.t() | nil,
          next_refresh_at: DateTime.t() | nil,
          snapshot_generation: String.t() | nil
        }

  @type detail_key ::
          {:linear_issue, String.t()} | {:github_files, String.t(), pos_integer(), String.t(), pos_integer()}
  @type snapshot :: %{
          sources: %{optional(source()) => %{status: source_status(), data: term()}},
          details: %{optional(detail_key()) => %{status: source_status(), data: term()}},
          generation: String.t() | nil,
          subscriptions: %{optional(pid()) => reference()},
          polling?: boolean(),
          manual_refresh_after_ms: integer(),
          external_in_flight: non_neg_integer(),
          budget: %{window_started_at_ms: integer(), linear: non_neg_integer(), github: non_neg_integer()},
          budget_limits: %{linear: pos_integer(), github: pos_integer()}
        }
  @detail_refresh_after_seconds 60
  @detail_stale_after_seconds 120
  @gatekeeper_check_ms 15_000
  @manual_refresh_cooldown_ms 10_000
  @max_external_in_flight 2
  @budget_window_ms 3_600_000
  @linear_budget_per_window 300
  @github_budget_per_window 2_400

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec snapshot(GenServer.name()) :: snapshot()
  def snapshot(name \\ __MODULE__) do
    if Process.whereis(name), do: GenServer.call(name, :snapshot), else: empty_snapshot()
  end

  @spec detail_snapshot(detail_key(), GenServer.name()) :: %{status: source_status(), data: term()} | nil
  def detail_snapshot(key, name \\ __MODULE__) do
    if Process.whereis(name), do: GenServer.call(name, {:detail_snapshot, key}), else: nil
  end

  @doc "Returns cached detail data for 60 seconds and coalesces an overdue refresh."
  @spec request_detail(detail_key(), (-> {:ok, term()} | {:error, term()}), GenServer.name()) ::
          :started | :merged | :cached | :backing_off
  def request_detail(key, fetcher, name \\ __MODULE__) when is_function(fetcher, 0) do
    if Process.whereis(name), do: GenServer.call(name, {:request_detail, key, fetcher}), else: :backing_off
  end

  @doc false
  @spec put_detail_snapshot_for_test(detail_key(), term(), DateTime.t(), GenServer.name()) :: :ok
  def put_detail_snapshot_for_test(key, data, now, name) when is_struct(now, DateTime) do
    GenServer.call(name, {:put_detail_snapshot, key, data, now})
  end

  @spec put_snapshot(source(), term(), String.t() | nil, GenServer.name()) :: :ok
  def put_snapshot(source, data, generation \\ nil, name \\ __MODULE__) when source in [:linear, :github, :gatekeeper] do
    GenServer.call(name, {:put_snapshot, source, data, generation})
  end

  @spec record_failure(source(), term(), DateTime.t() | nil, GenServer.name()) :: :ok
  def record_failure(source, reason, retry_at \\ nil, name \\ __MODULE__)
      when source in [:linear, :github, :gatekeeper] do
    GenServer.call(name, {:record_failure, source, sanitize_error(reason), retry_at})
  end

  @doc "Starts one merged read for a source; concurrent callers share that read."
  @spec refresh(source(), (-> {:ok, term()} | {:error, term()}), GenServer.name()) :: :started | :merged
  def refresh(source, fetcher, name \\ __MODULE__)
      when source in [:linear, :github, :gatekeeper] and is_function(fetcher, 0) do
    GenServer.call(name, {:refresh, source, fetcher})
  end

  @doc "Registers one connected dashboard consumer; reads pause when none remain."
  @spec subscribe(pid(), GenServer.name()) :: :ok
  def subscribe(pid \\ self(), name \\ __MODULE__) when is_pid(pid) do
    if Process.whereis(name), do: GenServer.call(name, {:subscribe, pid}), else: :ok
  end

  @spec unsubscribe(pid(), GenServer.name()) :: :ok
  def unsubscribe(pid \\ self(), name \\ __MODULE__) when is_pid(pid) do
    if Process.whereis(name), do: GenServer.call(name, {:unsubscribe, pid}), else: :ok
  end

  @doc "Coalesces dashboard-only manual reads for ten seconds; it never touches the Orchestrator."
  @spec manual_refresh(GenServer.name()) :: :started | :merged | :cooldown | :disabled
  def manual_refresh(name \\ __MODULE__) do
    if Process.whereis(name), do: GenServer.call(name, :manual_refresh), else: :disabled
  end

  @impl true
  def init(opts) do
    {:ok,
     empty_snapshot()
     |> Map.put(:config_fun, Keyword.get(opts, :config_fun, &DashboardConfig.snapshot/0))
     |> Map.put(:linear_fetcher, Keyword.get(opts, :linear_fetcher, &DashboardLinear.fetch_project_issues/0))
     |> Map.put(:github_fetcher, Keyword.get(opts, :github_fetcher, &DashboardGitHub.fetch_project_summaries/1))
     |> Map.put(:budget_limits, Keyword.get(opts, :budget_limits, default_budget_limits()))}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  def handle_call({:detail_snapshot, key}, _from, state) do
    updated = age_detail(key, state)
    {:reply, get_in(updated, [:details, key]), updated}
  end

  def handle_call({:put_detail_snapshot, key, data, now}, _from, state) do
    updated = put_detail_success(state, key, data, now)
    {:reply, :ok, updated}
  end

  def handle_call({:request_detail, key, fetcher}, _from, state) do
    {result, updated} = begin_detail_refresh(key, fetcher, state)
    {:reply, result, updated}
  end

  def handle_call({:put_snapshot, source, data, generation}, _from, state) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    status = %{
      default_status()
      | availability: :available,
        freshness: :fresh,
        last_error: nil,
        last_attempt_at: now,
        last_success_at: now,
        snapshot_generation: generation
    }

    updated = put_in(state, [:sources, source], %{status: status, data: data})
    ObservabilityPubSub.broadcast_update()
    {:reply, :ok, updated}
  end

  def handle_call({:record_failure, source, reason, retry_at}, _from, state) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    previous = get_in(state, [:sources, source]) || %{status: default_status(), data: nil}
    availability = if previous.status.availability == :available, do: :available, else: :unavailable
    status = %{previous.status | availability: availability, freshness: :stale, refresh: :backing_off, last_error: reason, last_attempt_at: now, next_refresh_at: retry_at}
    updated = put_in(state, [:sources, source], %{previous | status: status})
    ObservabilityPubSub.broadcast_update()
    {:reply, :ok, updated}
  end

  def handle_call({:refresh, source, fetcher}, _from, state) do
    {result, updated} = begin_refresh(source, fetcher, state)
    {:reply, result, updated}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    subscriptions = Map.get(state, :subscriptions, %{})

    updated =
      if Map.has_key?(subscriptions, pid) do
        state
      else
        ref = Process.monitor(pid)
        state |> Map.put(:subscriptions, Map.put(subscriptions, pid, ref)) |> prepare_configuration() |> resume_polling()
      end

    {:reply, :ok, updated}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, remove_subscription(state, pid)}
  end

  def handle_call(:manual_refresh, _from, state) do
    state = prepare_configuration(state)
    now_ms = System.monotonic_time(:millisecond)

    cond do
      not aggregation_active?(state) ->
        {:reply, :disabled, state}

      now_ms < Map.get(state, :manual_refresh_after_ms, 0) ->
        {:reply, :cooldown, state}

      true ->
        {result, updated} = begin_refresh(:linear, linear_fetcher(state), state)
        {:reply, result, Map.put(updated, :manual_refresh_after_ms, now_ms + @manual_refresh_cooldown_ms)}
    end
  end

  @impl true
  def handle_info({:dashboard_refresh_result, source, generation, {:ok, data}}, state) do
    state = finish_external(state)

    if generation != Map.get(state, :generation) do
      {:noreply, state}
    else
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      current = get_in(state, [:sources, source]) || %{status: default_status(), data: nil}
      status = %{current.status | availability: :available, freshness: :fresh, refresh: :idle, last_error: nil, last_success_at: now, last_attempt_at: now}
      updated = put_in(state, [:sources, source], %{status: status, data: data})
      ObservabilityPubSub.broadcast_update()
      updated = maybe_start_github_refresh(source, data, updated)

      {:noreply, updated}
    end
  end

  def handle_info({:dashboard_refresh_result, source, generation, {:error, reason}}, state) do
    state = finish_external(state)

    if generation != Map.get(state, :generation) do
      {:noreply, state}
    else
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      current = get_in(state, [:sources, source]) || %{status: default_status(), data: nil}
      availability = if current.status.availability == :available, do: :available, else: :unavailable
      status = %{current.status | availability: availability, freshness: :stale, refresh: :backing_off, last_error: sanitize_error(reason), last_attempt_at: now}
      updated = put_in(state, [:sources, source], %{current | status: status})
      ObservabilityPubSub.broadcast_update()
      {:noreply, updated}
    end
  end

  def handle_info({:dashboard_detail_result, key, generation, {:ok, data}}, state) do
    state = finish_external(state)

    if generation != Map.get(state, :generation) do
      {:noreply, state}
    else
      updated = put_detail_success(state, key, data, now())
      ObservabilityPubSub.broadcast_update()
      {:noreply, updated}
    end
  end

  def handle_info({:dashboard_detail_result, key, generation, {:error, reason}}, state) do
    state = finish_external(state)

    if generation != Map.get(state, :generation) do
      {:noreply, state}
    else
      current = get_in(state, [:details, key]) || %{status: default_status(), data: nil}
      availability = if current.status.availability == :available, do: :available, else: :unavailable

      status = %{
        current.status
        | availability: availability,
          freshness: :stale,
          refresh: :backing_off,
          last_error: sanitize_error(reason),
          last_attempt_at: now()
      }

      updated = put_in(state, [:details, key], %{current | status: status})
      ObservabilityPubSub.broadcast_update()
      {:noreply, updated}
    end
  end

  def handle_info(:refresh_linear, state) do
    state = prepare_configuration(state)

    if aggregation_active?(state) do
      {_result, updated} = begin_refresh(:linear, linear_fetcher(state), state)
      Process.send_after(self(), :refresh_linear, aggregation_refresh_ms(state))
      {:noreply, updated}
    else
      {:noreply, Map.put(state, :polling?, false)}
    end
  end

  def handle_info(:refresh_gatekeeper, state) do
    state = prepare_configuration(state)

    if aggregation_active?(state) do
      updated = refresh_gatekeeper_snapshot(state)
      Process.send_after(self(), :refresh_gatekeeper, @gatekeeper_check_ms)
      {:noreply, updated}
    else
      {:noreply, Map.put(state, :polling?, false)}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    subscriptions = Map.get(state, :subscriptions, %{})

    if Map.get(subscriptions, pid) == ref do
      {:noreply, remove_subscription(state, pid)}
    else
      {:noreply, state}
    end
  end

  @spec empty_snapshot() :: snapshot()
  def empty_snapshot do
    %{
      sources: %{},
      details: %{},
      generation: nil,
      subscriptions: %{},
      polling?: false,
      manual_refresh_after_ms: System.monotonic_time(:millisecond) - @manual_refresh_cooldown_ms,
      external_in_flight: 0,
      budget: %{window_started_at_ms: System.monotonic_time(:millisecond), linear: 0, github: 0},
      budget_limits: default_budget_limits()
    }
  end

  defp default_status do
    %{
      availability: :empty,
      freshness: :unknown,
      refresh: :idle,
      last_error: nil,
      last_attempt_at: nil,
      last_success_at: nil,
      next_refresh_at: nil,
      snapshot_generation: nil
    }
  end

  defp begin_refresh(source, fetcher, state) do
    current = get_in(state, [:sources, source]) || %{status: default_status(), data: nil}

    cond do
      current.status.refresh == :loading ->
        {:merged, state}

      not external_capacity?(state) or not within_budget?(source, state) ->
        {:merged, put_source_failure(state, source, :dashboard_budget_or_concurrency_limit)}

      true ->
        status = %{current.status | refresh: :loading, last_attempt_at: DateTime.utc_now() |> DateTime.truncate(:second)}
        updated = put_in(state, [:sources, source], %{current | status: status})
        parent = self()
        generation = Map.get(updated, :generation)

        {:ok, _pid} =
          Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
            send(parent, {:dashboard_refresh_result, source, generation, fetcher.()})
          end)

        {:started, consume_external_budget(updated, source)}
    end
  end

  defp begin_detail_refresh(key, fetcher, state) do
    state = age_detail(key, state)
    current = get_in(state, [:details, key]) || %{status: default_status(), data: nil}

    cond do
      current.status.refresh == :loading ->
        {:merged, state}

      current.status.refresh == :backing_off ->
        {:backing_off, state}

      detail_fresh?(current.status, now()) ->
        {:cached, state}

      not external_capacity?(state) or not within_budget?(detail_source(key), state) ->
        {:backing_off, put_detail_failure(state, key, :dashboard_budget_or_concurrency_limit)}

      true ->
        status = %{current.status | refresh: :loading, last_attempt_at: now()}
        updated = put_in(state, [:details, key], %{current | status: status})
        parent = self()
        generation = Map.get(updated, :generation)

        {:ok, _pid} =
          Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
            send(parent, {:dashboard_detail_result, key, generation, fetcher.()})
          end)

        {:started, consume_external_budget(updated, detail_source(key))}
    end
  end

  defp put_detail_success(state, key, data, timestamp) do
    status = %{
      default_status()
      | availability: :available,
        freshness: :fresh,
        refresh: :idle,
        last_attempt_at: timestamp,
        last_success_at: timestamp
    }

    put_in(state, [:details, key], %{status: status, data: data})
  end

  defp detail_fresh?(%{last_success_at: %DateTime{} = successful_at, freshness: :fresh}, timestamp) do
    DateTime.diff(timestamp, successful_at, :second) <= @detail_refresh_after_seconds
  end

  defp detail_fresh?(_, _), do: false

  defp age_detail(key, state) do
    case get_in(state, [:details, key]) do
      %{status: %{last_success_at: %DateTime{} = successful_at, freshness: freshness} = status} = detail
      when freshness == :fresh ->
        if DateTime.diff(now(), successful_at, :second) > @detail_stale_after_seconds do
          put_in(state, [:details, key], %{detail | status: %{status | freshness: :stale}})
        else
          state
        end

      _ ->
        state
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp aggregation_refresh_ms(state) do
    case config_snapshot(state) do
      {:ok, %{refresh_ms: interval}} when is_integer(interval) -> interval
      _ -> 60_000
    end
  end

  # This is intentionally a synchronous local file read in the Store, not a
  # platform request and never a workspace scan. DashboardGatekeeper rejects a
  # bad replacement while the Store retains its last readable source value.
  defp refresh_gatekeeper_snapshot(state) do
    with {:ok, config} <- config_snapshot(state),
         true <- config.aggregation_enabled?,
         path when is_binary(path) and byte_size(path) > 0 <- config.gatekeeper_observation_path do
      previous = get_in(state, [:sources, :gatekeeper, :data])

      case DashboardGatekeeper.read(path, config.profile, config.project_slug_id, previous) do
        {:ok, data} -> put_source_success(state, :gatekeeper, data)
        {:error, reason} -> put_source_failure(state, :gatekeeper, reason)
      end
    else
      _ -> state
    end
  end

  defp put_source_success(state, source, data) do
    timestamp = now()
    current = get_in(state, [:sources, source]) || %{status: default_status(), data: nil}

    status = %{
      current.status
      | availability: :available,
        freshness: :fresh,
        refresh: :idle,
        last_error: nil,
        last_attempt_at: timestamp,
        last_success_at: timestamp
    }

    updated = put_in(state, [:sources, source], %{status: status, data: data})
    ObservabilityPubSub.broadcast_update()
    updated
  end

  defp put_source_failure(state, source, reason) do
    timestamp = now()
    current = get_in(state, [:sources, source]) || %{status: default_status(), data: nil}
    availability = if current.status.availability == :available, do: :available, else: :unavailable

    status = %{
      current.status
      | availability: availability,
        freshness: :stale,
        refresh: :backing_off,
        last_error: sanitize_error(reason),
        last_attempt_at: timestamp
    }

    updated = put_in(state, [:sources, source], %{current | status: status})
    ObservabilityPubSub.broadcast_update()
    updated
  end

  defp put_detail_failure(state, key, reason) do
    current = get_in(state, [:details, key]) || %{status: default_status(), data: nil}
    availability = if current.status.availability == :available, do: :available, else: :unavailable
    status = %{current.status | availability: availability, freshness: :stale, refresh: :backing_off, last_error: sanitize_error(reason), last_attempt_at: now()}
    put_in(state, [:details, key], %{current | status: status})
  end

  # GitHub reads are driven by the shared Linear snapshot, never by browser
  # renders. A second caller joins the same source refresh through
  # `begin_refresh/3`, preserving the one-cache/one-in-flight invariant.
  defp maybe_start_github_refresh(:linear, data, state) when is_list(data) do
    {_result, updated} = begin_refresh(:github, fn -> github_fetcher(state).(data) end, state)
    updated
  end

  defp maybe_start_github_refresh(_source, _data, state), do: state

  defp prepare_configuration(state) do
    case config_snapshot(state) do
      {:ok, %{aggregation_enabled?: true} = config} ->
        generation = configuration_generation(config)

        if generation == Map.get(state, :generation) do
          state
        else
          %{
            state
            | generation: generation,
              sources: %{},
              details: %{},
              external_in_flight: 0,
              budget: %{window_started_at_ms: System.monotonic_time(:millisecond), linear: 0, github: 0}
          }
        end

      _ ->
        %{state | sources: %{}, details: %{}, generation: nil, external_in_flight: 0}
    end
  end

  defp configuration_generation(config) do
    [config.profile, config.project_slug, config.repository, config.target_branch]
    |> Enum.join("\u0000")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp config_snapshot(state), do: Map.fetch!(state, :config_fun).()
  defp linear_fetcher(state), do: Map.fetch!(state, :linear_fetcher)
  defp github_fetcher(state), do: Map.fetch!(state, :github_fetcher)

  defp aggregation_active?(state) do
    Map.get(state, :generation) != nil and map_size(Map.get(state, :subscriptions, %{})) > 0
  end

  defp resume_polling(state) do
    if aggregation_active?(state) and not Map.get(state, :polling?, false) do
      send(self(), :refresh_linear)
      send(self(), :refresh_gatekeeper)
      Map.put(state, :polling?, true)
    else
      state
    end
  end

  defp remove_subscription(state, pid) do
    subscriptions = Map.get(state, :subscriptions, %{})

    case Map.pop(subscriptions, pid) do
      {nil, _} ->
        state

      {ref, remaining} ->
        Process.demonitor(ref, [:flush])
        %{state | subscriptions: remaining, polling?: map_size(remaining) > 0 and Map.get(state, :polling?, false)}
    end
  end

  defp external_capacity?(state), do: Map.get(state, :external_in_flight, 0) < @max_external_in_flight
  defp detail_source({:linear_issue, _}), do: :linear
  defp detail_source({:github_files, _, _, _, _}), do: :github

  defp within_budget?(source, state) do
    budget = current_budget(state)
    limit = Map.fetch!(Map.get(state, :budget_limits, default_budget_limits()), source)
    Map.fetch!(budget, source) < limit
  end

  defp default_budget_limits, do: %{linear: @linear_budget_per_window, github: @github_budget_per_window}

  defp consume_external_budget(state, source) do
    budget = current_budget(state)
    budget = Map.update!(budget, source, &(&1 + 1))
    %{state | budget: budget, external_in_flight: Map.get(state, :external_in_flight, 0) + 1}
  end

  defp current_budget(state) do
    budget = Map.fetch!(state, :budget)

    if System.monotonic_time(:millisecond) - budget.window_started_at_ms >= @budget_window_ms do
      %{window_started_at_ms: System.monotonic_time(:millisecond), linear: 0, github: 0}
    else
      budget
    end
  end

  defp finish_external(state), do: %{state | external_in_flight: max(Map.get(state, :external_in_flight, 0) - 1, 0)}

  defp sanitize_error(reason) do
    reason
    |> inspect(limit: 3, printable_limit: 160)
    |> String.replace(~r/(token|authorization|api[_-]?key)\s*[=:]\s*(?:bearer\s+)?[^\s,}]+/i, "\\1=[REDACTED]")
  end
end
