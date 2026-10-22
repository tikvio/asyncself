defmodule SymphonyElixirWeb.DashboardComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias SymphonyElixirWeb.Dashboard.{DetailComponents, MergingActionComponents, ProjectComponents, RuntimeComponents}

  test "runtime components retain every legacy table's fields, links, and copy controls" do
    now = ~U[2026-10-19 00:01:00Z]

    payload = %{
      counts: %{running: 1, retrying: 1, blocked: 1},
      codex_totals: %{total_tokens: 12, input_tokens: 5, output_tokens: 7, seconds_running: 30},
      rate_limits: %{primary: "available"},
      running: [
        %{
          issue_identifier: "EXM-1",
          issue_url: "https://linear.app/issue/EXM-1",
          state: "In Progress",
          session_id: "session-1",
          started_at: ~U[2026-10-19 00:00:00Z],
          turn_count: 2,
          last_event: :message,
          last_message: "working",
          last_event_at: "2026-10-19T00:00:30Z",
          tokens: %{total_tokens: 12, input_tokens: 5, output_tokens: 7}
        }
      ],
      blocked: [
        %{
          issue_identifier: "EXM-2",
          issue_url: "https://linear.app/issue/EXM-2",
          state: "Blocked",
          session_id: "session-2",
          blocked_at: "2026-10-19T00:00:30Z",
          last_event: :message,
          last_message: "waiting",
          last_event_at: nil,
          error: "approval required"
        }
      ],
      retrying: [%{issue_identifier: "EXM-3", issue_url: "https://linear.app/issue/EXM-3", attempt: 2, due_at: "2026-10-19T00:02:00Z", error: "timeout"}]
    }

    html =
      [
        render_component(&RuntimeComponents.overview/1, %{payload: payload, now: now}),
        render_component(&RuntimeComponents.rate_limits/1, %{rate_limits: payload.rate_limits}),
        render_component(&RuntimeComponents.running_sessions/1, %{payload: payload, now: now}),
        render_component(&RuntimeComponents.blocked_sessions/1, %{payload: payload}),
        render_component(&RuntimeComponents.retry_queue/1, %{payload: payload})
      ]
      |> IO.iodata_to_binary()

    for text <- [
          "Running",
          "Retrying",
          "Blocked",
          "Total tokens",
          "Rate limits",
          "Running sessions",
          "Blocked sessions",
          "Retry queue",
          "JSON details",
          "Copy ID",
          "Runtime / turns",
          "Codex update",
          "approval required",
          "timeout"
        ] do
      assert html =~ text
    end

    assert html =~ ~s(data-copy="session-1")
    assert html =~ ~s(data-copy="session-2")
    assert html =~ ~s(href="https://linear.app/issue/EXM-1")
    assert html =~ ~s(href="/api/v1/EXM-3")
  end

  test "project component separates source status and displays runtime mapping" do
    snapshot = %{
      sources: %{
        linear: %{
          data: [
            %{
              identifier: "EXM-1",
              title: "Fixture",
              url: "https://linear.app/issue/EXM-1",
              state_name: "In Review",
              runtime_state: "idle",
              pr_summary: "unknown",
              updated_at: "2026-10-19T00:00:00Z",
              default_scope?: true
            }
          ],
          status: %{availability: :available, freshness: :fresh, refresh: :idle, last_error: nil}
        },
        github: %{status: %{availability: :unavailable, freshness: :stale, refresh: :backing_off}},
        gatekeeper: %{status: %{availability: :empty, freshness: :unknown, refresh: :idle}}
      }
    }

    html =
      render_component(&ProjectComponents.projects_section/1, %{
        snapshot: snapshot,
        config: {:ok, %{profile: "github", project_slug: "project", repository: "example-org/example-repo", target_branch: "feature/base"}},
        filters: %{q: "", state: "all"}
      })

    assert html =~ "EXM-1"
    assert html =~ "In Review"
    assert html =~ "idle"
    assert html =~ "Linear: available · fresh · idle"
    assert html =~ "github: unavailable · stale · backing_off"
    assert html =~ "gatekeeper: empty · unknown · idle"
    assert html =~ "/issues/EXM-1?q=&amp;state=all"
    assert html =~ "phx-click=\"dashboard-refresh\""
    assert html =~ "Gatekeeper process and scan health are unknown"
  end

  test "detail text is escaped, workpad stays conservative, and patchless files are metadata only" do
    issue = %{id: "linear-1", identifier: "EXM-1", title: "<script>bad</script>", url: "https://linear.app/issue/EXM-1", runtime_state: "unknown", pr_data: %{prs: []}}

    detail = %{
      description: "<img src=x onerror=alert(1)>\n## Start Gate\n- [ ] human: approval",
      comments: [%{id: "comment-1", body: "<b>comment</b>", url: "https://linear.app/comment/1", created_at: "1", updated_at: "2"}],
      workpads: [%{id: "comment-2", body: "## Codex Workpad\n<script>x</script>", url: "https://linear.app/comment/2", created_at: "1", updated_at: "3"}],
      dependencies: []
    }

    html =
      render_component(&DetailComponents.issue_detail/1, %{
        issue: issue,
        detail: detail,
        detail_status: %{availability: :available, freshness: :fresh, refresh: :idle, last_error: nil},
        runtime: %{},
        pr_data: issue.pr_data,
        gatekeeper: %{
          status: %{availability: :available, freshness: :fresh},
          data: %{health: %{heartbeat: :fresh, scan: :unknown, heartbeat_age_ms: 12}}
        },
        comment_page: 1,
        expanded_pr: {:github_files, "example-org/example-repo", 1, "head", 1},
        file_detail: %{
          page: 1,
          head_sha: "head",
          files: [%{filename: "asset.png", status: "modified", additions: 1, deletions: 0, patch_status: :unavailable}],
          has_next?: false,
          truncated?: false,
          budgets: %{files: 20, lines: 500, bytes: 262_144}
        }
      })

    assert html =~ "&lt;script&gt;bad&lt;/script&gt;"
    assert html =~ "&lt;img src=x onerror=alert(1)&gt;"
    assert html =~ "resolution unknown"
    assert html =~ "metadata only"
    assert html =~ "process heartbeat fresh"
    refute html =~ "<script>bad</script>"
  end

  test "the same Merging action component distinguishes ready, waiting, conflict, failure, and completed facts" do
    issue = %{id: "issue-1", identifier: "EXM-1", state_name: "In Review", pr_data: %{prs: []}}
    enabled = {:ok, %{enabled?: true}}

    ready = render_action(issue, enabled, %{})
    assert ready =~ "Merging"
    assert ready =~ "Only updates Linear status; Gatekeeper handles the next step."
    assert ready =~ "phx-click=\"merging-open\""

    waiting = render_action(issue, enabled, %{"issue-1" => %{status: :waiting_gatekeeper}})
    assert waiting =~ "Waiting Gatekeeper"
    assert waiting =~ "does not mean the PR has merged"

    attention =
      render_action(%{issue | state_name: "Merging"}, enabled, %{}, %{status: %{availability: :unavailable}})

    assert attention =~ "Gatekeeper needs attention"

    conflict = render_action(issue, enabled, %{"issue-1" => %{status: :conflict}})
    assert conflict =~ "State changed externally"

    failed = render_action(issue, enabled, %{"issue-1" => %{status: :failed}})
    assert failed =~ "Merging submission failed"

    completed = render_action(%{issue | pr_data: %{prs: [%{state: :merged}]}}, enabled, %{})
    assert completed =~ "PR merged"
    assert completed =~ "not from the Linear transition alone"
  end

  test "Needs Info offers only a safe handoff to Linear" do
    issue = %{
      id: "issue-1",
      identifier: "EXM-1",
      state_name: "Needs Info",
      url: "https://linear.app/example/issue/EXM-1/example",
      pr_data: %{prs: []}
    }

    html = render_action(issue, {:ok, %{enabled?: true}}, %{})

    assert html =~ "Open in Linear"
    assert html =~ ~s(href="https://linear.app/example/issue/EXM-1/example")
    assert html =~ ~s(target="_blank")
    assert html =~ ~s(rel="noopener noreferrer")
    assert html =~ "This dashboard remains read-only."
    refute html =~ ~s(phx-click="merging-open")

    unsafe = render_action(%{issue | url: "javascript:alert(1)"}, {:ok, %{enabled?: true}}, %{})
    refute unsafe =~ "Open in Linear"
    refute unsafe =~ "javascript:"
    assert unsafe =~ "Linear issue link is unavailable."
  end

  test "confirmation dialog describes the Linear-only scope and has no merge control" do
    html =
      render_component(&MergingActionComponents.confirmation_dialog/1, %{
        confirmation: %{
          issue: %{id: "issue-1", identifier: "EXM-1", state_name: "In Review", pr_data: %{prs: [%{number: 42}]}},
          phase: :ready
        }
      })

    assert html =~ "Move EXM-1 to Merging?"
    assert html =~ "Only updates Linear status; Gatekeeper handles the next step."
    assert html =~ "Confirm Merging"
    assert html =~ "will not be merged by this page"
    refute html =~ "Merge PR"
  end

  defp render_action(issue, action_scope, actions, gatekeeper \\ nil) do
    render_component(&MergingActionComponents.action_control/1, %{
      issue: issue,
      action_scope: action_scope,
      actions: actions,
      gatekeeper: gatekeeper
    })
  end
end
