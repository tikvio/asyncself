defmodule SymphonyElixir.AgentBackend.DeepSeek do
  @moduledoc "ACP stdio adapter for the pinned local `dsh --profile acp` CLI."

  @behaviour SymphonyElixir.AgentBackend
  require Logger
  alias SymphonyElixir.AgentBackend.DeepSeek.SessionOwner

  @initialize_id 1
  @new_session_id 2
  @max_frame_bytes 1_048_576
  @console_wrapper_source File.read!(Path.expand("../../../priv/acp/console_to_stderr.cjs", __DIR__))

  @type owner_session :: %{owner: pid()}
  @type port_session :: %{
          required(:port) => port(),
          required(:process_group_pid) => pos_integer() | nil,
          required(:workspace) => Path.t(),
          required(:stderr_path) => Path.t(),
          required(:session_id) => String.t() | nil,
          optional(:request_counter) => term()
        }
  @type session :: owner_session() | port_session()

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    SessionOwner.start_link(workspace, opts)
    |> case do
      {:ok, owner} -> {:ok, %{owner: owner}}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @doc false
  @spec start_port_session(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_port_session(workspace, opts) do
    command = Keyword.get(opts, :command, "dsh --profile acp")
    timeout = Keyword.get(opts, :handshake_timeout_ms, 15_000)
    stderr_path = Path.join(System.tmp_dir!(), "asyncself-dsh-stderr-#{System.unique_integer([:positive])}.log")

    with {:ok, launch} <- acp_launch_command(command, stderr_path, opts) do
      try do
        port =
          Port.open(
            {:spawn_executable, String.to_charlist("/bin/bash")},
            [
              :binary,
              :exit_status,
              {:line, @max_frame_bytes},
              args: [~c"-lc", String.to_charlist(launch)],
              cd: String.to_charlist(workspace)
            ]
          )

        session = %{
          port: port,
          process_group_pid: port_process_group_pid(port),
          workspace: workspace,
          stderr_path: stderr_path,
          session_id: nil
        }

        with :ok <- send_request(port, @initialize_id, "initialize", initialize_params()),
             {:ok, _initialize} <- await_response(port, @initialize_id, timeout),
             :ok <- send_request(port, @new_session_id, "session/new", %{cwd: workspace, mcpServers: Keyword.get(opts, :mcp_servers, [])}),
             {:ok, result} <- await_response(port, @new_session_id, timeout),
             :ok <- validate_capabilities(result) do
          session_id = result["sessionId"]

          {:ok,
           session
           |> Map.put(:session_id, session_id)
           |> Map.put(:process_group_pid, await_process_group_pid(port))
           |> Map.put(:request_counter, :atomics.new(1, []))}
        else
          {:error, reason} ->
            close_session(session)
            {:error, reason}
        end
      rescue
        error -> {:error, {:deepseek_start_failed, Exception.message(error)}}
      end
    end
  end

  @spec start_turn(session(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def start_turn(session, prompt, issue), do: start_turn(session, prompt, issue, [])

  @spec start_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}

  @impl true
  def start_turn(%{owner: owner}, prompt, issue, opts),
    do: SessionOwner.start_turn(owner, prompt, issue, opts)

  def start_turn(%{port: port, request_counter: request_counter, session_id: session_id}, prompt, _issue, _opts) do
    id = :atomics.add_get(request_counter, 1, 1) + 2

    :ok = send_request(port, id, "session/prompt", %{sessionId: session_id, prompt: [%{type: "text", text: prompt}]})
    {:ok, %{turn_id: id}}
  end

  @spec await_turn(session(), map()) :: {:ok, map()} | {:error, term()}
  def await_turn(session, turn), do: await_turn(session, turn, [])

  @spec await_turn(session(), map(), keyword()) :: {:ok, map()} | {:error, term()}

  @impl true
  def await_turn(%{owner: owner}, turn, opts), do: SessionOwner.await_turn(owner, turn, opts)

  def await_turn(%{port: port} = session, %{turn_id: id}, opts) do
    now = System.monotonic_time(:millisecond)

    receive_turn(port, id, session, [], %{
      read_timeout_ms: Keyword.get(opts, :read_timeout_ms, 5_000),
      progress_timeout_ms: Keyword.get(opts, :progress_timeout_ms, 300_000),
      deadline_ms: now + Keyword.get(opts, :turn_timeout_ms, 3_600_000),
      last_read_ms: now,
      last_progress_ms: now
    })
  end

  @impl true
  @spec cancel_turn(session(), map(), term()) :: :ok | {:error, term()}
  def cancel_turn(%{owner: owner}, turn, reason), do: SessionOwner.cancel_turn(owner, turn, reason)

  def cancel_turn(%{port: port, session_id: session_id}, _turn, _reason) do
    :ok = send_notification(port, "session/cancel", %{sessionId: session_id})
    :ok
  end

  @impl true
  @spec close_session(session()) :: :ok
  def close_session(%{owner: owner}), do: SessionOwner.close(owner)

  def close_session(%{port: port, process_group_pid: process_group_pid, session_id: session_id, stderr_path: stderr_path}) do
    if is_binary(session_id) and Port.info(port) != nil do
      try do
        _ = send_request(port, 9_999_999, "session/close", %{sessionId: session_id})
        _ = await_response(port, 9_999_999, 1_000)
      rescue
        ArgumentError -> :ok
      end
    end

    # The ACP process is started as a session/process-group leader. Signal only
    # a group whose PGID matches its recorded root PID, so no parent BEAM
    # process or unrelated user CLI can be affected.
    _ = terminate_process_group(process_group_pid)

    if Port.info(port) != nil do
      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end
    end

    _ = bounded_stderr(stderr_path)
    File.rm(stderr_path)
    :ok
  catch
    :exit, _ -> :ok
  end

  @spec bounded_stderr(Path.t()) :: String.t()
  def bounded_stderr(path) do
    case File.read(path) do
      {:ok, data} -> String.slice(data, 0, 4_096)
      _ -> ""
    end
  end

  defp receive_turn(port, id, session, updates, timing) do
    now = System.monotonic_time(:millisecond)
    read_remaining = timing.read_timeout_ms - (now - timing.last_read_ms)
    progress_remaining = timing.progress_timeout_ms - (now - timing.last_progress_ms)
    wall_remaining = timing.deadline_ms - now

    cond do
      wall_remaining <= 0 ->
        {:error, :turn_timeout}

      read_remaining <= 0 ->
        {:error, :read_inactivity_timeout}

      progress_remaining <= 0 ->
        {:error, :progress_timeout}

      true ->
        receive_turn_message(
          port,
          id,
          session,
          updates,
          timing,
          min(read_remaining, min(progress_remaining, wall_remaining))
        )
    end
  end

  defp receive_turn_message(port, id, session, updates, timing, timeout) do
    receive do
      :deepseek_cancel ->
        _ = cancel_turn(session, %{turn_id: id}, :concurrent_cancel)
        receive_turn(port, id, session, updates, timing)

      :deepseek_close ->
        {:error, :session_closed}

      {^port, {:data, {:eol, line}}} ->
        timing = %{timing | last_read_ms: System.monotonic_time(:millisecond)}

        case Jason.decode(to_string(line)) do
          {:ok, %{"id" => ^id, "result" => result}} ->
            {:ok, %{result: result, updates: updates}}

          {:ok, %{"id" => ^id, "error" => error}} ->
            {:error, {:acp_error, error}}

          {:ok, %{"method" => "session/update"} = update} ->
            timing =
              if substantive_update?(update),
                do: %{timing | last_progress_ms: System.monotonic_time(:millisecond)},
                else: timing

            receive_turn(port, id, session, [update | updates], timing)

          {:ok, %{"id" => request_id, "method" => "session/request_permission"}} ->
            :ok = send_permission_rejection(port, request_id)
            receive_turn(port, id, session, updates, timing)

          {:ok, %{"id" => request_id, "method" => method}} ->
            :ok = send_method_not_found(port, request_id, method)
            receive_turn(port, id, session, updates, timing)

          {:ok, _other} ->
            receive_turn(port, id, session, updates, timing)

          {:error, reason} ->
            {:error, {:invalid_stdout_frame, reason}}
        end

      {^port, {:data, {:noeol, chunk}}} ->
        {:error, {:stdout_frame_too_large, byte_size(chunk)}}

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout -> receive_turn(port, id, session, updates, timing)
    end
  end

  defp substantive_update?(%{"params" => %{"update" => %{"sessionUpdate" => %{"type" => type}}}})
       when type in ["tool_call", "tool_call_update"], do: true

  defp substantive_update?(_update), do: false

  defp validate_capabilities(%{"sessionId" => _}), do: :ok
  defp validate_capabilities(result), do: {:error, {:missing_session_id, result}}

  defp initialize_params do
    %{protocolVersion: 1, clientInfo: %{name: "asyncself", version: "0.1.0"}, clientCapabilities: %{}}
  end

  # dsh itself is a shell shim that delegates to a Node entrypoint.  Invoking
  # that entrypoint directly lets us preload the ACP-only console policy without
  # using NODE_OPTIONS (which would leak into every Node child process).
  defp acp_launch_command("dsh --profile acp", stderr_path, opts) do
    with dsh when is_binary(dsh) <- Keyword.get(opts, :dsh_executable) || System.find_executable("dsh"),
         {:ok, entrypoint} <- dsh_entrypoint(dsh),
         node when is_binary(node) <- System.find_executable("node"),
         setsid when is_binary(setsid) <- System.find_executable("setsid"),
         wrapper when is_binary(wrapper) <- console_wrapper_path(),
         :ok <- ensure_regular_file(entrypoint, :dsh_entrypoint),
         :ok <- ensure_regular_file(wrapper, :console_wrapper) do
      home_prefix =
        case Keyword.get(opts, :dsh_home) do
          home when is_binary(home) and home != "" -> "DSH_HOME=#{shell_escape(home)} "
          _ -> ""
        end

      {:ok,
       home_prefix <>
         "exec #{shell_escape(setsid)} --wait #{shell_escape(node)} --require #{shell_escape(wrapper)} #{shell_escape(entrypoint)} --profile acp 2>#{shell_escape(stderr_path)}"}
    else
      nil -> {:error, :dsh_or_node_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp acp_launch_command(command, _stderr_path, _opts), do: {:error, {:unsupported_deepseek_command, command}}

  defp dsh_entrypoint(dsh) do
    case File.read(dsh) do
      {:ok, content} ->
        case Regex.run(~r/exec\s+"([^"]+)"\s+"\$@"/, content) do
          [_, target] -> {:ok, Path.expand(target, Path.dirname(dsh))}
          _ -> {:error, {:unsupported_dsh_launcher, dsh}}
        end

      {:error, reason} ->
        {:error, {:dsh_launcher_unreadable, dsh, reason}}
    end
  end

  defp console_wrapper_path do
    :symphony_elixir
    |> Application.app_dir("priv/acp/console_to_stderr.cjs")
    |> case do
      path when is_binary(path) -> if(File.regular?(path), do: path, else: materialize_console_wrapper())
    end
  end

  defp materialize_console_wrapper do
    digest = :crypto.hash(:sha256, @console_wrapper_source) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    path = Path.join(System.tmp_dir!(), "asyncself-acp-console-#{digest}.cjs")

    case File.read(path) do
      {:ok, @console_wrapper_source} ->
        path

      _ ->
        with :ok <- File.write(path, @console_wrapper_source),
             :ok <- File.chmod(path, 0o600) do
          path
        else
          _ -> nil
        end
    end
  end

  defp ensure_regular_file(path, label) do
    if File.regular?(path), do: :ok, else: {:error, {:missing_acp_file, label, path}}
  end

  defp port_process_group_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid > 0 -> acp_process_group_leader(pid)
      _ -> nil
    end
  end

  defp await_process_group_pid(port, attempts \\ 20)

  defp await_process_group_pid(_port, 0), do: nil

  defp await_process_group_pid(port, attempts) do
    case port_process_group_pid(port) do
      pid when is_integer(pid) ->
        pid

      nil ->
        Process.sleep(10)
        await_process_group_pid(port, attempts - 1)
    end
  end

  defp acp_process_group_leader(root_pid) do
    root_pid
    |> descendant_pids()
    |> Enum.find(fn pid -> process_group_id(pid) == pid and acp_command?(pid) end)
  end

  defp descendant_pids(root_pid), do: descendant_pids([root_pid], [], [])

  defp descendant_pids([], _seen, result), do: Enum.reverse(result)

  defp descendant_pids([pid | rest], seen, result) do
    if pid in seen do
      descendant_pids(rest, seen, result)
    else
      descendant_pids(child_pids(pid) ++ rest, [pid | seen], [pid | result])
    end
  end

  defp child_pids(pid) do
    case System.cmd("ps", ["-o", "pid=", "--ppid", Integer.to_string(pid)], stderr_to_stdout: true) do
      {children, 0} ->
        for child <- String.split(children), {child_pid, ""} <- [Integer.parse(child)], do: child_pid

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp acp_command?(pid) do
    with {:ok, executable} <- File.read_link("/proc/#{pid}/exe"),
         true <- Path.basename(executable) in ["node", "nodejs"],
         {:ok, command} <- File.read("/proc/#{pid}/cmdline") do
      String.contains?(command, "--profile\u0000acp")
    else
      _ -> false
    end
  end

  defp process_group_id(pid) do
    case System.cmd("ps", ["-o", "pgid=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {pgid, 0} ->
        case Integer.parse(String.trim(pgid)) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp terminate_process_group(nil), do: :ok

  defp terminate_process_group(pid) do
    with ^pid <- process_group_id(pid),
         {_output, 0} <- System.cmd("/bin/kill", ["-TERM", "--", "-#{pid}"], stderr_to_stdout: true) do
      :ok
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp send_request(port, id, method, params), do: send_json(port, %{jsonrpc: "2.0", id: id, method: method, params: params})
  defp send_notification(port, method, params), do: send_json(port, %{jsonrpc: "2.0", method: method, params: params})
  defp send_permission_rejection(port, id), do: send_json(port, %{jsonrpc: "2.0", id: id, result: %{outcome: %{outcome: "cancelled"}}})

  defp send_method_not_found(port, id, method),
    do: send_json(port, %{jsonrpc: "2.0", id: id, error: %{code: -32_601, message: "Unsupported ACP client request: #{method}"}})

  defp send_json(port, payload) do
    true = Port.command(port, Jason.encode!(payload) <> "\n")
    :ok
  end

  defp await_response(port, id, timeout) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(to_string(line)) do
          {:ok, %{"id" => ^id, "result" => result}} -> {:ok, result}
          {:ok, %{"id" => ^id, "error" => error}} -> {:error, {:acp_error, error}}
          {:ok, %{"method" => _}} -> await_response(port, id, timeout)
          {:ok, _} -> await_response(port, id, timeout)
          {:error, reason} -> {:error, {:invalid_stdout_frame, reason}}
        end

      {^port, {:data, {:noeol, chunk}}} ->
        {:error, {:stdout_frame_too_large, byte_size(chunk)}}

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout -> {:error, :handshake_timeout}
    end
  end

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
