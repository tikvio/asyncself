defmodule SymphonyElixir.DeepSeekAdapterTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentBackend.DeepSeek

  test "real pinned dsh ACP handshake is stdout-clean in an isolated profile" do
    workspace = Path.join(System.tmp_dir!(), "asyncself-dsh-test-#{System.unique_integer([:positive])}")
    dsh_home = Path.join(System.tmp_dir!(), "asyncself-dsh-home-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf(workspace)
      File.rm_rf(dsh_home)
    end)

    assert {:ok, session} =
             DeepSeek.start_session(workspace,
               command: "dsh --profile acp",
               dsh_home: dsh_home,
               handshake_timeout_ms: 15_000
             )

    assert is_pid(session.owner)
    assert :ok = DeepSeek.cancel_turn(session, %{}, :test)
    assert :ok = DeepSeek.close_session(session)
  end

  test "real pinned dsh ACP mounts an absolute stdio MCP command" do
    workspace = Path.join(System.tmp_dir!(), "asyncself-dsh-mcp-#{System.unique_integer([:positive])}")
    dsh_home = Path.join(System.tmp_dir!(), "asyncself-dsh-mcp-home-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf(workspace)
      File.rm_rf(dsh_home)
    end)

    fixture = Path.expand("../fixtures/stdio_mcp_fixture.cjs", __DIR__)

    assert {:ok, session} =
             DeepSeek.start_session(workspace,
               command: "dsh --profile acp",
               dsh_home: dsh_home,
               mcp_servers: [%{name: "fixture", command: System.find_executable("node"), args: [fixture]}],
               handshake_timeout_ms: 15_000
             )

    assert :ok = DeepSeek.close_session(session)
  end

  test "ACP distinguishes read inactivity, progress, wall-clock, and child exit" do
    cases = [
      silence: :read_inactivity_timeout,
      noise: :progress_timeout,
      progress: :turn_timeout,
      exit: {:port_exit, 17}
    ]

    for {mode, expected} <- cases do
      assert_timeout_mode(mode, expected)
    end
  end

  test "ACP rejects malformed frames and responds deterministically to server requests" do
    assert_fixture_turn(:error, fn result -> assert {:error, {:acp_error, %{"code" => -32_000}}} = result end)
    assert_fixture_turn(:invalid, fn result -> assert {:error, {:invalid_stdout_frame, _reason}} = result end)
    assert_fixture_turn(:permission, fn result -> assert {:ok, %{result: %{"handled" => true}}} = result end)
    assert_fixture_turn(:unknown_request, fn result -> assert {:ok, %{result: %{"handled" => true}}} = result end)
  end

  test "ACP startup rejects unsupported commands and malformed handshakes without crashing its caller" do
    root = Path.join(System.tmp_dir!(), "asyncself-acp-handshake-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    launcher = Path.join(root, "dsh")
    fixture = Path.expand("../fixtures/acp_timeout_fixture.cjs", __DIR__)
    File.write!(launcher, "#!/bin/sh\nexec \"#{fixture}\" \"$@\"\n")
    File.chmod!(launcher, 0o755)
    old_mode = System.get_env("ASYNCSELF_FAKE_ACP_MODE")

    try do
      assert {:error, {:unsupported_deepseek_command, "fixture"}} = DeepSeek.start_session(workspace, command: "fixture")
      assert {:error, {:dsh_launcher_unreadable, _, :enoent}} = DeepSeek.start_session(workspace, dsh_executable: Path.join(root, "missing-dsh"))

      System.put_env("ASYNCSELF_FAKE_ACP_MODE", "handshake_invalid")

      assert {:error, {:invalid_stdout_frame, _reason}} =
               DeepSeek.start_session(workspace, handshake_timeout_ms: 500, dsh_executable: launcher)

      System.put_env("ASYNCSELF_FAKE_ACP_MODE", "handshake_missing")

      assert {:error, {:missing_session_id, %{}}} =
               DeepSeek.start_session(workspace, handshake_timeout_ms: 500, dsh_executable: launcher)
    after
      if old_mode, do: System.put_env("ASYNCSELF_FAKE_ACP_MODE", old_mode), else: System.delete_env("ASYNCSELF_FAKE_ACP_MODE")
      File.rm_rf(root)
    end
  end

  test "closed owner APIs are idempotent" do
    owner = spawn(fn -> :ok end)
    assert_eventually(fn -> not Process.alive?(owner) end)
    assert {:error, :session_closed} = DeepSeek.await_turn(%{owner: owner}, %{})
    assert :ok = DeepSeek.cancel_turn(%{owner: owner}, %{}, :test)
    assert :ok = DeepSeek.close_session(%{owner: owner})
    assert DeepSeek.bounded_stderr("/tmp/asyncself-no-such-stderr-file") == ""
    stderr_path = Path.join(System.tmp_dir!(), "asyncself-bounded-stderr-#{System.unique_integer([:positive])}")
    File.write!(stderr_path, String.duplicate("x", 5_000))
    on_exit(fn -> File.rm(stderr_path) end)
    assert byte_size(DeepSeek.bounded_stderr(stderr_path)) == 4_096
  end

  test "idle owner ignores late ACP port frames after a completed control request" do
    root = Path.join(System.tmp_dir!(), "asyncself-acp-late-frame-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    launcher = Path.join(root, "dsh")
    fixture = Path.expand("../fixtures/acp_timeout_fixture.cjs", __DIR__)
    File.write!(launcher, "#!/bin/sh\nexec \"#{fixture}\" \"$@\"\n")
    File.chmod!(launcher, 0o755)

    try do
      assert {:ok, session} = DeepSeek.start_session(workspace, handshake_timeout_ms: 500, dsh_executable: launcher)
      %{session: %{port: port}} = :sys.get_state(session.owner)
      send(session.owner, {port, {:data, {:eol, "{\"jsonrpc\":\"2.0\"}"}}})
      send(session.owner, {port, {:exit_status, 0}})
      assert Process.alive?(session.owner)
      assert :ok = DeepSeek.close_session(session)
    after
      File.rm_rf(root)
    end
  end

  test "owner accepts cancellation while another process awaits the turn" do
    root = Path.join(System.tmp_dir!(), "asyncself-acp-concurrent-cancel-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    launcher = Path.join(root, "dsh")
    fixture = Path.expand("../fixtures/acp_timeout_fixture.cjs", __DIR__)
    File.write!(launcher, "#!/bin/sh\nexec \"#{fixture}\" \"$@\"\n")
    File.chmod!(launcher, 0o755)
    old_mode = System.get_env("ASYNCSELF_FAKE_ACP_MODE")
    System.put_env("ASYNCSELF_FAKE_ACP_MODE", "silence")

    try do
      assert {:ok, session} = DeepSeek.start_session(workspace, handshake_timeout_ms: 500, dsh_executable: launcher)
      assert {:ok, turn} = DeepSeek.start_turn(session, "fixture", %{})
      task = Task.async(fn -> DeepSeek.await_turn(session, turn, read_timeout_ms: 1_000, turn_timeout_ms: 2_000) end)
      assert :ok = DeepSeek.cancel_turn(session, turn, :test)
      assert {:ok, %{result: %{"stopped" => true}}} = Task.await(task, 2_000)
      assert :ok = DeepSeek.close_session(session)
    after
      if old_mode, do: System.put_env("ASYNCSELF_FAKE_ACP_MODE", old_mode), else: System.delete_env("ASYNCSELF_FAKE_ACP_MODE")
      File.rm_rf(root)
    end
  end

  test "owner closes while another process awaits the turn" do
    root = Path.join(System.tmp_dir!(), "asyncself-acp-concurrent-close-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    launcher = Path.join(root, "dsh")
    fixture = Path.expand("../fixtures/acp_timeout_fixture.cjs", __DIR__)
    File.write!(launcher, "#!/bin/sh\nexec \"#{fixture}\" \"$@\"\n")
    File.chmod!(launcher, 0o755)
    old_mode = System.get_env("ASYNCSELF_FAKE_ACP_MODE")
    System.put_env("ASYNCSELF_FAKE_ACP_MODE", "silence")

    try do
      assert {:ok, session} = DeepSeek.start_session(workspace, handshake_timeout_ms: 500, dsh_executable: launcher)
      assert {:ok, turn} = DeepSeek.start_turn(session, "fixture", %{})
      task = Task.async(fn -> DeepSeek.await_turn(session, turn, read_timeout_ms: 1_000, turn_timeout_ms: 2_000) end)
      assert :ok = DeepSeek.close_session(session)
      assert {:error, :session_closed} = Task.await(task, 2_000)
    after
      if old_mode, do: System.put_env("ASYNCSELF_FAKE_ACP_MODE", old_mode), else: System.delete_env("ASYNCSELF_FAKE_ACP_MODE")
      File.rm_rf(root)
    end
  end

  test "ACP close reaps its isolated process group" do
    root = Path.join(System.tmp_dir!(), "asyncself-acp-child-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    pid_path = Path.join(root, "child.pid")
    File.mkdir_p!(workspace)
    launcher = Path.join(root, "dsh")
    fixture = Path.expand("../fixtures/acp_timeout_fixture.cjs", __DIR__)
    File.write!(launcher, "#!/bin/sh\nexec \"#{fixture}\" \"$@\"\n")
    File.chmod!(launcher, 0o755)
    old_mode = System.get_env("ASYNCSELF_FAKE_ACP_MODE")
    old_pid_path = System.get_env("ASYNCSELF_FAKE_ACP_CHILD_PID_PATH")
    System.put_env("ASYNCSELF_FAKE_ACP_MODE", "child")
    System.put_env("ASYNCSELF_FAKE_ACP_CHILD_PID_PATH", pid_path)

    try do
      assert {:ok, session} = DeepSeek.start_session(workspace, handshake_timeout_ms: 500, dsh_executable: launcher)
      assert is_pid(session.owner)
      assert {:ok, child_pid_text} = File.read(pid_path)
      child_pid = String.to_integer(String.trim(child_pid_text))
      assert File.exists?("/proc/#{child_pid}")
      assert :ok = DeepSeek.close_session(session)
      assert_eventually(fn -> not process_alive?(child_pid) end)
    after
      if old_mode, do: System.put_env("ASYNCSELF_FAKE_ACP_MODE", old_mode), else: System.delete_env("ASYNCSELF_FAKE_ACP_MODE")
      if old_pid_path, do: System.put_env("ASYNCSELF_FAKE_ACP_CHILD_PID_PATH", old_pid_path), else: System.delete_env("ASYNCSELF_FAKE_ACP_CHILD_PID_PATH")
      File.rm_rf(root)
    end
  end

  test "owner shutdown reaps its isolated ACP process group" do
    root = Path.join(System.tmp_dir!(), "asyncself-acp-owner-stop-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    pid_path = Path.join(root, "child.pid")
    File.mkdir_p!(workspace)
    launcher = Path.join(root, "dsh")
    fixture = Path.expand("../fixtures/acp_timeout_fixture.cjs", __DIR__)
    File.write!(launcher, "#!/bin/sh\nexec \"#{fixture}\" \"$@\"\n")
    File.chmod!(launcher, 0o755)
    old_mode = System.get_env("ASYNCSELF_FAKE_ACP_MODE")
    old_pid_path = System.get_env("ASYNCSELF_FAKE_ACP_CHILD_PID_PATH")
    System.put_env("ASYNCSELF_FAKE_ACP_MODE", "child")
    System.put_env("ASYNCSELF_FAKE_ACP_CHILD_PID_PATH", pid_path)

    try do
      assert {:ok, session} = DeepSeek.start_session(workspace, handshake_timeout_ms: 500, dsh_executable: launcher)
      assert {:ok, child_pid_text} = File.read(pid_path)
      child_pid = String.to_integer(String.trim(child_pid_text))
      Process.unlink(session.owner)
      monitor = Process.monitor(session.owner)
      Process.exit(session.owner, :shutdown)
      assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
      assert_eventually(fn -> not process_alive?(child_pid) end)
    after
      if old_mode, do: System.put_env("ASYNCSELF_FAKE_ACP_MODE", old_mode), else: System.delete_env("ASYNCSELF_FAKE_ACP_MODE")
      if old_pid_path, do: System.put_env("ASYNCSELF_FAKE_ACP_CHILD_PID_PATH", old_pid_path), else: System.delete_env("ASYNCSELF_FAKE_ACP_CHILD_PID_PATH")
      File.rm_rf(root)
    end
  end

  @tag real_account: true
  @tag skip: System.get_env("ASYNCSELF_DSH_REAL_ACCOUNT") != "1"
  test "real account ACP handshake is stdout-clean without changing the profile" do
    workspace = Path.join(System.tmp_dir!(), "asyncself-dsh-account-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    assert {:ok, session} =
             DeepSeek.start_session(workspace,
               command: "dsh --profile acp",
               handshake_timeout_ms: 15_000
             )

    assert is_pid(session.owner)
    assert :ok = DeepSeek.cancel_turn(session, %{}, :test)
    assert :ok = DeepSeek.close_session(session)
  end

  @tag real_account: true
  @tag skip: System.get_env("ASYNCSELF_DSH_LIVE") != "1"
  test "real account ACP completes a minimal model prompt" do
    workspace = Path.join(System.tmp_dir!(), "asyncself-dsh-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    assert {:ok, session} =
             DeepSeek.start_session(workspace,
               command: "dsh --profile acp",
               handshake_timeout_ms: 15_000
             )

    try do
      assert {:ok, turn} =
               DeepSeek.start_turn(session, "Reply with exactly: ASYNCSELF_ACP_OK", %{})

      assert {:ok, %{result: result}} =
               DeepSeek.await_turn(session, turn, turn_timeout_ms: 120_000)

      assert is_map(result)

      assert {:ok, second_turn} =
               DeepSeek.start_turn(session, "Reply with exactly: ASYNCSELF_ACP_SECOND", %{})

      assert second_turn.turn_id > turn.turn_id

      assert {:ok, %{result: second_result}} =
               DeepSeek.await_turn(session, second_turn, turn_timeout_ms: 120_000)

      assert is_map(second_result)
    after
      assert :ok = DeepSeek.close_session(session)
    end
  end

  @tag real_account: true
  @tag skip: System.get_env("ASYNCSELF_DSH_LIVE") != "1"
  test "real account ACP accepts cancellation of an in-flight prompt" do
    workspace = Path.join(System.tmp_dir!(), "asyncself-dsh-cancel-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    assert {:ok, session} =
             DeepSeek.start_session(workspace,
               command: "dsh --profile acp",
               handshake_timeout_ms: 15_000
             )

    try do
      assert {:ok, turn} =
               DeepSeek.start_turn(session, "Think carefully about a large software design before replying.", %{})

      assert :ok = DeepSeek.cancel_turn(session, turn, :test_cancellation)
      assert {:ok, _result} = DeepSeek.await_turn(session, turn, turn_timeout_ms: 120_000)
    after
      assert :ok = DeepSeek.close_session(session)
    end
  end

  defp assert_timeout_mode(mode, expected) do
    root = Path.join(System.tmp_dir!(), "asyncself-acp-timeout-#{mode}-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    launcher = Path.join(root, "dsh")
    fixture = Path.expand("../fixtures/acp_timeout_fixture.cjs", __DIR__)
    File.write!(launcher, "#!/bin/sh\nexec \"#{fixture}\" \"$@\"\n")
    File.chmod!(launcher, 0o755)
    old_mode = System.get_env("ASYNCSELF_FAKE_ACP_MODE")
    System.put_env("ASYNCSELF_FAKE_ACP_MODE", Atom.to_string(mode))

    try do
      assert {:ok, session} = DeepSeek.start_session(workspace, handshake_timeout_ms: 500, dsh_executable: launcher)
      assert {:ok, turn} = DeepSeek.start_turn(session, "fixture", %{})

      {read_timeout_ms, progress_timeout_ms, turn_timeout_ms} =
        if mode == :silence, do: {15, 150, 300}, else: {80, 45, 120}

      assert {:error, ^expected} =
               DeepSeek.await_turn(session, turn,
                 read_timeout_ms: read_timeout_ms,
                 progress_timeout_ms: progress_timeout_ms,
                 turn_timeout_ms: turn_timeout_ms
               )

      assert :ok = DeepSeek.close_session(session)
    after
      if old_mode, do: System.put_env("ASYNCSELF_FAKE_ACP_MODE", old_mode), else: System.delete_env("ASYNCSELF_FAKE_ACP_MODE")
      File.rm_rf(root)
    end
  end

  defp assert_fixture_turn(mode, assertion) when is_function(assertion, 1) do
    root = Path.join(System.tmp_dir!(), "asyncself-acp-response-#{mode}-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    launcher = Path.join(root, "dsh")
    fixture = Path.expand("../fixtures/acp_timeout_fixture.cjs", __DIR__)
    File.write!(launcher, "#!/bin/sh\nexec \"#{fixture}\" \"$@\"\n")
    File.chmod!(launcher, 0o755)
    old_mode = System.get_env("ASYNCSELF_FAKE_ACP_MODE")
    System.put_env("ASYNCSELF_FAKE_ACP_MODE", Atom.to_string(mode))

    try do
      assert {:ok, session} = DeepSeek.start_session(workspace, handshake_timeout_ms: 500, dsh_executable: launcher)
      assert {:ok, turn} = DeepSeek.start_turn(session, "fixture", %{})

      result =
        DeepSeek.await_turn(session, turn,
          read_timeout_ms: 250,
          progress_timeout_ms: 250,
          turn_timeout_ms: 1_000
        )

      assertion.(result)
      assert :ok = DeepSeek.close_session(session)
    after
      if old_mode, do: System.put_env("ASYNCSELF_FAKE_ACP_MODE", old_mode), else: System.delete_env("ASYNCSELF_FAKE_ACP_MODE")
      File.rm_rf(root)
    end
  end

  defp assert_eventually(predicate, attempts \\ 20)

  defp assert_eventually(predicate, attempts) when attempts > 0 do
    if predicate.() do
      :ok
    else
      Process.sleep(25)
      assert_eventually(predicate, attempts - 1)
    end
  end

  defp assert_eventually(_predicate, 0), do: flunk("condition did not become true")

  defp process_alive?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> not String.contains?(stat, ") Z ")
      {:error, :enoent} -> false
      {:error, _reason} -> true
    end
  end
end
