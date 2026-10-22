defmodule SymphonyElixirWeb.DashboardLiveMergingTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{DashboardStore, Workflow}

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    original_endpoint_config = Application.get_env(:symphony_elixir, @endpoint, [])
    original_profile = System.get_env("SYMPHONY_PROFILE")
    original_project_slug_id = System.get_env("SYMPHONY_LINEAR_PROJECT_SLUG_ID")
    original_project_id = System.get_env("SYMPHONY_LINEAR_PROJECT_ID")
    original_active_label = System.get_env("SYMPHONY_GATEKEEPER_ACTIVE_LABEL")
    original_repository = System.get_env("SYMPHONY_GITHUB_REPOSITORY")
    original_branch = System.get_env("SYMPHONY_TARGET_BRANCH")

    on_exit(fn ->
      Application.put_env(:symphony_elixir, @endpoint, original_endpoint_config)
      restore_env("SYMPHONY_PROFILE", original_profile)
      restore_env("SYMPHONY_LINEAR_PROJECT_SLUG_ID", original_project_slug_id)
      restore_env("SYMPHONY_LINEAR_PROJECT_ID", original_project_id)
      restore_env("SYMPHONY_GATEKEEPER_ACTIVE_LABEL", original_active_label)
      restore_env("SYMPHONY_GITHUB_REPOSITORY", original_repository)
      restore_env("SYMPHONY_TARGET_BRANCH", original_branch)
    end)

    System.put_env("SYMPHONY_PROFILE", "github")
    System.put_env("SYMPHONY_LINEAR_PROJECT_SLUG_ID", "1234abcd5678")
    System.put_env("SYMPHONY_LINEAR_PROJECT_ID", "00000000-0000-4000-8000-000000000000")
    System.put_env("SYMPHONY_GATEKEEPER_ACTIVE_LABEL", "example-project")
    System.put_env("SYMPHONY_GITHUB_REPOSITORY", "example-org/example-repo")
    System.put_env("SYMPHONY_TARGET_BRANCH", "feature/asyncself/example-target")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "example-linear-project-1234abcd5678",
      tracker_required_labels: ["example-project"],
      dashboard_linear_actions_enabled: true
    )

    Application.put_env(
      :symphony_elixir,
      @endpoint,
      original_endpoint_config
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.put(:linear_action_submitter, fn "issue-1", "review-state" -> {:ok, %{status: :waiting_gatekeeper, outcome: :waiting_gatekeeper}} end)
    )

    unless Process.whereis(@endpoint), do: start_supervised!({@endpoint, []})
    :ok = DashboardStore.put_snapshot(:linear, [issue()], "live-merging-fixture")
    :ok
  end

  test "list action confirms a Linear-only Merging transition and reports waiting Gatekeeper" do
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Merging"
    assert html =~ "Only updates Linear status; Gatekeeper handles the next step."

    html = view |> element("button[phx-click='merging-open']", "Merging") |> render_click()
    assert html =~ "Move EXM-1 to Merging?"
    assert html =~ "Gatekeeper remains the sole merge executor"

    html = view |> element("button[phx-click='merging-submit']", "Confirm Merging") |> render_click()
    assert html =~ "Waiting Gatekeeper"
    assert html =~ "Linear Merging is not PR merged."
    refute html =~ "PR merged</p>"
  end

  test "forged issue ID does not open an action confirmation" do
    {:ok, view, _html} = live(build_conn(), "/")
    html = render_click(view, "merging-open", %{"issue-id" => "forged-id", "team" => "other", "state" => "Merging"})
    refute html =~ "merging-confirmation"
  end

  test "endpoint keeps origin checking enabled for browser-backed mutations" do
    refute @endpoint.config(:check_origin) == false
  end

  defp issue do
    %{
      id: "issue-1",
      identifier: "EXM-1",
      title: "Fixture issue",
      url: "https://linear.app/issue/EXM-1",
      state_id: "review-state",
      state_name: "In Review",
      state_type: "started",
      labels: [%{"name" => "example-project"}],
      default_scope?: true,
      runtime_state: "idle",
      pr_summary: "unknown",
      pr_data: %{prs: [%{number: 42, state: :open}]},
      updated_at: "2026-10-19T00:00:00Z"
    }
  end
end
