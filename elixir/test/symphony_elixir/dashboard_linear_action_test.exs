defmodule SymphonyElixir.DashboardLinearActionTest do
  # credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
  # credo:disable-for-this-file Credo.Check.Refactor.Nesting
  use ExUnit.Case, async: false

  alias SymphonyElixir.{DashboardActionLedger, DashboardLinearAction}

  setup do
    name = Module.concat(__MODULE__, "Ledger#{System.unique_integer([:positive])}")
    path = Path.join(System.tmp_dir!(), "dashboard-action-ledger-#{System.unique_integer([:positive])}.dets")
    start_supervised!({DashboardActionLedger, name: name, path: path})
    on_exit(fn -> File.rm(path) end)
    %{ledger: name}
  end

  test "updates only once and reports waiting for Gatekeeper after readback", %{ledger: ledger} do
    agent = start_fixture(:in_review, :success)
    opts = options(agent, ledger)

    assert {:ok, %{status: :waiting_gatekeeper, outcome: :waiting_gatekeeper}} =
             DashboardLinearAction.submit_for_test("issue-1", "review-state", opts)

    assert {:ok, %{status: :waiting_gatekeeper}} =
             DashboardLinearAction.submit_for_test("issue-1", "review-state", opts)

    assert %{
             writes: 1,
             state: :merging,
             mutation_query: mutation_query,
             mutation_variables: %{id: "issue-1", input: %{stateId: "merging-state"}}
           } = Agent.get(agent, & &1)

    assert mutation_query =~ "issueUpdate(id: $id, input: $input)"
  end

  test "response loss is resolved by a readback and never repeats the mutation", %{ledger: ledger} do
    agent = start_fixture(:in_review, :response_lost_after_write)

    assert {:ok, %{status: :waiting_gatekeeper}} =
             DashboardLinearAction.submit_for_test("issue-1", "review-state", options(agent, ledger))

    assert %{writes: 1, state: :merging} = Agent.get(agent, & &1)
  end

  test "an externally changed state becomes a conflict rather than an overwrite", %{ledger: ledger} do
    agent = start_fixture(:in_review, :external_change_after_write)

    assert {:conflict, %{state: %{name: "Done"}, action: %{status: :conflict, outcome: :observed_state_changed}}} =
             DashboardLinearAction.submit_for_test("issue-1", "review-state", options(agent, ledger))

    assert %{writes: 1, state: :done} = Agent.get(agent, & &1)
  end

  test "wrong observed state and forged scope values cannot write", %{ledger: ledger} do
    agent = start_fixture(:in_review, :success)

    assert {:conflict, %{state: %{name: "In Review"}}} =
             DashboardLinearAction.submit_for_test("issue-1", "forged-state", options(agent, ledger))

    assert %{writes: 0} = Agent.get(agent, & &1)

    forged_project_scope = fn ->
      {:ok, current_scope} = scope()
      {:ok, Map.put(current_scope, :project_slug_id, "other-project")}
    end

    assert {:error, :scope_mismatch} =
             DashboardLinearAction.submit_for_test(
               "issue-1",
               "review-state",
               options(agent, ledger, scope_fun: forged_project_scope)
             )

    assert %{writes: 0} = Agent.get(agent, & &1)

    forged_project_id_scope = fn ->
      {:ok, current_scope} = scope()
      {:ok, Map.put(current_scope, :project_id, "other-project-id")}
    end

    assert {:error, :scope_mismatch} =
             DashboardLinearAction.submit_for_test(
               "issue-1",
               "review-state",
               options(agent, ledger, scope_fun: forged_project_id_scope)
             )

    assert %{writes: 0} = Agent.get(agent, & &1)

    forged_scope = fn ->
      {:ok, current_scope} = scope()
      {:ok, Map.put(current_scope, :required_label, "other-label")}
    end

    assert {:error, :scope_mismatch} =
             DashboardLinearAction.submit_for_test(
               "issue-1",
               "review-state",
               options(agent, ledger, scope_fun: forged_scope)
             )

    assert %{writes: 0} = Agent.get(agent, & &1)
  end

  test "scope, feature flag, malformed IDs, and unavailable dynamic state are rejected", %{ledger: ledger} do
    agent = start_fixture(:in_review, :success)

    disabled = fn ->
      {:ok, current_scope} = scope()
      {:ok, Map.put(current_scope, :enabled?, false)}
    end

    assert {:error, :action_not_authorized} =
             DashboardLinearAction.submit_for_test("issue-1", "review-state", options(agent, ledger, scope_fun: disabled))

    assert {:error, :action_not_authorized} = DashboardLinearAction.submit_for_test("../../issue", "review-state", options(agent, ledger))

    state_missing = start_fixture(:in_review, :missing_merging_state)

    assert {:error, :merging_state_unavailable} =
             DashboardLinearAction.submit_for_test("issue-1", "review-state", options(state_missing, ledger))

    assert %{writes: 0} = Agent.get(agent, & &1)
  end

  test "concurrent submissions share the in-flight action", %{ledger: ledger} do
    parent = self()
    agent = start_fixture(:in_review, {:blocked_success, parent})
    opts = options(agent, ledger)

    first = Task.async(fn -> DashboardLinearAction.submit_for_test("issue-1", "review-state", opts) end)
    assert_receive :mutation_started
    second = Task.async(fn -> DashboardLinearAction.submit_for_test("issue-1", "review-state", opts) end)

    assert {:ok, %{status: :submitting}} = Task.await(second)
    send(first.pid, :release_mutation)
    assert {:ok, %{status: :waiting_gatekeeper}} = Task.await(first)
    assert %{writes: 1} = Agent.get(agent, & &1)
  end

  test "ledger survives a service restart without retaining sensitive response data" do
    name = Module.concat(__MODULE__, "RestartLedger#{System.unique_integer([:positive])}")
    path = Path.join(System.tmp_dir!(), "dashboard-action-restart-#{System.unique_integer([:positive])}.dets")
    {:ok, first} = DashboardActionLedger.start_link(name: name, path: path)
    key = {"issue-1", "Merging", "review-state"}
    assert {:started, _} = DashboardActionLedger.claim(key, %{issue_id: "issue-1", target_state: "Merging", observed_state_id: "review-state"}, name)
    assert {:ok, _} = DashboardActionLedger.complete(key, :waiting_gatekeeper, name)
    :ok = GenServer.stop(first)
    {:ok, second} = DashboardActionLedger.start_link(name: name, path: path)
    action = DashboardActionLedger.get(key, name)
    refute Map.has_key?(action, :headers)
    refute Map.has_key?(action, :response)
    :ok = GenServer.stop(second)
    File.rm(path)
  end

  defp options(agent, ledger, overrides \\ []) do
    Keyword.merge([graphql: fixture_graphql(agent), scope_fun: &scope/0, ledger: ledger], overrides)
  end

  defp scope do
    {:ok,
     %{
       enabled?: true,
       profile: "github",
       project_slug: "example-linear-project-1234abcd5678",
       project_slug_id: "1234abcd5678",
       project_id: "project-1",
       required_label: "example-project",
       repository: "example-org/example-repo",
       target_branch: "feature/asyncself/example-target"
     }}
  end

  defp start_fixture(state, behavior) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{state: state, behavior: behavior, writes: 0, mutation_query: nil, mutation_variables: nil}
      end)

    agent
  end

  # The fixture intentionally models several provider responses in one closure.
  defp fixture_graphql(agent) do
    fn query, variables ->
      cond do
        query =~ "DashboardMergingState" ->
          case Agent.get(agent, & &1.behavior) do
            :missing_merging_state ->
              {:ok, %{"data" => %{"team" => %{"states" => %{"nodes" => []}}}}}

            _ ->
              {:ok,
               %{
                 "data" => %{
                   "team" => %{
                     "states" => %{"nodes" => [%{"id" => "merging-state", "name" => "Merging"}]}
                   }
                 }
               }}
          end

        query =~ "DashboardMergingIssueUpdate" ->
          mutation_result =
            Agent.get_and_update(agent, fn %{behavior: behavior} = value ->
              next = %{value | writes: value.writes + 1, mutation_query: query, mutation_variables: variables}

              case behavior do
                :success -> {{:ok, mutation_success()}, %{next | state: :merging}}
                :response_lost_after_write -> {{:error, :timeout}, %{next | state: :merging}}
                :external_change_after_write -> {{:ok, mutation_success()}, %{next | state: :done}}
                {:blocked_success, parent} -> {{:blocked, parent}, %{next | state: :merging}}
              end
            end)

          case mutation_result do
            {:blocked, parent} ->
              send(parent, :mutation_started)

              receive do
                :release_mutation -> {:ok, mutation_success()}
              end

            _ ->
              mutation_result
          end

        query =~ "DashboardMergingIssue" ->
          {:ok, %{"data" => %{"issue" => issue_payload(Agent.get(agent, & &1.state))}}}
      end
    end
  end

  defp issue_payload(state) do
    state =
      case state do
        :in_review -> %{"id" => "review-state", "name" => "In Review"}
        :merging -> %{"id" => "merging-state", "name" => "Merging"}
        :done -> %{"id" => "done-state", "name" => "Done"}
      end

    %{
      "id" => "issue-1",
      "identifier" => "EXM-1",
      "state" => state,
      "team" => %{"id" => "team-1", "key" => "EXM"},
      "project" => %{"id" => "project-1", "slugId" => "1234abcd5678"},
      "labels" => %{"nodes" => [%{"name" => "example-project"}]}
    }
  end

  defp mutation_success, do: %{"data" => %{"issueUpdate" => %{"success" => true}}}
end
