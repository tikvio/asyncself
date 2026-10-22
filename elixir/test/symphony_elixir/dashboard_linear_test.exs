defmodule SymphonyElixir.DashboardLinearTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.DashboardLinear

  test "reads all Linear pages before publishing the list" do
    graph = fn _query, variables ->
      case variables.after do
        nil -> {:ok, page([issue("EXM-1")], true, "next")}
        "next" -> {:ok, page([issue("EXM-2")], false, nil)}
      end
    end

    assert {:ok, [%{identifier: "EXM-1"}, %{identifier: "EXM-2"}]} =
             DashboardLinear.fetch_project_issues_for_test("project", graph)
  end

  test "rejects incomplete pagination rather than returning a partial list" do
    graph = fn _query, _variables -> {:ok, page([issue("EXM-1")], true, nil)} end
    assert {:error, :missing_cursor} = DashboardLinear.fetch_project_issues_for_test("project", graph)
  end

  test "project rows fully page comments and attachments used for PR association" do
    graph = fn query, variables ->
      cond do
        query =~ "DashboardProjectIssues" ->
          issue =
            issue("EXM-1")
            |> Map.put(
              "comments",
              connection_value([%{"id" => "comment-1", "body" => "first"}], true, "comments-next")
            )
            |> Map.put(
              "attachments",
              connection_value(
                [%{"id" => "attachment-1", "url" => "https://github.com/example-org/example-repo/pull/1"}],
                true,
                "attachments-next"
              )
            )

          {:ok, page([issue], false, nil)}

        query =~ "DashboardIssueAssociationComments" ->
          assert variables.after == "comments-next"

          {:ok,
           connection(
             "comments",
             [%{"id" => "comment-2", "body" => "https://github.com/example-org/example-repo/pull/2"}],
             false,
             nil
           )}

        query =~ "DashboardIssueAssociationAttachments" ->
          assert variables.after == "attachments-next"
          {:ok, connection("attachments", [%{"id" => "attachment-2", "url" => "https://example.invalid"}], false, nil)}
      end
    end

    assert {:ok, [issue]} = DashboardLinear.fetch_project_issues_for_test("project", graph)
    assert Enum.map(issue.comments, & &1["id"]) == ["comment-1", "comment-2"]
    assert Enum.map(issue.attachments, & &1["id"]) == ["attachment-1", "attachment-2"]
  end

  test "project rows reject an incomplete PR association connection" do
    graph = fn query, _variables ->
      if query =~ "DashboardProjectIssues" do
        incomplete = issue("EXM-1") |> Map.put("comments", connection_value([], true, nil))
        {:ok, page([incomplete], false, nil)}
      end
    end

    assert {:error, {:linear_pr_association_incomplete, "comments", :missing_cursor}} =
             DashboardLinear.fetch_project_issues_for_test("project", graph)
  end

  test "details fully page comments and dependencies and retain conservative workpad candidates" do
    graph = fn query, variables ->
      cond do
        query =~ "DashboardIssueDetail" ->
          {:ok, %{"data" => %{"issue" => issue("EXM-1") |> Map.put("description", "- [ ] ordinary\n## Start Gate\n- [ ] human: approve")}}}

        query =~ "DashboardIssueComments" and variables.after == nil ->
          {:ok,
           connection(
             "comments",
             [%{"id" => "2", "body" => "progress only", "url" => "https://linear.app/c/2", "createdAt" => "2026-01-01T00:00:00Z", "updatedAt" => "2026-01-01T01:00:00Z"}],
             true,
             "comments-2"
           )}

        query =~ "DashboardIssueComments" ->
          {:ok,
           connection(
             "comments",
             [
               %{"id" => "1", "body" => "## Codex Workpad\nplan", "url" => "https://linear.app/c/1", "createdAt" => "2026-01-02T00:00:00Z", "updatedAt" => "2026-01-03T00:00:00Z"},
               %{"id" => "0", "body" => "## Codex Workpad\nnewer", "url" => "https://linear.app/c/0", "createdAt" => "2026-01-02T00:00:00Z", "updatedAt" => "2026-01-04T00:00:00Z"},
               %{
                 "id" => "deleted",
                 "body" => "## Codex Workpad\nremoved",
                 "deletedAt" => "2026-01-05T00:00:00Z",
                 "url" => "https://linear.app/c/deleted",
                 "createdAt" => "2026-01-02T00:00:00Z",
                 "updatedAt" => "2026-01-05T00:00:00Z"
               }
             ],
             false,
             nil
           )}

        query =~ "DashboardIssueDependencies" and variables.after == nil ->
          {:ok,
           connection(
             "inverseRelations",
             [
               %{
                 "type" => "blocks",
                 "issue" => %{"id" => "dep-1", "identifier" => "EXM-9", "title" => "Upstream", "url" => "https://linear.app/EXM-9", "state" => %{"name" => "In Progress", "type" => "started"}}
               }
             ],
             true,
             "deps-2"
           )}

        true ->
          {:ok, connection("inverseRelations", [], false, nil)}
      end
    end

    assert {:ok, detail} = DashboardLinear.fetch_issue_detail_for_test("issue-1", graph)
    assert Enum.map(detail.comments, & &1.id) == ["1", "0", "2"]
    assert Enum.map(detail.workpads, & &1.id) == ["0", "1"]
    assert detail.comment_resolution == :unknown
    assert [%{identifier: "EXM-9", state: %{"name" => "In Progress"}}] = detail.dependencies
  end

  defp page(nodes, has_next, cursor), do: %{"data" => %{"issues" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => has_next, "endCursor" => cursor}}}}

  defp connection(field, nodes, has_next, cursor), do: %{"data" => %{"issue" => %{field => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => has_next, "endCursor" => cursor}}}}}

  defp connection_value(nodes, has_next, cursor),
    do: %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => has_next, "endCursor" => cursor}}

  defp issue(identifier),
    do: %{
      "id" => identifier,
      "identifier" => identifier,
      "title" => "fixture",
      "description" => "",
      "url" => "https://linear.app/fixture",
      "updatedAt" => "2026-01-01T00:00:00Z",
      "completedAt" => nil,
      "canceledAt" => nil,
      "state" => %{"name" => "Todo", "type" => "started"},
      "labels" => %{"nodes" => []},
      "comments" => connection_value([], false, nil),
      "attachments" => connection_value([], false, nil)
    }
end
