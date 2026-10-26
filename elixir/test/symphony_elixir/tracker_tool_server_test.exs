defmodule SymphonyElixir.TrackerToolServerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.TrackerToolServer

  test "MCP server declaration keeps a token in server-local env and binds one issue" do
    executable = System.find_executable("sh")

    assert {:ok, server} =
             TrackerToolServer.mcp_server(
               %{id: "bound-issue"},
               executable,
               %{api_key: "fixture-token", endpoint: "https://linear.example.test/graphql"}
             )

    assert server.command == executable
    assert server.args == ["--tracker-tool-server", "--issue-id", "bound-issue"]

    assert server.env == [
             %{name: "SYMPHONY_LINEAR_MCP_TOKEN", value: "fixture-token"},
             %{name: "SYMPHONY_LINEAR_MCP_ENDPOINT", value: "https://linear.example.test/graphql"}
           ]
  end

  test "MCP tool ignores no caller-selected issue and rejects an injected issue field" do
    parent = self()

    result =
      TrackerToolServer.execute(
        "linear_get_issue",
        %{},
        %{issue: %{id: "bound-issue"}},
        linear_client: fn query, variables, _opts ->
          send(parent, {:linear_query, query, variables})
          {:ok, %{"data" => %{"issue" => %{"id" => "bound-issue"}}}}
        end
      )

    assert result["success"] == true
    assert_receive {:linear_query, _query, %{"id" => "bound-issue"}}

    rejected =
      TrackerToolServer.execute(
        "linear_get_issue",
        %{"issue_id" => "other-issue"},
        %{issue: %{id: "bound-issue"}},
        linear_client: fn _, _, _ -> flunk("must not call Linear") end
      )

    assert rejected == %{"success" => false, "error" => %{"message" => "arguments contain an unregistered field"}}
  end

  test "MCP transport requires initialize before advertising its fixed tool set" do
    issue = %{id: "bound-issue"}

    assert %{
             jsonrpc: "2.0",
             id: 1,
             result: %{
               protocolVersion: "2024-11-05",
               capabilities: %{tools: %{}},
               serverInfo: %{name: "asyncself-linear"}
             }
           } =
             TrackerToolServer.handle_request(
               %{
                 "id" => 1,
                 "method" => "initialize",
                 "params" => %{"protocolVersion" => "2024-11-05"}
               },
               issue,
               []
             )

    assert nil == TrackerToolServer.handle_request(%{"method" => "notifications/initialized"}, issue, [])

    assert %{result: %{tools: tools}} = TrackerToolServer.handle_request(%{"id" => 2, "method" => "tools/list"}, issue, [])
    assert Enum.any?(tools, &(&1["name"] == "linear_get_issue"))
    assert %{error: %{code: -32_601}} = TrackerToolServer.handle_request(%{"id" => 3, "method" => "unknown"}, issue, [])
  end

  test "MCP declaration fails closed for missing tokens and unsafe executable paths" do
    assert {:error, :missing_linear_mcp_token} = TrackerToolServer.mcp_environment(%{})
    assert {:error, :mcp_command_not_absolute} = TrackerToolServer.mcp_server(%{id: "bound-issue"}, "relative-symphony", %{api_key: "fixture"})
    assert {:error, :mcp_command_not_regular} = TrackerToolServer.mcp_server(%{id: "bound-issue"}, "/tmp/not-a-symphony-escript", %{api_key: "fixture"})
    assert {:error, :invalid_bound_issue} = TrackerToolServer.mcp_server(%{}, "/bin/sh", %{api_key: "fixture"})
    assert {:error, :symphony_mcp_server_not_found} = TrackerToolServer.executable()
  end

  test "MCP call response preserves a bound issue and rejects malformed requests" do
    issue = %{id: "bound-issue"}

    assert %{result: %{content: [%{text: response}]}} =
             TrackerToolServer.handle_request(
               %{
                 "id" => 4,
                 "method" => "tools/call",
                 "params" => %{"name" => "linear_get_issue", "arguments" => %{"issue_id" => "other"}}
               },
               issue,
               []
             )

    assert %{"success" => false} = Jason.decode!(response)
    assert nil == TrackerToolServer.handle_request(%{"method" => "ignored"}, issue, [])
  end

  test "stdio task serves a complete MCP initialize request and resolves its executable" do
    original_leader = Process.group_leader()

    {:ok, device} =
      StringIO.open(~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}\n))

    original_path = System.get_env("PATH")
    escript_dir = Path.join(File.cwd!(), "bin")

    try do
      Process.group_leader(self(), device)
      assert {:ok, pid} = TrackerToolServer.start_link(%{id: "bound-issue"})
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      Process.group_leader(self(), original_leader)

      {_, output} = StringIO.contents(device)
      assert output =~ "asyncself-linear"

      System.put_env("PATH", escript_dir <> ":" <> original_path)
      assert {:ok, executable} = TrackerToolServer.executable()
      assert executable == Path.join(escript_dir, "symphony")
    after
      Process.group_leader(self(), original_leader)
      System.put_env("PATH", original_path)
    end
  end

  test "CLI MCP mode owns only its server-local token and validates typed arguments" do
    original_leader = Process.group_leader()

    {:ok, device} =
      StringIO.open(~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}\n))

    original_token = System.get_env("SYMPHONY_LINEAR_MCP_TOKEN")

    try do
      System.put_env("SYMPHONY_LINEAR_MCP_TOKEN", "fixture-child-token")
      Process.group_leader(self(), device)
      assert :ok = TrackerToolServer.main(["--issue-id", "bound-issue"])
      Process.group_leader(self(), original_leader)
      {_, output} = StringIO.contents(device)
      assert output =~ "asyncself-linear"

      invalid =
        TrackerToolServer.execute(
          "linear_update_issue_state",
          %{"state" => ""},
          %{issue: %{id: "bound-issue"}},
          []
        )

      assert invalid == %{"success" => false, "error" => %{"message" => "arguments contain an invalid field value"}}
      assert %{"success" => false} = TrackerToolServer.execute("linear_get_issue", %{}, %{}, [])
    after
      Process.group_leader(self(), original_leader)
      if original_token, do: System.put_env("SYMPHONY_LINEAR_MCP_TOKEN", original_token), else: System.delete_env("SYMPHONY_LINEAR_MCP_TOKEN")
    end
  end
end
