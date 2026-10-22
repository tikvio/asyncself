defmodule SymphonyElixir.DeliveryGate do
  @moduledoc """
  Program-level delivery checks for Linear state transitions.

  Workflow text remains guidance; this gate prevents `In Review` without an
  open or already-merged change linked to the current issue identifier.
  """

  @default_gitlab_host "https://gitlab.com"

  @spec validate_in_review(map(), keyword()) :: :ok | {:error, atom() | tuple()}
  def validate_in_review(issue, opts \\ []) when is_map(issue) do
    checker = Keyword.get(opts, :delivery_gate, &check_gitlab/1)

    case checker.(issue) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_delivery_gate_result}
    end
  end

  @doc false
  @spec check_gitlab(map()) :: :ok | {:error, atom() | tuple()}
  def check_gitlab(issue) do
    with {:ok, token} <- gitlab_token(),
         {:ok, host} <- gitlab_host(),
         {:ok, project} <- gitlab_project(),
         {:ok, merge_requests} <- fetch_merge_requests(host, project, token),
         true <- Enum.any?(merge_requests, &(eligible_change?(&1) and linked_to_issue?(&1, issue))) do
      :ok
    else
      false -> {:error, :missing_gitlab_mr}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec check_github(map()) :: :ok | {:error, atom() | tuple()}
  def check_github(issue) do
    with {:ok, token} <- github_token(),
         {:ok, repository} <- github_repository(),
         {:ok, pulls} <- fetch_all_pulls(repository, token),
         true <- Enum.any?(pulls, &(eligible_change?(&1) and linked_to_issue?(&1, issue))) do
      :ok
    else
      false -> {:error, :missing_github_pr}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec validate_in_review_for_host(map(), keyword()) :: :ok | {:error, atom() | tuple()}
  def validate_in_review_for_host(issue, opts \\ []) do
    case System.get_env("SYMPHONY_CODE_HOST", "gitlab") do
      "gitlab" ->
        validate_in_review(issue, opts)

      "github" ->
        checker = Keyword.get(opts, :delivery_gate, &check_github/1)

        case checker.(issue) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
          _ -> {:error, :invalid_delivery_gate_result}
        end

      other ->
        {:error, {:unsupported_code_host, other}}
    end
  end

  defp fetch_merge_requests(host, project, token) do
    path = "/api/v4/projects/#{URI.encode(project, &URI.char_unreserved?/1)}/merge_requests"

    case Req.get(host <> path,
           headers: [{"PRIVATE-TOKEN", token}],
           params: [state: "all", per_page: 100]
         ) do
      {:ok, %{status: 200, body: body}} when is_list(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:gitlab_api_status, status}}
      {:error, reason} -> {:error, {:gitlab_api_request, reason}}
    end
  end

  @doc false
  @spec eligible_change?(term()) :: boolean()
  def eligible_change?(change) when is_map(change) do
    state = change["state"]
    state in ["opened", "open", "merged"] or is_binary(change["merged_at"])
  end

  def eligible_change?(_), do: false

  defp linked_to_issue?(mr, issue) do
    identifier = Map.get(issue, :identifier) || Map.get(issue, "identifier")
    head_ref = get_in(mr, ["head", "ref"])
    text = Enum.join([mr["title"], mr["description"], mr["body"], mr["source_branch"], head_ref], " ")
    is_binary(identifier) and String.contains?(text, identifier)
  end

  defp gitlab_token do
    case System.get_env("GITLAB_TOKEN") || System.get_env("GITLAB_PAT") || System.get_env("GITLAB_ACCESS_TOKEN") do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :missing_gitlab_token}
    end
  end

  defp gitlab_host do
    host = String.trim_trailing(System.get_env("SYMPHONY_GITLAB_HOST") || @default_gitlab_host, "/")

    normalized =
      cond do
        String.starts_with?(host, "https://") -> host
        String.starts_with?(host, "http://") -> nil
        true -> "https://" <> host
      end

    if is_binary(normalized) and URI.parse(normalized).host,
      do: {:ok, normalized},
      else: {:error, :invalid_gitlab_host}
  end

  defp gitlab_project do
    case System.get_env("SYMPHONY_GITLAB_PROJECT") do
      project when is_binary(project) and project != "" -> {:ok, project}
      _ -> {:error, :missing_gitlab_project}
    end
  end

  defp fetch_all_pulls(repository, token) do
    case Req.get("https://api.github.com/repos/" <> repository <> "/pulls",
           headers: [{"Authorization", "Bearer " <> token}, {"Accept", "application/vnd.github+json"}],
           params: [state: "all", per_page: 100]
         ) do
      {:ok, %{status: 200, body: body}} when is_list(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
      {:error, reason} -> {:error, {:github_api_request, reason}}
    end
  end

  defp github_token do
    case System.get_env("GH_TOKEN") || System.get_env("GITHUB_TOKEN") do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :missing_github_token}
    end
  end

  defp github_repository do
    case System.get_env("SYMPHONY_GITHUB_REPOSITORY") || System.get_env("GITHUB_REPOSITORY") do
      repository when is_binary(repository) and repository != "" -> {:ok, repository}
      _ -> {:error, :missing_github_repository}
    end
  end
end
