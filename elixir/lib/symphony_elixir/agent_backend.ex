defmodule SymphonyElixir.AgentBackend do
  @moduledoc "Small, explicit contract shared by the supported CLI adapters."

  @type session :: term()
  @type turn_ref :: term()
  @type runtime :: map()

  @callback start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  @callback start_turn(session(), String.t(), map(), keyword()) :: {:ok, turn_ref()} | {:error, term()}
  @callback await_turn(session(), turn_ref(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback cancel_turn(session(), turn_ref(), term()) :: :ok | {:error, term()}
  @callback close_session(session()) :: :ok

  @spec adapter(map()) :: module()
  def adapter(%{backend: :deepseek}), do: SymphonyElixir.AgentBackend.DeepSeek
  def adapter(_runtime), do: SymphonyElixir.AgentBackend.Codex
end

defmodule SymphonyElixir.AgentBackend.Codex do
  @moduledoc false
  @behaviour SymphonyElixir.AgentBackend
  alias SymphonyElixir.Codex.AppServer

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def start_session(workspace, opts), do: AppServer.start_session(workspace, opts)

  @impl true
  @spec start_turn(term(), String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def start_turn(_session, prompt, issue, opts), do: {:ok, %{prompt: prompt, issue: issue, opts: opts}}

  @impl true
  @spec await_turn(term(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def await_turn(session, %{prompt: prompt, issue: issue, opts: turn_opts}, opts) do
    AppServer.run_turn(session, prompt, issue, Keyword.merge(turn_opts, opts))
  end

  @impl true
  @spec cancel_turn(term(), term(), term()) :: :ok
  def cancel_turn(session, _turn, _reason), do: AppServer.stop_session(session)

  @impl true
  @spec close_session(term()) :: :ok
  def close_session(session), do: AppServer.stop_session(session)
end

defmodule SymphonyElixir.AgentBackend.Runtime do
  @moduledoc "Builds the immutable backend snapshot used by one service lifetime."

  alias SymphonyElixir.Config.Schema

  @type t :: %{
          backend: :codex | :deepseek,
          adapter: module(),
          command: String.t(),
          required_version: String.t() | nil,
          worker_topology: :local | :ssh,
          tracker_kind: String.t() | nil,
          usage_kind: :billable_tokens | :unknown,
          timeouts: map(),
          fingerprint: term()
        }

  @spec build(Schema.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def build(settings, opts \\ []) do
    backend = settings.agent.backend || "codex"
    worker_topology = if settings.worker.ssh_hosts == [], do: :local, else: :ssh

    case backend do
      "codex" ->
        {:ok,
         snapshot(
           :codex,
           SymphonyElixir.AgentBackend.Codex,
           settings.codex.command,
           nil,
           worker_topology,
           settings,
           opts
         )}

      "deepseek" ->
        build_deepseek(settings, worker_topology, opts)

      other ->
        {:error, {:unsupported_backend, other}}
    end
  end

  @spec validate(Schema.t(), keyword()) :: :ok | {:error, term()}
  def validate(settings, opts \\ []) do
    case build(settings, opts) do
      {:ok, runtime} -> maybe_check_command(runtime, opts)
      error -> error
    end
  end

  defp build_deepseek(settings, worker_topology, opts) do
    cond do
      worker_topology == :ssh ->
        {:error, {:unsupported_topology, :deepseek_ssh}}

      settings.tracker.kind not in ["linear", "memory"] ->
        {:error, {:unsupported_tracker, settings.tracker.kind}}

      settings.agent.max_tokens_per_run > 0 ->
        {:error, :deepseek_usage_not_comparable_to_token_ceiling}

      settings.deepseek.command != "dsh --profile acp" ->
        {:error, :invalid_deepseek_command}

      true ->
        {:ok,
         snapshot(
           :deepseek,
           SymphonyElixir.AgentBackend.DeepSeek,
           settings.deepseek.command,
           settings.deepseek.required_version,
           worker_topology,
           settings,
           opts
         )}
    end
  end

  @spec immutable_equal?(t(), t()) :: boolean()
  def immutable_equal?(left, right), do: left.fingerprint == right.fingerprint

  @spec version(String.t()) :: {:ok, String.t()} | {:error, term()}
  def version(command \\ "dsh") do
    case System.cmd(command, ["--version"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:cli_version_failed, command, status, String.slice(output, 0, 200)}}
    end
  rescue
    error -> {:error, {:cli_not_found, command, Exception.message(error)}}
  end

  defp snapshot(backend, adapter, command, required_version, worker_topology, settings, _opts) do
    timeouts =
      case backend do
        :deepseek -> Map.from_struct(settings.deepseek) |> Map.take([:handshake_timeout_ms, :read_timeout_ms, :progress_timeout_ms, :turn_timeout_ms])
        :codex -> Map.from_struct(settings.codex) |> Map.take([:read_timeout_ms, :stall_timeout_ms, :turn_timeout_ms])
      end

    %{
      backend: backend,
      adapter: adapter,
      command: command,
      required_version: required_version,
      worker_topology: worker_topology,
      tracker_kind: settings.tracker.kind,
      usage_kind: if(backend == :codex, do: :billable_tokens, else: :unknown),
      timeouts: timeouts,
      fingerprint: {backend, command, required_version, worker_topology, settings.tracker.kind, timeouts, settings.agent.max_tokens_per_run}
    }
  end

  defp maybe_check_command(%{backend: :codex, command: command}, opts) do
    if Keyword.get(opts, :skip_command, false) do
      :ok
    else
      opts
      |> Keyword.get(:command_checker, &System.find_executable/1)
      |> verify_command(command |> String.split() |> List.first())
    end
  end

  defp maybe_check_command(%{backend: :deepseek, command: command, required_version: required}, opts) do
    if Keyword.get(opts, :skip_command, false) do
      :ok
    else
      with {:ok, actual} <- version(command |> String.split() |> List.first()),
           true <- actual == required or {:error, {:version_mismatch, required, actual}} do
        :ok
      end
    end
  end

  defp verify_command(command_checker, command) when is_function(command_checker, 1) do
    if is_binary(command_checker.(command)), do: :ok, else: {:error, {:cli_not_found, command}}
  end
end
