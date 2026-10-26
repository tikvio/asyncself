defmodule SymphonyElixir.PreflightTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Preflight

  defmodule FakeDeepSeek do
    def start_session(_workspace, _opts), do: {:ok, :session}
    def start_turn(:session, _prompt, _issue), do: {:ok, :turn}
    def await_turn(:session, :turn, _timeouts), do: {:ok, %{}}
    def close_session(:session), do: :ok
  end

  test "static Codex preflight validates the selected command without requiring dsh" do
    root = Path.join(System.tmp_dir!(), "asyncself-preflight-test-#{System.unique_integer([:positive])}")
    workflow = Path.join(root, "WORKFLOW.md")
    File.mkdir_p!(root)

    File.write!(
      workflow,
      """
      ---
      tracker:
        kind: linear
        api_key: fixture-token
        project_slug: asyncself-preflight
      agent:
        backend: codex
      codex:
        command: sh -c ignored
      ---

      Fixture workflow.
      """
    )

    on_exit(fn -> File.rm_rf(root) end)
    assert :ok = Preflight.check(workflow, :static)
  end

  test "DeepSeek preflight keeps static and live requests separate with injected protocol dependencies" do
    root = Path.join(System.tmp_dir!(), "asyncself-deepseek-preflight-test-#{System.unique_integer([:positive])}")
    workflow = Path.join(root, "WORKFLOW.md")
    File.mkdir_p!(root)

    File.write!(
      workflow,
      """
      ---
      tracker:
        kind: linear
        api_key: fixture-token
        project_slug: asyncself-preflight
      agent:
        backend: deepseek
      ---

      Fixture workflow.
      """
    )

    on_exit(fn -> File.rm_rf(root) end)

    deps = [
      validate_runtime: fn _ -> :ok end,
      deepseek_adapter: FakeDeepSeek,
      mcp_servers: fn _ -> {:ok, [%{name: "fixture"}]} end
    ]

    assert :ok = Preflight.check(workflow, :static, deps)
    assert :ok = Preflight.check(workflow, :live, deps)
  end

  test "live Codex preflight remains explicitly unsupported" do
    root = Path.join(System.tmp_dir!(), "asyncself-codex-live-preflight-test-#{System.unique_integer([:positive])}")
    workflow = Path.join(root, "WORKFLOW.md")
    File.mkdir_p!(root)

    File.write!(workflow, "---\ntracker:\n  kind: linear\n  api_key: fixture-token\n  project_slug: asyncself-preflight\nagent:\n  backend: codex\ncodex:\n  command: sh\n---\nFixture.\n")
    on_exit(fn -> File.rm_rf(root) end)
    assert {:error, :codex_live_preflight_not_supported} = Preflight.check(workflow, :live)
  end
end
