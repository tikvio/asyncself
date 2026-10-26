defmodule SymphonyElixir.AgentBackend.DeepSeek.SessionOwner do
  @moduledoc false

  use GenServer

  alias SymphonyElixir.AgentBackend.DeepSeek

  @spec start_link(Path.t(), keyword()) :: GenServer.on_start()
  def start_link(workspace, opts) do
    case GenServer.start(__MODULE__, {workspace, opts}) do
      {:ok, owner} -> link_started_owner(owner)
      error -> error
    end
  end

  defp link_started_owner(owner) do
    if Process.alive?(owner) do
      Process.link(owner)
      {:ok, owner}
    else
      {:error, :session_owner_exited_during_start}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @spec start_turn(pid(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_turn(owner, prompt, issue, opts), do: GenServer.call(owner, {:start_turn, prompt, issue, opts})

  @spec await_turn(pid(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def await_turn(owner, turn, opts) do
    GenServer.call(owner, {:await_turn, turn, opts}, :infinity)
  catch
    :exit, _ -> {:error, :session_closed}
  end

  @spec cancel_turn(pid(), map(), term()) :: :ok | {:error, term()}
  def cancel_turn(owner, _turn, _reason) when is_pid(owner) do
    if Process.alive?(owner), do: send(owner, :deepseek_cancel)
    :ok
  end

  @spec close(pid()) :: :ok
  def close(owner) when is_pid(owner) do
    if Process.alive?(owner) do
      send(owner, :deepseek_close)
      GenServer.call(owner, :close, :infinity)
    else
      :ok
    end
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init({workspace, opts}) do
    Process.flag(:trap_exit, true)

    case DeepSeek.start_port_session(workspace, opts) do
      {:ok, session} ->
        # A Port is linked to its owner by default. Its normal exit is an ACP
        # protocol event, not an owner lifecycle decision; keep receiving port
        # messages but do not let that link terminate this GenServer.
        Process.unlink(session.port)
        {:ok, %{session: session}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:start_turn, prompt, issue, opts}, _from, %{session: session} = state) do
    {:reply, DeepSeek.start_turn(session, prompt, issue, opts), state}
  end

  def handle_call({:await_turn, turn, opts}, _from, %{session: session} = state) do
    {:reply, DeepSeek.await_turn(session, turn, opts), state}
  end

  def handle_call(:close, _from, state), do: {:stop, :normal, :ok, state}

  @impl true
  def handle_info(:deepseek_cancel, %{session: session} = state) do
    _ = DeepSeek.cancel_turn(session, %{}, :idle_cancel)
    {:noreply, state}
  end

  def handle_info(:deepseek_close, state), do: {:noreply, state}
  def handle_info({port, {:data, _frame}}, %{session: %{port: port}} = state), do: {:noreply, state}
  def handle_info({port, {:exit_status, _status}}, %{session: %{port: port}} = state), do: {:noreply, state}
  def handle_info({:EXIT, _from, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, port, _reason}, %{session: %{port: port}} = state), do: {:noreply, state}
  def handle_info({:EXIT, _from, reason}, state), do: {:stop, reason, state}

  @impl true
  def terminate(_reason, %{session: session}) do
    DeepSeek.close_session(session)
    :ok
  end
end
