defmodule SymphonyElixir.TrackerToolServer do
  @moduledoc "Issue-bound tool facade used by the local DeepSeek MCP process."

  alias SymphonyElixir.Linear.TypedAgentTool

  @token_env "SYMPHONY_LINEAR_MCP_TOKEN"
  @endpoint_env "SYMPHONY_LINEAR_MCP_ENDPOINT"

  @spec tool_specs() :: [map()]
  def tool_specs, do: TypedAgentTool.tool_specs()

  @spec executable() :: {:ok, Path.t()} | {:error, :symphony_mcp_server_not_found}
  def executable do
    [System.find_executable("symphony"), escript_path()]
    |> Enum.find(&regular_absolute_file?/1)
    |> case do
      path when is_binary(path) -> {:ok, Path.expand(path)}
      nil -> {:error, :symphony_mcp_server_not_found}
    end
  end

  @spec start_link(map(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(%{id: _} = issue, opts \\ []) do
    Task.start_link(fn -> serve(issue, opts) end)
  end

  @spec main([String.t()]) :: :ok | no_return()
  def main(["--issue-id", issue_id]) when is_binary(issue_id) and issue_id != "" do
    serve(%{id: issue_id}, tracker_opts())
  end

  def main(_args) do
    IO.puts(:stderr, "Usage: symphony --tracker-tool-server --issue-id <Linear issue UUID>")
    System.halt(2)
  end

  @spec mcp_environment(map()) :: {:ok, [map()]} | {:error, term()}
  def mcp_environment(%{api_key: token} = settings) when is_binary(token) and token != "" do
    endpoint =
      Map.get(settings, :endpoint) || Map.get(settings, "endpoint") ||
        "https://api.linear.app/graphql"

    {:ok, [%{name: @token_env, value: token}, %{name: @endpoint_env, value: endpoint}]}
  end

  def mcp_environment(_settings), do: {:error, :missing_linear_mcp_token}

  @spec mcp_server(map(), Path.t(), map()) :: {:ok, map()} | {:error, term()}
  def mcp_server(%{id: issue_id}, executable, tracker_settings)
      when is_binary(issue_id) and issue_id != "" and is_binary(executable) do
    with true <- Path.type(executable) == :absolute or {:error, :mcp_command_not_absolute},
         true <- File.regular?(executable) or {:error, :mcp_command_not_regular},
         {:ok, env} <- mcp_environment(tracker_settings) do
      {:ok,
       %{
         name: "asyncself_linear",
         command: executable,
         args: ["--tracker-tool-server", "--issue-id", issue_id],
         env: env
       }}
    end
  end

  def mcp_server(_issue, _executable, _tracker_settings), do: {:error, :invalid_bound_issue}

  defp escript_path do
    case :escript.script_name() do
      [] -> nil
      name -> List.to_string(name)
    end
  end

  defp regular_absolute_file?(path) when is_binary(path) do
    expanded = Path.expand(path)
    Path.basename(expanded) == "symphony" and Path.type(expanded) == :absolute and File.regular?(expanded)
  end

  defp regular_absolute_file?(_path), do: false

  @spec execute(String.t(), map(), map(), keyword()) :: map()
  def execute(tool, arguments, %{issue: %{id: bound_id} = issue}, opts) when is_binary(bound_id) do
    with %{} = spec <- Enum.find(tool_specs(), &(&1["name"] == tool)),
         :ok <- validate_arguments(arguments, spec) do
      TypedAgentTool.execute(tool, arguments, Keyword.merge(opts, issue: issue))
    else
      nil -> %{"success" => false, "error" => %{"message" => "unknown or unregistered tool"}}
      {:error, reason} -> %{"success" => false, "error" => %{"message" => reason}}
    end
  end

  def execute(_tool, _arguments, _binding, _opts),
    do: %{"success" => false, "error" => %{"message" => "missing bound issue"}}

  @doc false
  @spec handle_request(map(), map(), keyword()) :: map() | nil
  def handle_request(%{"id" => id, "method" => "initialize", "params" => %{"protocolVersion" => version}}, _issue, _opts)
      when is_binary(version) do
    %{
      jsonrpc: "2.0",
      id: id,
      result: %{
        protocolVersion: version,
        capabilities: %{tools: %{}},
        serverInfo: %{name: "asyncself-linear", version: "0.1.0"}
      }
    }
  end

  def handle_request(%{"method" => "notifications/initialized"}, _issue, _opts), do: nil

  def handle_request(%{"id" => id, "method" => "tools/list"}, _issue, _opts) do
    %{jsonrpc: "2.0", id: id, result: %{tools: tool_specs()}}
  end

  def handle_request(%{"id" => id, "method" => "tools/call", "params" => %{"name" => name, "arguments" => args}}, issue, opts) do
    result = execute(name, args, %{issue: issue}, opts)
    %{jsonrpc: "2.0", id: id, result: %{content: [%{type: "text", text: Jason.encode!(result)}]}}
  end

  def handle_request(%{"id" => id}, _issue, _opts) do
    %{jsonrpc: "2.0", id: id, error: %{code: -32_601, message: "method not supported"}}
  end

  def handle_request(_request, _issue, _opts), do: nil

  defp tracker_opts do
    case System.get_env(@token_env) do
      token when is_binary(token) and token != "" ->
        [
          tracker_settings: %{
            api_key: token,
            endpoint: System.get_env(@endpoint_env) || "https://api.linear.app/graphql"
          }
        ]

      _ ->
        [
          tracker_settings: %{
            api_key: "",
            endpoint: System.get_env(@endpoint_env) || "https://api.linear.app/graphql"
          }
        ]
    end
  end

  defp validate_arguments(arguments, %{"inputSchema" => schema}) when is_map(arguments) do
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])

    cond do
      Enum.any?(Map.keys(arguments), &(not Map.has_key?(properties, &1))) ->
        {:error, "arguments contain an unregistered field"}

      Enum.any?(required, &(not Map.has_key?(arguments, &1))) ->
        {:error, "arguments are missing a required field"}

      Enum.any?(arguments, &invalid_string_argument?(&1, properties)) ->
        {:error, "arguments contain an invalid field value"}

      true ->
        :ok
    end
  end

  defp validate_arguments(_arguments, _spec), do: {:error, "arguments must be an object"}

  defp invalid_string_argument?({key, value}, properties) do
    Map.get(properties, key, %{})["type"] == "string" and (not is_binary(value) or value == "")
  end

  defp serve(issue, opts) do
    # The transport is intentionally a child-local stdio boundary.  Secrets are
    # held in opts by the host and never serialized into prompts or responses.
    _ = for line <- IO.stream(:stdio, :line), do: serve_line(line, issue, opts)
    :ok
  end

  defp serve_line(line, issue, opts) do
    with {:ok, request} <- Jason.decode(line),
         response when not is_nil(response) <- handle_request(request, issue, opts) do
      IO.puts(Jason.encode!(response))
    else
      _ -> :ok
    end
  end
end
