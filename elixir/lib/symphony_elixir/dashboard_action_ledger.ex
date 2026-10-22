defmodule SymphonyElixir.DashboardActionLedger do
  @moduledoc """
  Small durable ledger for dashboard Linear actions.

  It contains only action identity, lifecycle and sanitized outcome atoms.  It
  deliberately never stores GraphQL bodies, request headers, credentials, or
  platform response text.
  """

  use GenServer

  @type action :: %{
          key: term(),
          issue_id: String.t(),
          target_state: String.t(),
          observed_state_id: String.t() | nil,
          status: :submitting | :waiting_gatekeeper | :conflict | :failed,
          outcome: atom() | nil,
          inserted_at_ms: non_neg_integer(),
          updated_at_ms: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec claim(term(), map(), GenServer.name()) :: {:started, action()} | {:existing, action()} | {:error, :unavailable}
  def claim(key, metadata, name \\ __MODULE__) when is_map(metadata) do
    if Process.whereis(name), do: GenServer.call(name, {:claim, key, metadata}), else: {:error, :unavailable}
  end

  @spec complete(term(), atom(), GenServer.name()) :: {:ok, action()} | {:error, :unavailable}
  def complete(key, outcome, name \\ __MODULE__) when is_atom(outcome) do
    update(key, :waiting_gatekeeper, outcome, name)
  end

  @spec conflict(term(), atom(), GenServer.name()) :: {:ok, action()} | {:error, :unavailable}
  def conflict(key, outcome, name \\ __MODULE__) when is_atom(outcome) do
    update(key, :conflict, outcome, name)
  end

  @spec fail(term(), atom(), GenServer.name()) :: {:ok, action()} | {:error, :unavailable}
  def fail(key, outcome, name \\ __MODULE__) when is_atom(outcome) do
    update(key, :failed, outcome, name)
  end

  @spec get(term(), GenServer.name()) :: action() | nil
  def get(key, name \\ __MODULE__) do
    if Process.whereis(name), do: GenServer.call(name, {:get, key}), else: nil
  end

  @spec default_path() :: Path.t()
  def default_path do
    runtime_dir = System.get_env("SYMPHONY_RUNTIME_DIR") || Path.join(System.tmp_dir!(), "symphony")
    Path.join(runtime_dir, "dashboard-linear-actions.dets")
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, default_path())
    File.mkdir_p!(Path.dirname(path))
    table = Keyword.get(opts, :table, ledger_table_name(Keyword.get(opts, :name, __MODULE__)))

    case :dets.open_file(table, file: String.to_charlist(path), type: :set) do
      {:ok, ^table} -> {:ok, %{table: table}}
      {:error, reason} -> {:stop, {:ledger_open_failed, reason}}
    end
  end

  @impl true
  def handle_call({:claim, key, metadata}, _from, state) do
    case :dets.lookup(state.table, key) do
      [{^key, %{status: status} = action}] when status in [:submitting, :waiting_gatekeeper] ->
        {:reply, {:existing, action}, state}

      _ ->
        now = System.system_time(:millisecond)

        action = %{
          key: key,
          issue_id: Map.fetch!(metadata, :issue_id),
          target_state: Map.fetch!(metadata, :target_state),
          observed_state_id: Map.get(metadata, :observed_state_id),
          status: :submitting,
          outcome: nil,
          inserted_at_ms: now,
          updated_at_ms: now
        }

        :ok = :dets.insert(state.table, {key, action})
        :ok = :dets.sync(state.table)
        {:reply, {:started, action}, state}
    end
  end

  def handle_call({:get, key}, _from, state) do
    action =
      case :dets.lookup(state.table, key) do
        [{^key, value}] -> value
        [] -> nil
      end

    {:reply, action, state}
  end

  def handle_call({:update, key, status, outcome}, _from, state) do
    reply =
      case :dets.lookup(state.table, key) do
        [{^key, action}] ->
          updated = %{action | status: status, outcome: outcome, updated_at_ms: System.system_time(:millisecond)}
          :ok = :dets.insert(state.table, {key, updated})
          :ok = :dets.sync(state.table)
          {:ok, updated}

        [] ->
          {:error, :unavailable}
      end

    {:reply, reply, state}
  end

  @impl true
  def terminate(_reason, %{table: table}) do
    :ok = :dets.close(table)
    :ok
  end

  defp update(key, status, outcome, name) do
    if Process.whereis(name), do: GenServer.call(name, {:update, key, status, outcome}), else: {:error, :unavailable}
  end

  defp ledger_table_name(name) when is_atom(name), do: name
  defp ledger_table_name(_), do: __MODULE__
end
