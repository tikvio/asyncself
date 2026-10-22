defmodule SymphonyElixir.DashboardLinearAction do
  @moduledoc """
  Server-authorized `In Review -> Merging` transition for the dashboard.

  This module only talks to Linear.  It has no GitHub client, merger command,
  worker dispatch, or Gatekeeper invocation path.
  """

  alias SymphonyElixir.{DashboardActionLedger, DashboardConfig, Linear.Client}

  @target_state "Merging"
  @source_state "In Review"
  @type result :: {:ok, DashboardActionLedger.action()} | {:conflict, DashboardActionLedger.action() | map()} | {:error, atom()}

  @spec submit(String.t(), String.t() | nil) :: result()
  def submit(issue_id, observed_state_id) do
    submit_for_test(issue_id, observed_state_id, [])
  end

  @doc false
  @spec submit_for_test(String.t(), String.t() | nil, keyword()) :: result()
  def submit_for_test(issue_id, observed_state_id, opts) when is_list(opts) do
    graphql = Keyword.get(opts, :graphql, &Client.graphql/2)
    scope_fun = Keyword.get(opts, :scope_fun, &DashboardConfig.action_scope/0)
    ledger = Keyword.get(opts, :ledger, DashboardActionLedger)

    with true <- valid_issue_id?(issue_id),
         {:ok, scope} <- scope_fun.(),
         true <- scope.enabled? do
      transition(issue_id, observed_state_id, scope, graphql, ledger)
    else
      false -> {:error, :action_not_authorized}
      {:error, reason} -> {:error, normalize_scope_error(reason)}
    end
  end

  def submit_for_test(_, _, _), do: {:error, :action_not_authorized}

  defp transition(issue_id, observed_state_id, scope, graphql, ledger) do
    with {:ok, issue} <- read_issue(issue_id, graphql),
         :ok <- validate_scope(issue, scope),
         {:ok, target_state_id} <- resolve_target_state(issue, graphql) do
      key = {issue.id, @target_state, observed_state_id}
      metadata = %{issue_id: issue.id, target_state: @target_state, observed_state_id: observed_state_id}

      case current_state_result(issue, observed_state_id, key, metadata, ledger) do
        :transition -> write_and_confirm(issue, target_state_id, key, graphql, ledger)
        result -> result
      end
    else
      {:error, reason} -> {:error, normalize_action_error(reason)}
    end
  end

  defp current_state_result(%{state: %{name: @target_state}}, _observed, key, metadata, ledger) do
    complete_existing_or_new(key, metadata, :already_merging, ledger)
  end

  defp current_state_result(%{state: %{name: @source_state, id: state_id}}, observed_state_id, _key, _metadata, _ledger)
       when is_binary(observed_state_id) and state_id == observed_state_id,
       do: :transition

  defp current_state_result(issue, _observed, _key, _metadata, _ledger), do: {:conflict, issue}

  defp write_and_confirm(issue, target_state_id, key, graphql, ledger) do
    case DashboardActionLedger.claim(key, %{issue_id: issue.id, target_state: @target_state, observed_state_id: issue.state.id}, ledger) do
      {:existing, action} ->
        action_result(action)

      {:started, _action} ->
        # A transport error and an invalid mutation response are intentionally
        # treated alike: read Linear first, never issue a blind retry.
        _ = update_state(issue.id, target_state_id, graphql)
        confirm_after_write(issue.id, key, graphql, ledger)

      {:error, :unavailable} ->
        {:error, :ledger_unavailable}
    end
  end

  defp confirm_after_write(issue_id, key, graphql, ledger) do
    case read_issue(issue_id, graphql) do
      {:ok, %{state: %{name: @target_state}}} -> complete_existing(key, :waiting_gatekeeper, ledger)
      {:ok, %{state: %{name: @source_state}}} -> fail_existing(key, :mutation_unconfirmed, ledger)
      {:ok, issue} -> conflict_existing(key, :observed_state_changed, issue, ledger)
      {:error, _} -> fail_existing(key, :readback_unavailable, ledger)
    end
  end

  defp complete_existing_or_new(key, metadata, outcome, ledger) do
    case DashboardActionLedger.claim(key, metadata, ledger) do
      {:started, _} -> complete_existing(key, outcome, ledger)
      {:existing, action} -> action_result(action)
      {:error, :unavailable} -> {:error, :ledger_unavailable}
    end
  end

  defp complete_existing(key, outcome, ledger) do
    case DashboardActionLedger.complete(key, outcome, ledger) do
      {:ok, action} -> {:ok, action}
      {:error, _} -> {:error, :ledger_unavailable}
    end
  end

  defp fail_existing(key, outcome, ledger) do
    case DashboardActionLedger.fail(key, outcome, ledger) do
      {:ok, _action} -> {:error, outcome}
      {:error, _} -> {:error, :ledger_unavailable}
    end
  end

  defp conflict_existing(key, outcome, issue, ledger) do
    case DashboardActionLedger.conflict(key, outcome, ledger) do
      {:ok, action} -> {:conflict, Map.put(issue, :action, action)}
      {:error, _} -> {:conflict, issue}
    end
  end

  defp action_result(%{status: :waiting_gatekeeper} = action), do: {:ok, action}
  defp action_result(%{status: :conflict} = action), do: {:conflict, action}
  defp action_result(%{status: :submitting} = action), do: {:ok, action}
  defp action_result(_), do: {:error, :previous_action_failed}

  defp validate_scope(issue, scope) do
    cond do
      issue.project_id != scope.project_id -> {:error, :scope_mismatch}
      issue.project_slug_id != scope.project_slug_id -> {:error, :scope_mismatch}
      scope.required_label not in issue.labels -> {:error, :scope_mismatch}
      true -> :ok
    end
  end

  defp resolve_target_state(%{team_id: team_id}, graphql) when is_binary(team_id) do
    query = """
    query DashboardMergingState($teamId: String!) {
      team(id: $teamId) { states { nodes { id name } } }
    }
    """

    with {:ok, payload} <- graphql.(query, %{teamId: team_id}),
         states when is_list(states) <- get_in(payload, ["data", "team", "states", "nodes"]) || get_in(payload, ["team", "states", "nodes"]),
         %{"id" => id} <- Enum.find(states, &(Map.get(&1, "name") == @target_state)),
         true <- is_binary(id) and id != "" do
      {:ok, id}
    else
      _ -> {:error, :merging_state_unavailable}
    end
  end

  defp resolve_target_state(_, _), do: {:error, :merging_state_unavailable}

  defp read_issue(issue_id, graphql) do
    query = """
    query DashboardMergingIssue($id: String!) {
      issue(id: $id) {
        id identifier
        state { id name }
        team { id key }
        project { id slugId }
        labels { nodes { name } }
      }
    }
    """

    with {:ok, payload} <- graphql.(query, %{id: issue_id}),
         issue when is_map(issue) <- get_in(payload, ["data", "issue"]) || Map.get(payload, "issue"),
         id when is_binary(id) <- Map.get(issue, "id"),
         %{"id" => state_id, "name" => state_name} <- Map.get(issue, "state"),
         %{"id" => team_id} <- Map.get(issue, "team"),
         %{"id" => project_id, "slugId" => project_slug} <- Map.get(issue, "project") do
      {:ok,
       %{
         id: id,
         identifier: Map.get(issue, "identifier"),
         state: %{id: state_id, name: state_name},
         team_id: team_id,
         project_id: project_id,
         project_slug_id: project_slug,
         labels: issue |> get_in(["labels", "nodes"]) |> List.wrap() |> Enum.map(&Map.get(&1, "name"))
       }}
    else
      _ -> {:error, :issue_unavailable}
    end
  end

  defp update_state(issue_id, state_id, graphql) do
    query = """
    mutation DashboardMergingIssueUpdate($id: String!, $input: IssueUpdateInput!) {
      issueUpdate(id: $id, input: $input) { success issue { id state { id name } } }
    }
    """

    graphql.(query, %{id: issue_id, input: %{stateId: state_id}})
  end

  defp valid_issue_id?(id), do: is_binary(id) and byte_size(id) in 1..200 and String.match?(id, ~r/^[A-Za-z0-9_-]+$/)
  defp normalize_scope_error(reason) when reason in [:workflow_unavailable, :invalid_action_scope], do: reason
  defp normalize_scope_error(_), do: :action_not_authorized
  defp normalize_action_error(reason) when reason in [:scope_mismatch, :merging_state_unavailable, :issue_unavailable], do: reason
  defp normalize_action_error(_), do: :action_unavailable
end
