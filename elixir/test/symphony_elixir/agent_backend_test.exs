defmodule SymphonyElixir.AgentBackendTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentBackend.{Codex, Runtime, Usage}
  alias SymphonyElixir.Config.Schema

  test "missing backend defaults to codex and does not require dsh" do
    {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "linear"}})
    assert {:ok, runtime} = Runtime.build(settings, skip_command: true)
    assert runtime.backend == :codex
    assert runtime.adapter == Codex
  end

  test "deepseek rejects ssh and non-linear trackers" do
    {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "linear"}, "agent" => %{"backend" => "deepseek"}, "worker" => %{"ssh_hosts" => ["worker"]}})
    assert {:error, {:unsupported_topology, :deepseek_ssh}} = Runtime.build(settings, skip_command: true)

    {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "github"}, "agent" => %{"backend" => "deepseek"}})
    assert {:error, {:unsupported_tracker, "github"}} = Runtime.build(settings, skip_command: true)
  end

  test "deepseek rejects an unsafe comparable-token ceiling" do
    {:ok, settings} =
      Schema.parse(%{
        "tracker" => %{"kind" => "linear"},
        "agent" => %{"backend" => "deepseek", "max_tokens_per_run" => 1}
      })

    assert {:error, :deepseek_usage_not_comparable_to_token_ceiling} = Runtime.build(settings, skip_command: true)
  end

  test "unknown usage is not comparable to a token ceiling" do
    usage = Usage.unknown(:deepseek, "acp/session/update")
    refute Usage.comparable?(usage)
    assert usage.value == nil

    billable = Usage.billable_tokens(:codex, 7, "codex/turn")
    assert Usage.comparable?(billable)
    assert billable.unit == :tokens
  end

  test "adapter selects DeepSeek only for its frozen backend runtime" do
    assert SymphonyElixir.AgentBackend.adapter(%{backend: :deepseek}) == SymphonyElixir.AgentBackend.DeepSeek
    assert SymphonyElixir.AgentBackend.adapter(%{backend: :codex}) == Codex
  end

  test "deepseek settings accept separately configured timeout boundaries" do
    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{"kind" => "linear"},
               "agent" => %{"backend" => "deepseek"},
               "deepseek" => %{
                 "handshake_timeout_ms" => 1,
                 "read_timeout_ms" => 2,
                 "progress_timeout_ms" => 3,
                 "turn_timeout_ms" => 4
               }
             })

    assert settings.deepseek.handshake_timeout_ms == 1
    assert settings.deepseek.read_timeout_ms == 2
    assert settings.deepseek.progress_timeout_ms == 3
    assert settings.deepseek.turn_timeout_ms == 4
  end

  test "codex adapter exposes the shared deferred-turn contract" do
    issue = %{id: "issue-1"}
    assert {:ok, turn} = Codex.start_turn(:session, "prompt", issue, marker: :kept)
    assert turn.prompt == "prompt"
    assert turn.issue == issue
    assert turn.opts == [marker: :kept]
  end

  test "static validation checks only the selected Codex command" do
    {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "linear"}})

    assert :ok = Runtime.validate(settings, command_checker: fn "codex" -> "/fixture/codex" end)
    assert {:error, {:cli_not_found, "codex"}} = Runtime.validate(settings, command_checker: fn _ -> nil end)
  end

  test "CLI version probes return classified failures" do
    assert {:ok, "0.2.1-rc.2"} = Runtime.version("dsh")
    assert {:error, {:cli_version_failed, "sh", _status, _output}} = Runtime.version("sh")
    assert {:error, {:cli_not_found, "asyncself-no-such-cli", _message}} = Runtime.version("asyncself-no-such-cli")
  end

  test "runtime validates only the exact DeepSeek ACP command" do
    {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "linear"}, "agent" => %{"backend" => "deepseek"}})
    assert :ok = Runtime.validate(settings)

    {:ok, invalid} =
      Schema.parse(%{
        "tracker" => %{"kind" => "linear"},
        "agent" => %{"backend" => "deepseek"},
        "deepseek" => %{"command" => "not-dsh"}
      })

    assert {:error, :invalid_deepseek_command} = Runtime.build(invalid)

    {:ok, similarly_named} =
      Schema.parse(%{
        "tracker" => %{"kind" => "linear"},
        "agent" => %{"backend" => "deepseek"},
        "deepseek" => %{"command" => "dsh-wrapper --profile acp"}
      })

    assert {:error, :invalid_deepseek_command} = Runtime.build(similarly_named)
  end
end
