defmodule SymphonyElixir.Preflight do
  @moduledoc """
  Performs explicit, non-dispatching backend checks for the command-line entrypoint.

  `check/2` never sends a model prompt. `:live` is intentionally separate because
  it sends one minimal prompt through the configured backend account.
  """

  alias SymphonyElixir.AgentBackend.{DeepSeek, Runtime}
  alias SymphonyElixir.{Config, TrackerToolServer, Workflow}
  alias SymphonyElixir.Config.Schema

  @preflight_issue_id "asyncself-preflight-bound-issue"

  @spec check(Path.t(), :static | :live) :: :ok | {:error, term()}
  def check(workflow_path, mode \\ :static), do: check(workflow_path, mode, [])

  @doc false
  @spec check(Path.t(), :static | :live, keyword()) :: :ok | {:error, term()}
  def check(workflow_path, mode, opts) when mode in [:static, :live] and is_list(opts) do
    validate_settings = Keyword.get(opts, :validate_settings, &Config.validate_settings/1)
    validate_runtime = Keyword.get(opts, :validate_runtime, &Runtime.validate/1)

    with {:ok, workflow} <- Workflow.load(workflow_path),
         {:ok, settings} <- Schema.parse(workflow.config),
         :ok <- validate_settings.(settings),
         :ok <- validate_runtime.(settings),
         {:ok, runtime} <- Runtime.build(settings) do
      check_backend(runtime, settings, mode, opts)
    end
  end

  defp check_backend(%{backend: :codex}, _settings, :static, _opts), do: :ok
  defp check_backend(%{backend: :codex}, _settings, :live, _opts), do: {:error, :codex_live_preflight_not_supported}

  defp check_backend(%{backend: :deepseek} = runtime, settings, mode, opts) do
    adapter = Keyword.get(opts, :deepseek_adapter, DeepSeek)
    mcp_servers = Keyword.get(opts, :mcp_servers, &preflight_mcp_servers/1)
    workspace = Path.join(System.tmp_dir!(), "asyncself-preflight-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    try do
      with {:ok, mcp_servers} <- mcp_servers.(settings.tracker),
           {:ok, session} <-
             adapter.start_session(workspace,
               command: runtime.command,
               handshake_timeout_ms: runtime.timeouts.handshake_timeout_ms,
               mcp_servers: mcp_servers
             ) do
        try do
          if mode == :live do
            with {:ok, turn} <- adapter.start_turn(session, "Reply with exactly: ASYNCSELF_PREFLIGHT_OK", %{}),
                 {:ok, _result} <- adapter.await_turn(session, turn, runtime.timeouts |> Map.to_list()) do
              :ok
            end
          else
            :ok
          end
        after
          adapter.close_session(session)
        end
      end
    after
      File.rm_rf(workspace)
    end
  end

  defp preflight_mcp_servers(tracker_settings) do
    with {:ok, executable} <- TrackerToolServer.executable(),
         {:ok, server} <- TrackerToolServer.mcp_server(%{id: @preflight_issue_id}, executable, tracker_settings) do
      {:ok, [server]}
    end
  end
end
