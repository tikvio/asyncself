defmodule SymphonyElixir.DashboardConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.DashboardConfig

  test "builds aggregation scope from validated workflow settings and selected profile" do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_required_labels: ["example-project"],
      observability_enabled: true
    )

    env = fn
      "SYMPHONY_PROFILE" -> "github"
      "SYMPHONY_LINEAR_PROJECT_SLUG_ID" -> "project"
      "SYMPHONY_GATEKEEPER_ACTIVE_LABEL" -> "example-project"
      "SYMPHONY_GITHUB_REPOSITORY" -> "example-org/example-repo"
      "SYMPHONY_TARGET_BRANCH" -> "feature/asyncself/example-target"
      "SYMPHONY_GATEKEEPER_OBSERVATION_FILE" -> "/tmp/gatekeeper-observation.json"
    end

    assert {:ok, scope} = DashboardConfig.snapshot(env)
    assert scope.project_slug == "project"
    assert scope.project_slug_id == "project"
    assert scope.required_labels == ["example-project"]
    assert scope.gatekeeper_observation_path == "/tmp/gatekeeper-observation.json"
    refute scope.aggregation_enabled?
  end

  test "builds the Linear action scope from the selected GitHub profile" do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_project_slug: "example-linear-project-1234abcd5678",
      tracker_required_labels: ["example-project"],
      dashboard_linear_actions_enabled: true
    )

    env = fn
      "SYMPHONY_PROFILE" -> "github"
      "SYMPHONY_LINEAR_PROJECT_SLUG_ID" -> "1234abcd5678"
      "SYMPHONY_LINEAR_PROJECT_ID" -> "00000000-0000-4000-8000-000000000000"
      "SYMPHONY_GATEKEEPER_ACTIVE_LABEL" -> "example-project"
      "SYMPHONY_GITHUB_REPOSITORY" -> "example-org/example-repo"
      "SYMPHONY_TARGET_BRANCH" -> "feature/asyncself/example-target"
    end

    assert {:ok, scope} = DashboardConfig.action_scope(env)
    assert scope.enabled?
    assert scope.project_slug == "example-linear-project-1234abcd5678"
    assert scope.project_slug_id == "1234abcd5678"
    assert scope.project_id == "00000000-0000-4000-8000-000000000000"
    assert scope.required_label == "example-project"

    assert {:error, :invalid_action_scope} =
             DashboardConfig.action_scope(fn
               "SYMPHONY_LINEAR_PROJECT_SLUG_ID" -> "wrong-project"
               name -> env.(name)
             end)

    assert {:error, :invalid_action_scope} =
             DashboardConfig.action_scope(fn
               "SYMPHONY_LINEAR_PROJECT_ID" -> "wrong-project-id"
               name -> env.(name)
             end)

    assert {:error, :invalid_action_scope} =
             DashboardConfig.action_scope(fn
               "SYMPHONY_GATEKEEPER_ACTIVE_LABEL" -> "other-project"
               name -> env.(name)
             end)

    assert {:error, :invalid_action_scope} =
             DashboardConfig.action_scope(fn
               "SYMPHONY_GITHUB_REPOSITORY" -> "not-a-repository"
               name -> env.(name)
             end)

    assert {:error, :invalid_action_scope} =
             DashboardConfig.action_scope(fn
               "SYMPHONY_TARGET_BRANCH" -> "main"
               name -> env.(name)
             end)
  end

  test "refuses aggregation when the long slug and short slug ID disagree" do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_project_slug: "example-linear-project-1234abcd5678",
      tracker_required_labels: ["example-project"]
    )

    assert {:error, :invalid_dashboard_scope} =
             DashboardConfig.snapshot(fn
               "SYMPHONY_PROFILE" -> "github"
               "SYMPHONY_LINEAR_PROJECT_SLUG_ID" -> "different-project"
               "SYMPHONY_GATEKEEPER_ACTIVE_LABEL" -> "example-project"
               "SYMPHONY_GITHUB_REPOSITORY" -> "example-org/example-repo"
               "SYMPHONY_TARGET_BRANCH" -> "feature/asyncself/example-target"
               _ -> nil
             end)
  end

  test "refuses aggregation when the profile scope is incomplete" do
    assert {:error, :invalid_dashboard_scope} = DashboardConfig.snapshot(fn _ -> nil end)
  end

  test "a GitLab profile cannot initialize or read the GitHub aggregation scope" do
    assert {:error, :invalid_dashboard_scope} =
             DashboardConfig.snapshot(fn
               "SYMPHONY_PROFILE" -> "gitlab"
               unexpected -> raise "GitHub dashboard unexpectedly read #{unexpected}"
             end)
  end
end
