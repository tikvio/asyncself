defmodule SymphonyElixir.Linear.TypedAgentToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.AgentTool
  alias SymphonyElixir.Tracker.Issue

  @issue %Issue{id: "issue-123", identifier: "SYM-123"}

  test "fixed get issue uses bound id and verified issue(id: String) shape" do
    pid = self()

    response =
      AgentTool.execute("linear_get_issue", %{},
        issue: @issue,
        linear_client: fn query, vars, _ ->
          send(pid, {:query, query, vars})
          {:ok, %{"data" => %{"issue" => %{"id" => "issue-123"}}}}
        end
      )

    assert response["success"]
    assert_received {:query, query, %{"id" => "issue-123"}}
    assert query =~ "issue(id: $id)"
    refute query =~ "issues(filter:"
  end

  test "issue context batches issue, comments, states, and inverse relations" do
    pid = self()

    response =
      AgentTool.execute("linear_get_issue_context", %{},
        issue: @issue,
        linear_client: fn query, vars, _ ->
          send(pid, {:query, query, vars})
          {:ok, %{"data" => %{"issue" => %{"id" => "issue-123"}}}}
        end
      )

    assert response["success"]
    assert_received {:query, query, %{"id" => "issue-123"}}
    assert query =~ "comments(first: 100)"
    assert query =~ "states"
    assert query =~ "inverseRelations(first: 100)"
    assert query =~ "issue(id: $id)"
  end

  test "fixed update state resolves a state id before mutation" do
    pid = self()

    client = fn query, vars, _ ->
      send(pid, {:query, query, vars})

      if query =~ "issueUpdate" do
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      else
        {:ok, %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-done", "name" => "Done"}]}}}}}}
      end
    end

    response = AgentTool.execute("linear_update_issue_state", %{"state" => "Done"}, issue: @issue, linear_client: client)
    assert response["success"]
    assert_received {:query, _, %{"id" => "issue-123"}}
    assert_received {:query, mutation, %{"id" => "issue-123", "stateId" => "state-done"}}
    assert mutation =~ "stateId: $stateId"
  end

  test "In Review is blocked before Linear mutation when no GitLab MR exists" do
    called =
      AgentTool.execute("linear_update_issue_state", %{"state" => "In Review"},
        issue: @issue,
        delivery_gate: fn _issue -> {:error, :missing_gitlab_mr} end,
        linear_client: fn -> raise "Linear must not be called" end
      )

    refute called["success"]
    assert called["output"] =~ "missing_gitlab_mr"
  end

  test "In Review proceeds only after the delivery gate passes" do
    pid = self()

    client = fn query, vars, _ ->
      send(pid, {:query, query, vars})

      if query =~ "issueUpdate" do
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      else
        {:ok, %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "review", "name" => "In Review"}]}}}}}}
      end
    end

    response =
      AgentTool.execute("linear_update_issue_state", %{"state" => "In Review"},
        issue: @issue,
        delivery_gate: fn _issue -> :ok end,
        linear_client: client
      )

    assert response["success"]
    assert_received {:query, mutation, %{"stateId" => "review"}}
    assert mutation =~ "issueUpdate"
  end

  test "comment update verifies the comment belongs to the bound issue" do
    pid = self()

    client = fn query, vars, _ ->
      send(pid, {:query, query, vars})

      if query =~ "commentUpdate" do
        {:ok, %{"data" => %{"commentUpdate" => %{"success" => true}}}}
      else
        {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => [%{"id" => "comment-1"}]}}}}}
      end
    end

    response = AgentTool.execute("linear_update_comment", %{"comment_id" => "comment-1", "body" => "updated"}, issue: @issue, linear_client: client)
    assert response["success"]
    assert_received {:query, _, %{"id" => "issue-123"}}
    assert_received {:query, mutation, %{"id" => "comment-1", "body" => "updated"}}
    assert mutation =~ "commentUpdate"
  end

  test "comment update rejects a comment from another issue" do
    client = fn _query, _vars, _ ->
      {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => []}}}}}
    end

    response = AgentTool.execute("linear_update_comment", %{"comment_id" => "other", "body" => "updated"}, issue: @issue, linear_client: client)
    refute response["success"]
  end

  test "raw GraphQL stops after two consecutive HTTP 400 errors and resets after success" do
    pid = self()

    bad = fn _, _, _ ->
      send(pid, :called)
      {:error, {:linear_api_status, 400}}
    end

    for _ <- 1..2 do
      refute AgentTool.execute("linear_graphql", %{"query" => "query { nope }"}, issue: @issue, linear_client: bad)["success"]
    end

    assert_received :called
    assert_received :called
    response = AgentTool.execute("linear_graphql", %{"query" => "query { nope }"}, issue: @issue, linear_client: bad)
    refute response["success"]
    assert Jason.decode!(response["output"])["error"]["message"] =~ "stopped"
    refute_received :called
  end

  test "fixed comment, state, description and create operations use bound issue" do
    pid = self()

    client = fn query, vars, _ ->
      send(pid, {:query, query, vars})
      {:ok, %{"data" => %{}}}
    end

    for {tool, args} <- [
          {"linear_get_comments", %{}},
          {"linear_get_states", %{}},
          {"linear_update_issue_description", %{"description" => "updated"}},
          {"linear_add_comment", %{"body" => "workpad"}}
        ] do
      assert AgentTool.execute(tool, args, issue: @issue, linear_client: client)["success"]
    end

    assert_received {:query, comments, %{"id" => "issue-123"}}
    assert comments =~ "comments(first: 100)"
    assert_received {:query, states, %{"id" => "issue-123"}}
    assert states =~ "states"
    assert_received {:query, description, %{"id" => "issue-123", "description" => "updated"}}
    assert description =~ "issueUpdate"
    assert_received {:query, create, %{"issueId" => "issue-123", "body" => "workpad"}}
    assert create =~ "commentCreate"
  end

  test "typed tools reject malformed, unbound and failed requests" do
    refute AgentTool.execute("linear_get_issue", "bad", issue: @issue)["success"]
    refute AgentTool.execute("linear_get_issue", %{}, [])["success"]
    refute AgentTool.execute("linear_add_comment", %{}, issue: @issue)["success"]

    failing = fn _, _, _ -> {:error, :offline} end
    refute AgentTool.execute("linear_get_issue", %{}, issue: @issue, linear_client: failing)["success"]
    mutation_failed = fn _, _, _ -> {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}} end
    refute AgentTool.execute("linear_add_comment", %{"body" => "x"}, issue: @issue, linear_client: mutation_failed)["success"]
  end

  test "state update reports unknown state, read error and unexpected shape" do
    unknown = fn _, _, _ ->
      {:ok, %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => []}}}}}}
    end

    assert AgentTool.execute("linear_update_issue_state", %{"state" => "Absent"}, issue: @issue, linear_client: unknown)["output"] =~ "Unknown state"

    for reply <- [{:error, :offline}, {:ok, %{"data" => %{}}}] do
      client = fn _, _, _ -> reply end
      refute AgentTool.execute("linear_update_issue_state", %{"state" => "Done"}, issue: @issue, linear_client: client)["success"]
    end
  end

  test "comment update reports read error and unexpected ownership shape" do
    for reply <- [{:error, :offline}, {:ok, %{"data" => %{}}}] do
      client = fn _, _, _ -> reply end
      refute AgentTool.execute("linear_update_comment", %{"comment_id" => "x", "body" => "new"}, issue: @issue, linear_client: client)["success"]
    end
  end
end
