defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, PromptBuilder, Tracker, Workspace}
  alias SymphonyElixir.Tracker.Issue

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @doc false
  @spec progress_action_for_test(map()) :: boolean()
  def progress_action_for_test(message), do: progress_action?(message)

  @doc false
  @spec tool_call_event_for_test(map()) :: boolean()
  def tool_call_event_for_test(message), do: tool_call_event?(message)

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue, app_session, soft_limit, max_tool_calls_per_turn) do
    fn message ->
      progressed = progress_action?(message)
      if progressed, do: Process.put(:symphony_progress_action, true)
      enforce_tool_call_budget(app_session, issue, message, soft_limit, max_tool_calls_per_turn, progressed)
      send_codex_update(recipient, issue, message)
    end
  end

  defp enforce_tool_call_budget(_app_session, _issue, _message, _soft_limit, max, _progressed) when max <= 0, do: :ok

  defp enforce_tool_call_budget(app_session, issue, message, soft_limit, max, progressed) do
    if tool_call_event?(message) do
      count = Process.get(:symphony_tool_calls_this_turn, 0) + 1
      Process.put(:symphony_tool_calls_this_turn, count)
      since_progress = if progressed, do: 0, else: Process.get(:symphony_tool_calls_since_progress, 0) + 1
      Process.put(:symphony_tool_calls_since_progress, since_progress)

      if soft_limit > 0 and count == soft_limit do
        Logger.warning("Runner tool-call soft limit reached (#{count}/#{soft_limit}) issue=#{issue_context(issue)}")
      end

      if count >= max and since_progress >= 4 and Process.get(:symphony_tool_budget_stopped) != true do
        Process.put(:symphony_tool_budget_stopped, true)
        reason = "Runner tool-call hard limit reached after #{count} calls with #{since_progress} calls without progress"
        Logger.warning("#{reason} issue=#{issue_context(issue)}")
        AppServer.stop_session(app_session)
      end
    end

    :ok
  end

  defp tool_call_event?(%{event: :tool_call_completed}), do: true

  defp tool_call_event?(%{
         event: :notification,
         payload: %{
           "method" => "item/completed",
           "params" => %{"item" => %{"type" => "commandExecution"}}
         }
       }),
       do: true

  defp tool_call_event?(%{
         event: :notification,
         payload: %{
           "method" => "item/completed",
           "params" => %{"item" => %{"type" => type}}
         }
       })
       when type in ["CommandExecution", "DynamicToolCall"],
       do: true

  defp tool_call_event?(_message), do: false

  defp progress_action?(%{event: :tool_call_completed, payload: payload}), do: mutating_tool_call?(payload)

  defp progress_action?(%{event: :tool_call_failed}), do: false

  defp progress_action?(%{event: :notification, payload: %{"method" => "item/completed", "params" => %{"item" => %{"type" => type} = item}}})
       when type in ["CommandExecution", "commandExecution"], do: command_progress?(item)

  defp progress_action?(_message), do: false

  defp mutating_tool_call?(%{"tool" => tool}) when tool in ["linear_get_issue", "linear_get_issue_context", "linear_get_comments", "linear_get_states"], do: false
  defp mutating_tool_call?(%{"name" => tool}) when tool in ["linear_get_issue", "linear_get_issue_context", "linear_get_comments", "linear_get_states"], do: false
  defp mutating_tool_call?(_payload), do: true

  defp command_progress?(%{"command" => command}) when is_binary(command), do: not read_only_command?(command)
  defp command_progress?(%{"cmd" => command}) when is_binary(command), do: not read_only_command?(command)
  defp command_progress?(_item), do: false

  defp read_only_command?(command) do
    normalized = String.trim(command)
    Enum.any?(["pwd", "git status", "git diff", "git branch", "git log", "git show", "git rev-parse", "rg ", "sed ", "cat ", "find ", "ls ", "head ", "tail "], &String.starts_with?(normalized, &1))
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    context = %{
      workspace: workspace,
      issue: issue,
      recipient: codex_update_recipient,
      opts: opts,
      worker_host: worker_host,
      max_turns: Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns),
      tool_calls_soft_limit: Keyword.get(opts, :tool_calls_soft_limit, Config.settings!().agent.tool_calls_soft_limit),
      max_tool_calls_per_turn: Keyword.get(opts, :max_tool_calls_per_turn, Config.settings!().agent.max_tool_calls_per_turn),
      fetcher: Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issues_by_ids/1)
    }

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_codex_turns(session, context, 1, 0)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(app_session, context, turn_number, no_progress_turns) do
    prompt = build_turn_prompt(context.issue, context.opts, turn_number, context.max_turns)
    before_snapshot = workspace_snapshot(context.workspace, context.worker_host)
    Process.put(:symphony_progress_action, false)
    Process.put(:symphony_tool_calls_this_turn, 0)
    Process.put(:symphony_tool_calls_since_progress, 0)
    Process.put(:symphony_tool_budget_stopped, false)

    case AppServer.run_turn(
           app_session,
           prompt,
           context.issue,
           on_message:
             codex_message_handler(
               context.recipient,
               context.issue,
               app_session,
               context.tool_calls_soft_limit,
               context.max_tool_calls_per_turn
             )
         ) do
      {:ok, turn_session} ->
        Logger.info("Completed agent run for #{issue_context(context.issue)} session_id=#{turn_session[:session_id]} workspace=#{context.workspace} turn=#{turn_number}/#{context.max_turns}")
        after_snapshot = workspace_snapshot(context.workspace, context.worker_host)
        continuation = continue_with_issue?(context.issue, context.fetcher)

        handle_continuation(
          continuation,
          app_session,
          context,
          turn_number,
          no_progress_turns,
          before_snapshot,
          after_snapshot
        )

      {:error, reason} ->
        if Process.get(:symphony_tool_budget_stopped) == true do
          send_no_progress(context.recipient, context.issue, "Runner tool-call budget reached; inspect the interrupted Codex turn before resuming")
          Logger.warning("Codex turn stopped by runner tool-call budget issue=#{issue_context(context.issue)} reason=#{inspect(reason)}")
          :ok
        else
          {:error, reason}
        end
    end
  end

  defp handle_continuation({:continue, issue}, app_session, context, turn_number, no_progress_turns, before_snapshot, after_snapshot) when turn_number < context.max_turns do
    count = next_no_progress_count(no_progress_turns, before_snapshot, after_snapshot, context.issue, issue, Process.get(:symphony_progress_action))
    limit = Config.settings!().agent.max_no_progress_turns

    if limit > 0 and count >= limit do
      reason = "No workspace, issue, or tool progress across #{count} completed Codex turns; inspect before resuming"
      send_no_progress(context.recipient, context.issue, reason)
      :ok
    else
      Logger.info("Continuing agent run for #{issue_context(issue)} after normal turn completion turn=#{turn_number}/#{context.max_turns}")
      do_run_codex_turns(app_session, %{context | issue: issue}, turn_number + 1, count)
    end
  end

  defp handle_continuation({:continue, issue}, _app_session, _context, _turn_number, _count, _before, _after) do
    Logger.info("Reached agent.max_turns for #{issue_context(issue)} with issue still active; returning control to orchestrator")
    :ok
  end

  defp handle_continuation({:done, _issue}, _app_session, _context, _turn_number, _count, _before, _after),
    do: :ok

  defp handle_continuation({:error, reason}, _app_session, _context, _turn_number, _count, _before, _after),
    do: {:error, reason}

  @doc false
  @spec next_no_progress_count(non_neg_integer(), term(), term(), Issue.t(), Issue.t(), boolean() | nil) ::
          non_neg_integer()
  def next_no_progress_count(previous, {:clean, fingerprint}, {:clean, fingerprint}, issue, refreshed_issue, false)
      when issue.state == refreshed_issue.state and issue.description == refreshed_issue.description,
      do: previous + 1

  def next_no_progress_count(_previous, _before, _after, _issue, _refreshed_issue, _tool_action), do: 0

  defp workspace_snapshot(_workspace, worker_host) when is_binary(worker_host), do: :unknown

  defp workspace_snapshot(workspace, nil) do
    with {status, 0} <-
           System.cmd("git", ["-C", workspace, "status", "--porcelain=v1", "--untracked-files=all"], stderr_to_stdout: true),
         true <- status == "",
         {head, 0} <- System.cmd("git", ["-C", workspace, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {:clean, String.trim(head)}
    else
      _ -> :unknown
    end
  end

  defp send_no_progress(recipient, %Issue{id: issue_id}, reason)
       when is_pid(recipient) and is_binary(issue_id),
       do: send(recipient, {:agent_no_progress, issue_id, reason})

  defp send_no_progress(_recipient, _issue, _reason), do: :ok

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the tracker work item is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
