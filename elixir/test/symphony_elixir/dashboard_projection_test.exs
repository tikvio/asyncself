defmodule SymphonyElixir.DashboardProjectionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.DashboardProjection

  test "terminal status is based on Linear state type rather than its display name" do
    assert DashboardProjection.terminal_state?("completed")
    assert DashboardProjection.terminal_state?("canceled")
    refute DashboardProjection.terminal_state?("Done")
    assert DashboardProjection.terminal_state?(nil) == :unknown
  end

  test "runtime treats a complete fresh snapshot with no entry as idle" do
    assert DashboardProjection.runtime_state("issue-1", %{running: [], retrying: [], blocked: []}) == "idle"
    assert DashboardProjection.runtime_state("issue-1", :unavailable) == "unavailable"
    assert DashboardProjection.runtime_state("issue-1", %{}) == "unknown"
  end

  test "runtime mapping uses the stable Linear issue id and leaves unrelated issues idle" do
    issues = [%{id: "linear-1"}, %{id: "linear-2"}]
    payload = %{running: [%{issue_id: "linear-1"}], retrying: [], blocked: []}

    assert [%{runtime_state: "running"}, %{runtime_state: "idle"}] =
             DashboardProjection.attach_runtime(issues, payload)

    assert [%{runtime_state: "unavailable"}, %{runtime_state: "unavailable"}] =
             DashboardProjection.attach_runtime(issues, %{error: %{code: "snapshot_unavailable"}})
  end

  test "review verdicts retain unknown rather than turning incomplete responses into false" do
    assert %{value: :unknown} = DashboardProjection.review_attention(%{complete?: false})
    assert %{value: true} = DashboardProjection.review_attention(%{complete?: true, unresolved_threads: 1})
    assert %{value: false} = DashboardProjection.review_waiting(%{complete?: true, draft?: true})
    assert %{value: :unknown} = DashboardProjection.review_waiting(%{checks: :unknown})
  end

  test "A3 three-value fixtures distinguish draft, pending, no reviewers, comments and unknown" do
    draft = pr(draft?: true, checks: :passed, decision: :none, unresolved: 0)
    pending = pr(checks: :pending, decision: :none, unresolved: 0)
    no_reviewer = pr(checks: :passed, decision: :none, unresolved: 0)
    comment_only = pr(checks: :passed, decision: :none, unresolved: 0)

    assert %{review_waiting: %{value: false}} = DashboardProjection.pr_verdicts(%{complete?: true, prs: [draft]})
    assert %{review_waiting: %{value: false}} = DashboardProjection.pr_verdicts(%{complete?: true, prs: [pending]})

    assert %{review_waiting: %{value: true}, review_attention: %{value: false}} =
             DashboardProjection.pr_verdicts(%{complete?: true, prs: [no_reviewer]})

    assert %{review_attention: %{value: false}} =
             DashboardProjection.pr_verdicts(%{complete?: true, prs: [comment_only]})

    assert %{review_attention: %{value: :unknown}} = DashboardProjection.pr_verdicts(%{complete?: false})
  end

  test "multiple PRs preserve changes requests and scope warnings as separate evidence" do
    requested = pr(decision: :changes_requested)
    valid = pr(number: 2, decision: :none)
    warning = Map.put(pr(number: 3), :scope, {:warning, :base_mismatch})

    assert %{review_attention: %{value: true}} =
             DashboardProjection.pr_verdicts(%{complete?: true, prs: [requested, valid]})

    assert %{delivery_exception: %{value: true}, review_waiting: %{value: :unknown}} =
             DashboardProjection.pr_verdicts(%{complete?: true, prs: [valid, warning]})
  end

  test "only a level-two Start Gate section contributes gates" do
    body = "- [ ] ordinary checklist\n## Start Gate\n- [ ] human: approve release\n- [x] dep:EXM-12 dependency\n## Notes\n- [ ] human: ignored"
    assert DashboardProjection.parse_start_gate(body) == %{human: ["approve release"], dependencies: ["EXM-12"], unknown: []}
  end

  test "Start Gate keeps checkbox state and unsupported lines separate from ordinary checklists" do
    body = "- [x] ordinary\n## Start Gate\n- [x] human: sign off\n- [ ] dep:EXM-9 upstream\n- [ ] legacy item\n- human: old format\n### Start Gate\n- [x] human: ignored"
    gates = DashboardProjection.parse_start_gate_details(body)

    assert gates.human == [
             %{checked?: true, text: "sign off", raw: "- [x] human: sign off"},
             %{checked?: true, text: "ignored", raw: "- [x] human: ignored"}
           ]

    assert gates.dependencies == [%{checked?: false, identifier: "EXM-9", text: "upstream", raw: "- [ ] dep:EXM-9 upstream"}]
    assert gates.unknown == ["- [ ] legacy item", "- human: old format"]
  end

  defp pr(overrides) do
    defaults = %{
      number: 1,
      state: :open,
      draft?: false,
      scope: :valid,
      checks: %{state: :passed, head_sha: "head"},
      reviews: %{decision: :none, complete?: true},
      threads: %{unresolved: 0, complete?: true}
    }

    {decision, overrides} = Keyword.pop(overrides, :decision, :none)
    {unresolved, overrides} = Keyword.pop(overrides, :unresolved, 0)
    {checks, overrides} = Keyword.pop(overrides, :checks, :passed)

    defaults
    |> Map.merge(Map.new(overrides))
    |> Map.put(:checks, %{state: checks, head_sha: "head"})
    |> Map.put(:reviews, %{decision: decision, complete?: true})
    |> Map.put(:threads, %{unresolved: unresolved, complete?: true})
  end
end
