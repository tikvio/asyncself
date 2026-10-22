defmodule SymphonyElixir.AgentRunnerGuardTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.Tracker.Issue

  @issue %Issue{id: "issue-1", identifier: "SYM-1", state: "In Progress", description: "same"}

  test "counts only clean turns with unchanged workspace and issue" do
    assert AgentRunner.next_no_progress_count(0, {:clean, "abc"}, {:clean, "abc"}, @issue, @issue, false) == 1
    assert AgentRunner.next_no_progress_count(1, {:clean, "abc"}, {:clean, "abc"}, @issue, @issue, false) == 2
    assert AgentRunner.next_no_progress_count(2, {:clean, "abc"}, {:clean, "abc"}, @issue, @issue, false) == 3
  end

  test "dirty or changed workspace never counts as no progress" do
    assert AgentRunner.next_no_progress_count(2, :unknown, :unknown, @issue, @issue, false) == 0
    assert AgentRunner.next_no_progress_count(2, {:clean, "abc"}, {:clean, "def"}, @issue, @issue, false) == 0
  end

  test "issue updates and tool actions reset the count" do
    changed = %Issue{@issue | description: "new"}
    assert AgentRunner.next_no_progress_count(2, {:clean, "abc"}, {:clean, "abc"}, @issue, changed, false) == 0
    assert AgentRunner.next_no_progress_count(2, {:clean, "abc"}, {:clean, "abc"}, @issue, @issue, true) == 0
  end

  test "no-progress message blocks the issue and removes its running claim without retry" do
    running_entry = %{identifier: "SYM-1", issue: @issue, pid: self(), ref: make_ref()}
    state = %State{running: %{"issue-1" => running_entry}, claimed: MapSet.new(["issue-1"])}

    assert {:noreply, updated} = Orchestrator.handle_info({:agent_no_progress, "issue-1", "no progress"}, state)
    assert updated.running == %{}
    assert updated.retry_attempts == %{}
    assert updated.blocked["issue-1"].error == "no progress"
    assert MapSet.member?(updated.claimed, "issue-1")
  end

  test "token ceiling reads the current issue run, not process-wide dashboard totals" do
    assert Orchestrator.run_token_count(%{codex_total_tokens: 10}) == 10
    assert Orchestrator.run_token_count(%{codex_total_tokens: 0}) == 0
  end

  test "token usage fixture diffs cumulative AppServer payloads once" do
    first = %{
      event: :notification,
      timestamp: ~U[2026-09-29 03:47:52Z],
      payload: %{
        "params" => %{
          "msg" => %{
            "payload" => %{
              "info" => %{"total_token_usage" => %{"input_tokens" => 100, "output_tokens" => 10, "total_tokens" => 110}}
            }
          }
        }
      }
    }

    second =
      put_in(first, [:payload, "params", "msg", "payload", "info", "total_token_usage"], %{
        "input_tokens" => 150,
        "output_tokens" => 20,
        "total_tokens" => 170
      })

    assert Orchestrator.token_delta_for_test(%{}, first) == %{
             input_tokens: 100,
             output_tokens: 10,
             total_tokens: 110,
             input_reported: 100,
             output_reported: 10,
             total_reported: 110
           }

    entry = %{
      codex_last_reported_input_tokens: 100,
      codex_last_reported_output_tokens: 10,
      codex_last_reported_total_tokens: 110
    }

    assert Orchestrator.token_delta_for_test(entry, second).total_tokens == 60

    reported_entry = %{
      codex_last_reported_total_tokens: 170,
      codex_last_reported_input_tokens: 150,
      codex_last_reported_output_tokens: 20
    }

    assert Orchestrator.token_delta_for_test(Map.merge(entry, reported_entry), second).total_tokens ==
             0

    assert Orchestrator.token_totals_for_test([first, second, second]) == %{
             input_tokens: 150,
             output_tokens: 20,
             total_tokens: 170,
             seconds_running: 0
           }
  end

  test "read-only tool and command probes do not count as progress" do
    refute AgentRunner.progress_action_for_test(%{
             event: :tool_call_completed,
             payload: %{"tool" => "linear_get_issue_context"}
           })

    refute AgentRunner.progress_action_for_test(%{
             event: :notification,
             payload: %{
               "method" => "item/completed",
               "params" => %{
                 "item" => %{"type" => "commandExecution", "command" => "git status --short"}
               }
             }
           })

    assert AgentRunner.progress_action_for_test(%{
             event: :notification,
             payload: %{"method" => "item/completed", "params" => %{"item" => %{"type" => "commandExecution", "command" => "npm run build"}}}
           })
  end

  test "runner-level tool budget classifies tool and command events" do
    assert AgentRunner.tool_call_event_for_test(%{event: :tool_call_completed, payload: %{}})

    assert AgentRunner.tool_call_event_for_test(%{
             event: :notification,
             payload: %{"method" => "item/completed", "params" => %{"item" => %{"type" => "commandExecution"}}}
           })

    assert AgentRunner.tool_call_event_for_test(%{
             event: :notification,
             payload: %{"method" => "item/completed", "params" => %{"item" => %{"type" => "CommandExecution"}}}
           })

    assert AgentRunner.tool_call_event_for_test(%{
             event: :notification,
             payload: %{"method" => "item/completed", "params" => %{"item" => %{"type" => "DynamicToolCall"}}}
           })

    refute AgentRunner.tool_call_event_for_test(%{event: :tool_call_failed})
    refute AgentRunner.tool_call_event_for_test(%{event: :notification, payload: %{"method" => "turn/started"}})
  end
end
