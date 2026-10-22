defmodule SymphonyElixir.DashboardLinear do
  @moduledoc "Read-only, fully paginated Linear project-list adapter for the dashboard."

  alias SymphonyElixir.{DashboardConfig, Linear.Client}

  @page_size 50
  @detail_page_size 50
  @association_page_size 100
  @query """
  query DashboardProjectIssues($projectSlug: String!, $first: Int!, $after: String, $associationFirst: Int!) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}}, first: $first, after: $after) {
      nodes {
        id identifier title description url updatedAt completedAt canceledAt
        state { id name type }
        labels { nodes { name } }
        comments(first: $associationFirst) {
          nodes { id body }
          pageInfo { hasNextPage endCursor }
        }
        attachments(first: $associationFirst) {
          nodes { id url }
          pageInfo { hasNextPage endCursor }
        }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
  """

  @issue_query """
  query DashboardIssueDetail($id: String!) {
    issue(id: $id) {
      id identifier title description url updatedAt
      state { id name type }
    }
  }
  """

  @comments_query """
  query DashboardIssueComments($id: String!, $first: Int!, $after: String) {
    issue(id: $id) {
      comments(first: $first, after: $after) {
        nodes { id body url createdAt updatedAt }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
  """

  @association_comments_query """
  query DashboardIssueAssociationComments($id: String!, $first: Int!, $after: String) {
    issue(id: $id) {
      comments(first: $first, after: $after) {
        nodes { id body }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
  """

  @association_attachments_query """
  query DashboardIssueAssociationAttachments($id: String!, $first: Int!, $after: String) {
    issue(id: $id) {
      attachments(first: $first, after: $after) {
        nodes { id url }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
  """

  @dependencies_query """
  query DashboardIssueDependencies($id: String!, $first: Int!, $after: String) {
    issue(id: $id) {
      inverseRelations(first: $first, after: $after) {
        nodes {
          type
          issue { id identifier title url state { id name type } }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
  """

  @spec fetch_project_issues() :: {:ok, [map()]} | {:error, term()}
  def fetch_project_issues do
    with {:ok, config} <- DashboardConfig.snapshot() do
      fetch_project_issues(config.project_slug, config.required_labels, &Client.graphql/2)
    end
  end

  @doc "Reads one issue's detail data, fully paginating comments and upstream dependencies."
  @spec fetch_issue_detail(map()) :: {:ok, map()} | {:error, term()}
  def fetch_issue_detail(%{id: id}) when is_binary(id), do: fetch_issue_detail_for_test(id, &Client.graphql/2)
  def fetch_issue_detail(_), do: {:error, :linear_issue_id_missing}

  @doc false
  @spec fetch_issue_detail_for_test(String.t(), (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, map()} | {:error, term()}
  def fetch_issue_detail_for_test(id, graphql) when is_binary(id) and is_function(graphql, 2) do
    with {:ok, issue} <- fetch_issue(id, graphql),
         {:ok, comments} <- fetch_comments(id, graphql, nil, [], []),
         {:ok, dependencies} <- fetch_dependencies(id, graphql, nil, [], []) do
      {:ok,
       issue
       |> Map.put(:comments, normalize_comments(comments))
       |> Map.put(:comments_complete?, true)
       |> Map.put(:comment_resolution, :unknown)
       |> Map.put(:workpads, workpad_candidates(comments))
       |> Map.put(:dependencies, dependencies)
       |> Map.put(:dependencies_complete?, true)}
    end
  end

  @doc false
  @spec fetch_project_issues_for_test(String.t(), (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_project_issues_for_test(project_slug, graphql) when is_binary(project_slug) and is_function(graphql, 2) do
    fetch_project_issues(project_slug, [], graphql)
  end

  defp fetch_project_issues(project_slug, required_labels, graphql),
    do: fetch_page(project_slug, required_labels, graphql, nil, [], [])

  @spec fetch_page(
          String.t(),
          [String.t()],
          (String.t(), map() -> {:ok, map()} | {:error, term()}),
          String.t() | nil,
          [map()],
          [String.t()]
        ) :: {:ok, [map()]} | {:error, term()}
  defp fetch_page(project_slug, required_labels, graphql, cursor, issues, cursors) do
    variables = %{projectSlug: project_slug, first: @page_size, after: cursor, associationFirst: @association_page_size}

    with {:ok, response} <- graphql.(@query, variables),
         {:ok, nodes, page_info} <- decode_page(response),
         {:ok, nodes} <- complete_pr_associations(nodes, graphql) do
      next_issues = issues ++ Enum.map(nodes, &normalize_issue(&1, required_labels))

      case next_page(page_info, cursors) do
        {:next, next_cursor, next_cursors} ->
          fetch_page(project_slug, required_labels, graphql, next_cursor, next_issues, next_cursors)

        :complete ->
          {:ok, next_issues}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp complete_pr_associations(issues, graphql) when is_list(issues) do
    Enum.reduce_while(issues, {:ok, []}, fn issue, {:ok, acc} ->
      case complete_pr_associations(issue, graphql) do
        {:ok, complete} -> {:cont, {:ok, [complete | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, complete} -> {:ok, Enum.reverse(complete)}
      error -> error
    end
  end

  defp complete_pr_associations(%{"id" => issue_id} = issue, graphql) when is_binary(issue_id) do
    with {:ok, comments} <- complete_association(issue_id, "comments", Map.get(issue, "comments"), @association_comments_query, graphql),
         {:ok, attachments} <- complete_association(issue_id, "attachments", Map.get(issue, "attachments"), @association_attachments_query, graphql) do
      complete_page = %{"hasNextPage" => false, "endCursor" => nil}

      {:ok,
       issue
       |> Map.put("comments", %{"nodes" => comments, "pageInfo" => complete_page})
       |> Map.put("attachments", %{"nodes" => attachments, "pageInfo" => complete_page})}
    end
  end

  defp complete_pr_associations(_, _), do: {:error, :linear_pr_association_issue_missing}

  defp complete_association(issue_id, field, %{"nodes" => nodes, "pageInfo" => page}, query, graphql)
       when is_list(nodes) and is_map(page) do
    fetch_association_pages(issue_id, field, query, graphql, page, nodes, [])
  end

  defp complete_association(_issue_id, field, _connection, _query, _graphql),
    do: {:error, {:linear_pr_association_incomplete, field, :invalid_connection}}

  defp fetch_association_pages(issue_id, field, query, graphql, page, acc, cursors) do
    case next_association_page(page, cursors) do
      :complete ->
        {:ok, acc}

      {:next, cursor, next_cursors} ->
        with {:ok, response} <- graphql.(query, %{id: issue_id, first: @association_page_size, after: cursor}),
             {:ok, nodes, next_page} <- decode_connection(response, field) do
          fetch_association_pages(issue_id, field, query, graphql, next_page, acc ++ nodes, next_cursors)
        else
          {:error, reason} -> {:error, {:linear_pr_association_incomplete, field, reason}}
        end

      {:error, reason} ->
        {:error, {:linear_pr_association_incomplete, field, reason}}
    end
  end

  defp next_association_page(%{"hasNextPage" => false}, _cursors), do: :complete

  defp next_association_page(%{"hasNextPage" => true, "endCursor" => cursor}, cursors) when is_binary(cursor) and cursor != "" do
    if cursor in cursors,
      do: {:error, :repeated_cursor},
      else: {:next, cursor, [cursor | cursors]}
  end

  defp next_association_page(%{"hasNextPage" => true}, _cursors), do: {:error, :missing_cursor}
  defp next_association_page(_, _cursors), do: {:error, :invalid_page_info}

  defp fetch_issue(id, graphql) do
    with {:ok, response} <- graphql.(@issue_query, %{id: id}),
         {:ok, issue} <- decode_issue(response) do
      {:ok,
       %{
         id: issue["id"],
         identifier: issue["identifier"],
         title: issue["title"],
         description: issue["description"] || "",
         url: issue["url"],
         state: issue["state"] || %{},
         updated_at: issue["updatedAt"]
       }}
    end
  end

  defp fetch_comments(id, graphql, cursor, acc, cursors) do
    with {:ok, response} <- graphql.(@comments_query, %{id: id, first: @detail_page_size, after: cursor}),
         {:ok, nodes, page} <- decode_connection(response, "comments") do
      case next_page(page, cursors) do
        {:next, next_cursor, next_cursors} -> fetch_comments(id, graphql, next_cursor, acc ++ nodes, next_cursors)
        :complete -> {:ok, acc ++ nodes}
        {:error, reason} -> {:error, {:linear_comments_incomplete, reason}}
      end
    end
  end

  defp fetch_dependencies(id, graphql, cursor, acc, cursors) do
    with {:ok, response} <- graphql.(@dependencies_query, %{id: id, first: @detail_page_size, after: cursor}),
         {:ok, nodes, page} <- decode_connection(response, "inverseRelations") do
      case next_page(page, cursors) do
        {:next, next_cursor, next_cursors} -> fetch_dependencies(id, graphql, next_cursor, acc ++ nodes, next_cursors)
        :complete -> {:ok, normalize_dependencies(acc ++ nodes)}
        {:error, reason} -> {:error, {:linear_dependencies_incomplete, reason}}
      end
    end
  end

  defp decode_page(%{"data" => %{"issues" => %{"nodes" => nodes, "pageInfo" => page_info}}}) when is_list(nodes), do: {:ok, nodes, page_info}
  defp decode_page(%{"issues" => %{"nodes" => nodes, "pageInfo" => page_info}}) when is_list(nodes), do: {:ok, nodes, page_info}
  defp decode_page(_), do: {:error, :linear_dashboard_payload}

  defp decode_issue(%{"data" => %{"issue" => issue}}) when is_map(issue), do: {:ok, issue}
  defp decode_issue(%{"issue" => issue}) when is_map(issue), do: {:ok, issue}
  defp decode_issue(_), do: {:error, :linear_issue_detail_payload}

  defp decode_connection(payload, field) do
    issue = get_in(payload, ["data", "issue"]) || Map.get(payload, "issue")

    case issue && Map.get(issue, field) do
      %{"nodes" => nodes, "pageInfo" => page} when is_list(nodes) -> {:ok, nodes, page}
      _ -> {:error, :linear_detail_connection_payload}
    end
  end

  @spec next_page(map(), [String.t()]) ::
          :complete | {:error, :missing_cursor | :repeated_cursor} | {:next, String.t(), [String.t()]}
  defp next_page(%{"hasNextPage" => false}, _cursors), do: :complete

  defp next_page(%{"hasNextPage" => true, "endCursor" => cursor}, cursors) when is_binary(cursor) do
    if cursor in cursors,
      do: {:error, :repeated_cursor},
      else: {:next, cursor, [cursor | cursors]}
  end

  defp next_page(%{"hasNextPage" => true}, _cursors), do: {:error, :missing_cursor}
  defp next_page(_page_info, _cursors), do: :complete

  defp normalize_issue(issue, required_labels) do
    state = issue["state"] || %{}

    %{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"] || "",
      url: issue["url"],
      state_id: state["id"],
      state_name: state["name"] || "unknown",
      state_type: state["type"],
      updated_at: issue["updatedAt"],
      completed_at: issue["completedAt"],
      canceled_at: issue["canceledAt"],
      labels: get_in(issue, ["labels", "nodes"]) || [],
      comments: get_in(issue, ["comments", "nodes"]) || [],
      attachments: get_in(issue, ["attachments", "nodes"]) || [],
      default_scope?: has_required_labels?(issue, required_labels),
      runtime_state: "unknown",
      pr_summary: "unknown"
    }
  end

  defp normalize_comments(comments) do
    comments
    |> Enum.reject(&deleted_comment?/1)
    |> Enum.map(fn comment ->
      %{
        id: comment["id"],
        body: comment["body"] || "",
        url: comment["url"],
        created_at: comment["createdAt"],
        updated_at: comment["updatedAt"]
      }
    end)
    |> Enum.sort_by(fn comment -> {comment.created_at || "", comment.id || ""} end, :desc)
  end

  defp workpad_candidates(comments) do
    comments
    |> Enum.reject(&deleted_comment?/1)
    |> Enum.filter(&(is_binary(&1["body"]) and Regex.match?(~r/(?:\A|\r?\n)## Codex Workpad[ \t]*(?:\r?\n|\z)/, &1["body"])))
    |> Enum.map(fn comment ->
      %{
        id: comment["id"],
        body: comment["body"] || "",
        url: comment["url"],
        created_at: comment["createdAt"],
        updated_at: comment["updatedAt"],
        resolution: :unknown
      }
    end)
    |> Enum.sort_by(fn comment -> {comment.updated_at || "", comment.created_at || "", comment.id || ""} end, :desc)
  end

  defp normalize_dependencies(relations) do
    relations
    |> Enum.filter(&(String.downcase(to_string(&1["type"])) == "blocks" and is_map(&1["issue"])))
    |> Enum.map(fn relation ->
      issue = relation["issue"]
      %{id: issue["id"], identifier: issue["identifier"], title: issue["title"], url: issue["url"], state: issue["state"] || %{}}
    end)
    |> Enum.sort_by(fn dependency -> {dependency.identifier || "", dependency.id || ""} end)
  end

  defp deleted_comment?(comment), do: not is_nil(comment["deletedAt"]) or comment["deleted"] == true

  defp has_required_labels?(_issue, []), do: true

  defp has_required_labels?(issue, required_labels) do
    issue_labels =
      issue
      |> get_in(["labels", "nodes"])
      |> List.wrap()
      |> Enum.map(&Map.get(&1, "name"))

    Enum.all?(required_labels, &(&1 in issue_labels))
  end
end
