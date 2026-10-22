defmodule SymphonyElixir.DashboardConfig do
  @moduledoc """
  The single configuration adapter for read-only dashboard aggregation.

  It deliberately consumes the validated workflow structure and the selected
  local profile's non-secret scope variables. LiveViews and components receive
  its normalized result; they never inspect environment variables themselves.
  """

  alias SymphonyElixir.Config

  @type snapshot :: %{
          profile: String.t(),
          project_slug: String.t(),
          project_slug_id: String.t(),
          required_labels: [String.t()],
          repository: String.t(),
          target_branch: String.t(),
          aggregation_enabled?: boolean(),
          refresh_ms: pos_integer(),
          gatekeeper_observation_path: String.t() | nil
        }

  @type action_scope :: %{
          enabled?: boolean(),
          profile: String.t(),
          project_slug: String.t(),
          project_slug_id: String.t(),
          project_id: String.t(),
          required_label: String.t(),
          repository: String.t(),
          target_branch: String.t()
        }

  @github_profile "github"

  @spec snapshot((String.t() -> String.t() | nil)) :: {:ok, snapshot()} | {:error, atom()}
  def snapshot(env_fun \\ &System.get_env/1) when is_function(env_fun, 1) do
    with {:ok, settings} <- Config.settings(),
         @github_profile <- env_fun.("SYMPHONY_PROFILE"),
         project_slug <- settings.tracker.project_slug,
         true <- non_empty?(project_slug),
         project_slug_id <- env_fun.("SYMPHONY_LINEAR_PROJECT_SLUG_ID"),
         true <- non_empty?(project_slug_id),
         true <- matching_project_slug?(project_slug, project_slug_id),
         labels when is_list(labels) <- settings.tracker.required_labels,
         required_label <- env_fun.("SYMPHONY_GATEKEEPER_ACTIVE_LABEL"),
         true <- non_empty?(required_label) and required_label in labels,
         repository <- env_fun.("SYMPHONY_GITHUB_REPOSITORY"),
         true <- valid_repository?(repository),
         target_branch <- env_fun.("SYMPHONY_TARGET_BRANCH"),
         true <- valid_target_branch?(target_branch) do
      {:ok,
       %{
         profile: @github_profile,
         project_slug: project_slug,
         project_slug_id: project_slug_id,
         required_labels: labels,
         repository: repository,
         target_branch: target_branch,
         aggregation_enabled?: settings.observability.dashboard_aggregation_enabled,
         refresh_ms: settings.observability.dashboard_aggregation_refresh_ms,
         # Launcher fixes this path per selected profile. It is intentionally
         # not discovered by workspace/session scans or component code.
         gatekeeper_observation_path: env_fun.("SYMPHONY_GATEKEEPER_OBSERVATION_FILE")
       }}
    else
      {:error, _} -> {:error, :workflow_unavailable}
      _ -> {:error, :invalid_dashboard_scope}
    end
  end

  @doc "Returns the validated server-side scope for the opt-in Linear transition."
  @spec action_scope((String.t() -> String.t() | nil)) :: {:ok, action_scope()} | {:error, atom()}
  def action_scope(env_fun \\ &System.get_env/1) when is_function(env_fun, 1) do
    with {:ok, settings} <- Config.settings(),
         @github_profile <- env_fun.("SYMPHONY_PROFILE"),
         project_slug <- settings.tracker.project_slug,
         true <- non_empty?(project_slug),
         project_slug_id <- env_fun.("SYMPHONY_LINEAR_PROJECT_SLUG_ID"),
         true <- non_empty?(project_slug_id),
         true <- matching_project_slug?(project_slug, project_slug_id),
         project_id <- env_fun.("SYMPHONY_LINEAR_PROJECT_ID"),
         true <- valid_uuid?(project_id),
         required_label <- env_fun.("SYMPHONY_GATEKEEPER_ACTIVE_LABEL"),
         true <- non_empty?(required_label) and required_label in settings.tracker.required_labels,
         repository <- env_fun.("SYMPHONY_GITHUB_REPOSITORY"),
         true <- valid_repository?(repository),
         target_branch <- env_fun.("SYMPHONY_TARGET_BRANCH"),
         true <- valid_target_branch?(target_branch) do
      {:ok,
       %{
         enabled?: settings.dashboard.linear_actions_enabled,
         profile: @github_profile,
         project_slug: project_slug,
         project_slug_id: project_slug_id,
         project_id: project_id,
         required_label: required_label,
         repository: repository,
         target_branch: target_branch
       }}
    else
      {:error, _} -> {:error, :workflow_unavailable}
      _ -> {:error, :invalid_action_scope}
    end
  end

  defp matching_project_slug?(project_slug, project_slug_id) do
    project_slug == project_slug_id or String.ends_with?(project_slug, "-" <> project_slug_id)
  end

  defp non_empty?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_uuid?(value) when is_binary(value) do
    String.match?(value, ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) and
      match?({:ok, _}, Ecto.UUID.cast(value))
  end

  defp valid_uuid?(_), do: false

  defp valid_repository?(value) do
    non_empty?(value) and String.match?(value, ~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/)
  end

  defp valid_target_branch?(value), do: non_empty?(value) and value != "main"
end
