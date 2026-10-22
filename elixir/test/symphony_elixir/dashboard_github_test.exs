defmodule SymphonyElixir.DashboardGitHubTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.DashboardGitHub

  @config %{
    profile: "github",
    repository: "example-org/example-repo",
    target_branch: "feature/base",
    project_slug: "project",
    required_labels: ["example-project"],
    aggregation_enabled?: true,
    refresh_ms: 60_000
  }

  test "accepts only HTTPS GitHub PRs in the configured repository" do
    assert {:ok, %{number: 42}} = DashboardGitHub.validate_pr_url("https://github.com/example-org/example-repo/pull/42", "example-org/example-repo", "feature/base")
    assert {:error, :scope_mismatch} = DashboardGitHub.validate_pr_url("https://github.com/other/repo/pull/42", "example-org/example-repo", "feature/base")
    assert {:error, :invalid_pr_url} = DashboardGitHub.validate_pr_url("javascript:alert(1)", "example-org/example-repo", "feature/base")
  end

  test "keeps all explicit attachment, description, and comment PR associations" do
    issue = %{
      description: "See https://github.com/example-org/example-repo/pull/2",
      attachments: [
        %{url: "https://github.com/example-org/example-repo/pull/1"},
        %{url: "https://github.com/other/repo/pull/9"}
      ],
      comments: [
        %{body: "Review https://github.com/example-org/example-repo/pull/3"},
        %{body: "Duplicate https://github.com/example-org/example-repo/pull/1"}
      ]
    }

    result = DashboardGitHub.association_candidates(issue, "example-org/example-repo", "feature/base")
    assert %{valid: [%{number: 1}, %{number: 2}, %{number: 3}], invalid: [:scope_mismatch]} = result
  end

  test "uses complete paginated review threads and checks tied to the current head" do
    issue = %{id: "issue-1", description: "https://github.com/example-org/example-repo/pull/1"}

    assert {:ok, %{association: :verified, prs: [pr]}} =
             DashboardGitHub.fetch_issue_summary_for_test(issue, @config, &request/4)

    assert pr.head.sha == "head-1"
    assert pr.checks == %{state: :passed, head_sha: "head-1", required: ["build"]}
    assert pr.reviews.decision == :changes_requested
    assert pr.threads.unresolved == 1
    assert pr.threads.complete?
  end

  test "base mismatch is a scope warning and never a qualified delivery" do
    issue = %{id: "issue-1", description: "https://github.com/example-org/example-repo/pull/2"}

    assert {:ok, %{association: :verified, prs: [%{scope: {:warning, :base_mismatch}, checks: :unknown}]}} =
             DashboardGitHub.fetch_issue_summary_for_test(issue, @config, &request/4)
  end

  test "missing required rule data fails rather than becoming no required checks" do
    issue = %{id: "issue-1", description: "https://github.com/example-org/example-repo/pull/1"}

    request = fn method, path, params, body ->
      if path =~ "required_status_checks", do: {:error, :forbidden}, else: request(method, path, params, body)
    end

    assert {:error, {:required_rules_unavailable, :forbidden}} =
             DashboardGitHub.fetch_issue_summary_for_test(issue, @config, request)
  end

  test "diffs stop at the configured budget and say so" do
    assert %{files: [%{}], truncated?: true} = DashboardGitHub.bounded_diff([%{patch: "a\nb"}, %{patch: "c"}], 20, 2, 100)
  end

  test "file pages bind diffs to the current head and preserve metadata without a patch" do
    pr = %{repository: "example-org/example-repo", number: 1, head: %{sha: "head-new"}}

    request = fn "GET", path, params, nil ->
      assert path == "/repos/example-org/example-repo/pulls/1/files"
      assert params == %{"per_page" => 20, "page" => 2}

      {:ok,
       %{
         "files" => [
           %{"filename" => "binary.png", "status" => "modified", "additions" => 1, "deletions" => 0},
           %{"filename" => "safe.txt", "status" => "modified", "patch" => "+line"}
         ],
         "has_next" => false
       }}
    end

    assert {:ok, %{head_sha: "head-new", page: 2, has_next?: false, files: [binary, text]}} =
             DashboardGitHub.fetch_pr_files_for_test(pr, 2, request)

    assert binary.patch_status == :unavailable
    assert text.patch == "+line"
  end

  defp request("GET", "/repos/example-org/example-repo/pulls/1", _, _), do: {:ok, pr("feature/base")}
  defp request("GET", "/repos/example-org/example-repo/pulls/2", _, _), do: {:ok, pr("wrong-base")}

  defp request("GET", path, _, _) do
    cond do
      String.contains?(path, "required_status_checks") ->
        {:ok, %{"contexts" => ["build"]}}

      String.contains?(path, "check-runs") ->
        {:ok, %{"check_runs" => [%{"name" => "build", "status" => "completed", "conclusion" => "success"}]}}

      String.ends_with?(path, "/status") ->
        {:ok, %{"statuses" => []}}

      String.contains?(path, "/reviews") ->
        {:ok, [%{"id" => 1, "state" => "COMMENTED", "user" => %{"id" => "a"}}, %{"id" => 2, "state" => "CHANGES_REQUESTED", "submitted_at" => "2026-01-01T00:00:00Z", "user" => %{"id" => "a"}}]}
    end
  end

  defp request("POST", "/graphql", _, %{variables: %{after: nil}}), do: {:ok, thread_page([%{"isResolved" => true}], true, "next")}
  defp request("POST", "/graphql", _, %{variables: %{after: "next"}}), do: {:ok, thread_page([%{"isResolved" => false}], false, nil)}

  defp pr(base),
    do: %{
      "state" => "open",
      "draft" => false,
      "html_url" => "https://github.com/example-org/example-repo/pull/1",
      "base" => %{"ref" => base, "sha" => "base-1", "repo" => %{"full_name" => "example-org/example-repo"}},
      "head" => %{"ref" => "feature/work", "sha" => "head-1"}
    }

  defp thread_page(nodes, more?, cursor) do
    %{
      "data" => %{
        "repository" => %{
          "pullRequest" => %{
            "reviewThreads" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => more?, "endCursor" => cursor}}
          }
        }
      }
    }
  end
end
